#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <linux/ioprio.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef O_DIRECT
#define O_DIRECT 0
#endif

#define MAX_SAMPLES 1000000UL

enum worker_kind {
    WORKER_DECODE = 0,
    WORKER_PREFETCH = 1,
    WORKER_WRITE = 2,
};

struct kvio_config {
    const char *file_path;
    uint64_t file_size_bytes;
    size_t block_size_bytes;
    unsigned int decode_threads;
    unsigned int prefetch_threads;
    unsigned int write_threads;
    unsigned int runtime_seconds;
    unsigned int queue_depth;
    bool use_direct;
    bool random_read;
};

struct kvio_stats {
    pthread_mutex_t lock;
    uint64_t total_decode_reads;
    uint64_t total_prefetch_reads;
    uint64_t total_writes;
    uint64_t total_read_bytes;
    uint64_t total_write_bytes;
    uint64_t decode_latency_samples;
    long double decode_latency_sum_us;
    double max_decode_latency_us;
    double *decode_latencies_us;
};

struct worker_ctx {
    int fd;
    const struct kvio_config *cfg;
    struct kvio_stats *stats;
    unsigned int worker_id;
    enum worker_kind kind;
    volatile bool *stop;
    off_t region_start;
    off_t region_length;
};

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s --file <path> [options]\n"
            "  --file <path>\n"
            "  --size <bytes|K|M|G>\n"
            "  --block-size <bytes|K|M|G>\n"
            "  --decode-threads <n>\n"
            "  --prefetch-threads <n>\n"
            "  --write-threads <n>\n"
            "  --runtime <sec>\n"
            "  --queue-depth <n>\n"
            "  --random-read\n"
            "  --sequential-read\n"
            "  --buffered\n",
            prog);
}

static uint64_t parse_size(const char *value, const char *name)
{
    char *end = NULL;
    uint64_t parsed;
    uint64_t scale = 1;

    if (value == NULL || value[0] == '\0') {
        fprintf(stderr, "invalid %s\n", name);
        exit(EXIT_FAILURE);
    }

    parsed = strtoull(value, &end, 10);
    if (end == value) {
        fprintf(stderr, "invalid %s: %s\n", name, value);
        exit(EXIT_FAILURE);
    }

    if (*end != '\0') {
        if (end[1] != '\0') {
            fprintf(stderr, "invalid %s suffix: %s\n", name, value);
            exit(EXIT_FAILURE);
        }
        switch (*end) {
        case 'k':
        case 'K':
            scale = 1024ULL;
            break;
        case 'm':
        case 'M':
            scale = 1024ULL * 1024ULL;
            break;
        case 'g':
        case 'G':
            scale = 1024ULL * 1024ULL * 1024ULL;
            break;
        default:
            fprintf(stderr, "invalid %s suffix: %s\n", name, value);
            exit(EXIT_FAILURE);
        }
    }

    return parsed * scale;
}

static void set_defaults(struct kvio_config *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->file_size_bytes = 8ULL * 1024ULL * 1024ULL * 1024ULL;
    cfg->block_size_bytes = 1024UL * 1024UL;
    cfg->decode_threads = 4;
    cfg->prefetch_threads = 0;
    cfg->write_threads = 2;
    cfg->runtime_seconds = 60;
    cfg->queue_depth = 32;
    cfg->use_direct = true;
    cfg->random_read = true;
}

static void validate_config(const struct kvio_config *cfg)
{
    if (cfg->file_path == NULL) {
        fprintf(stderr, "--file is required\n");
        exit(EXIT_FAILURE);
    }
    if (cfg->block_size_bytes == 0 || cfg->file_size_bytes < cfg->block_size_bytes) {
        fprintf(stderr, "invalid size or block size\n");
        exit(EXIT_FAILURE);
    }
    if ((cfg->file_size_bytes % cfg->block_size_bytes) != 0) {
        fprintf(stderr, "--size must be a multiple of --block-size\n");
        exit(EXIT_FAILURE);
    }
    if (cfg->decode_threads == 0 && cfg->prefetch_threads == 0 && cfg->write_threads == 0) {
        fprintf(stderr, "no workers configured\n");
        exit(EXIT_FAILURE);
    }
}

static double timespec_diff_us(const struct timespec *start, const struct timespec *end)
{
    time_t sec = end->tv_sec - start->tv_sec;
    long nsec = end->tv_nsec - start->tv_nsec;

    return ((double)sec * 1000000.0) + ((double)nsec / 1000.0);
}

static int compare_double(const void *lhs, const void *rhs)
{
    const double a = *(const double *)lhs;
    const double b = *(const double *)rhs;

    if (a < b)
        return -1;
    if (a > b)
        return 1;
    return 0;
}

static double percentile_from_sorted(const double *values, uint64_t count, double pct)
{
    uint64_t index;

    if (count == 0)
        return 0.0;
    index = (uint64_t)(((pct / 100.0) * (double)(count - 1)) + 0.5);
    if (index >= count)
        index = count - 1;
    return values[index];
}

static int set_current_ioprio(enum worker_kind kind)
{
    int prio;

    switch (kind) {
    case WORKER_DECODE:
        prio = IOPRIO_PRIO_VALUE(IOPRIO_CLASS_RT, 0);
        break;
    case WORKER_PREFETCH:
        prio = IOPRIO_PRIO_VALUE(IOPRIO_CLASS_RT, 1);
        break;
    case WORKER_WRITE:
    default:
        prio = IOPRIO_PRIO_VALUE(IOPRIO_CLASS_BE, 7);
        break;
    }

    return syscall(SYS_ioprio_set, IOPRIO_WHO_PROCESS, 0, prio);
}

static int open_target(const struct kvio_config *cfg)
{
    int flags = O_CREAT | O_RDWR;
    int fd;

    if (cfg->use_direct)
        flags |= O_DIRECT;

    fd = open(cfg->file_path, flags, 0666);
    if (fd < 0 && cfg->use_direct) {
        fprintf(stderr, "warning: O_DIRECT open failed (%s), retrying buffered I/O\n", strerror(errno));
        flags &= ~O_DIRECT;
        fd = open(cfg->file_path, flags, 0666);
    }
    if (fd < 0) {
        perror("open");
        exit(EXIT_FAILURE);
    }
    return fd;
}

static void prepare_file(int fd, const struct kvio_config *cfg)
{
    if (ftruncate(fd, (off_t)cfg->file_size_bytes) != 0) {
        perror("ftruncate");
        close(fd);
        exit(EXIT_FAILURE);
    }
}

static void stats_init(struct kvio_stats *stats)
{
    memset(stats, 0, sizeof(*stats));
    pthread_mutex_init(&stats->lock, NULL);
    stats->decode_latencies_us = calloc(MAX_SAMPLES, sizeof(double));
    if (stats->decode_latencies_us == NULL) {
        perror("calloc");
        exit(EXIT_FAILURE);
    }
}

static void stats_destroy(struct kvio_stats *stats)
{
    pthread_mutex_destroy(&stats->lock);
    free(stats->decode_latencies_us);
}

static void record_decode(struct kvio_stats *stats, double latency_us, size_t bytes)
{
    pthread_mutex_lock(&stats->lock);
    stats->total_decode_reads++;
    stats->total_read_bytes += bytes;
    stats->decode_latency_sum_us += latency_us;
    if (latency_us > stats->max_decode_latency_us)
        stats->max_decode_latency_us = latency_us;
    if (stats->decode_latency_samples < MAX_SAMPLES)
        stats->decode_latencies_us[stats->decode_latency_samples++] = latency_us;
    pthread_mutex_unlock(&stats->lock);
}

static void record_prefetch(struct kvio_stats *stats, size_t bytes)
{
    pthread_mutex_lock(&stats->lock);
    stats->total_prefetch_reads++;
    stats->total_read_bytes += bytes;
    pthread_mutex_unlock(&stats->lock);
}

static void record_write(struct kvio_stats *stats, size_t bytes)
{
    pthread_mutex_lock(&stats->lock);
    stats->total_writes++;
    stats->total_write_bytes += bytes;
    pthread_mutex_unlock(&stats->lock);
}

static off_t next_read_offset(const struct worker_ctx *ctx, off_t op_index, off_t block_count)
{
    if (!ctx->cfg->random_read)
        return op_index % block_count;

    if (ctx->kind == WORKER_PREFETCH)
        return (op_index * 31 + (off_t)(ctx->worker_id * 7)) % block_count;

    return (op_index * 17 + (off_t)ctx->worker_id) % block_count;
}

static void *worker_main(void *arg)
{
    struct worker_ctx *ctx = (struct worker_ctx *)arg;
    void *buffer = NULL;
    size_t block_size = ctx->cfg->block_size_bytes;
    off_t block_count = (off_t)(ctx->region_length / (off_t)block_size);
    off_t op_index = 0;

    if (set_current_ioprio(ctx->kind) != 0) {
        fprintf(stderr, "warning: ioprio_set failed for worker %u: %s\n",
                ctx->worker_id, strerror(errno));
    }

    if (posix_memalign(&buffer, block_size, block_size) != 0) {
        perror("posix_memalign");
        return (void *)1;
    }

    memset(buffer, ctx->kind == WORKER_WRITE ? ('A' + (ctx->worker_id % 26)) : 0, block_size);

    while (!*(ctx->stop)) {
        off_t block_offset;
        off_t file_offset;
        ssize_t rc;

        if (block_count == 0)
            break;

        if (ctx->kind == WORKER_WRITE)
            block_offset = op_index % block_count;
        else
            block_offset = next_read_offset(ctx, op_index, block_count);

        file_offset = ctx->region_start + (block_offset * (off_t)block_size);

        if (ctx->kind == WORKER_WRITE) {
            rc = pwrite(ctx->fd, buffer, block_size, file_offset);
            if (rc < 0 || (size_t)rc != block_size)
                break;
            record_write(ctx->stats, block_size);
        } else {
            struct timespec start_ts;
            struct timespec end_ts;
            double latency_us;

            if (clock_gettime(CLOCK_MONOTONIC, &start_ts) != 0)
                break;
            rc = pread(ctx->fd, buffer, block_size, file_offset);
            if (clock_gettime(CLOCK_MONOTONIC, &end_ts) != 0)
                break;
            if (rc < 0 || (size_t)rc != block_size)
                break;
            latency_us = timespec_diff_us(&start_ts, &end_ts);

            if (ctx->kind == WORKER_DECODE)
                record_decode(ctx->stats, latency_us, block_size);
            else
                record_prefetch(ctx->stats, block_size);
        }

        op_index++;
    }

    free(buffer);
    return NULL;
}

static void print_summary(const struct kvio_config *cfg, const struct kvio_stats *stats)
{
    double avg_decode_us = 0.0;
    double p50_us = 0.0;
    double p95_us = 0.0;
    double p99_us = 0.0;
    double *sorted = NULL;
    double read_mib_s;
    double write_mib_s;

    if (stats->decode_latency_samples > 0) {
        sorted = malloc((size_t)stats->decode_latency_samples * sizeof(*sorted));
        if (sorted == NULL) {
            perror("malloc");
            exit(EXIT_FAILURE);
        }
        memcpy(sorted, stats->decode_latencies_us,
               (size_t)stats->decode_latency_samples * sizeof(*sorted));
        qsort(sorted, (size_t)stats->decode_latency_samples, sizeof(*sorted), compare_double);
        avg_decode_us = (double)(stats->decode_latency_sum_us / (long double)stats->decode_latency_samples);
        p50_us = percentile_from_sorted(sorted, stats->decode_latency_samples, 50.0);
        p95_us = percentile_from_sorted(sorted, stats->decode_latency_samples, 95.0);
        p99_us = percentile_from_sorted(sorted, stats->decode_latency_samples, 99.0);
    }

    read_mib_s = cfg->runtime_seconds ?
        ((double)stats->total_read_bytes / (1024.0 * 1024.0)) / (double)cfg->runtime_seconds : 0.0;
    write_mib_s = cfg->runtime_seconds ?
        ((double)stats->total_write_bytes / (1024.0 * 1024.0)) / (double)cfg->runtime_seconds : 0.0;

    printf("kvio-bench summary\n");
    printf("  file:                   %s\n", cfg->file_path);
    printf("  total_decode_reads:     %" PRIu64 "\n", stats->total_decode_reads);
    printf("  total_prefetch_reads:   %" PRIu64 "\n", stats->total_prefetch_reads);
    printf("  total_writes:           %" PRIu64 "\n", stats->total_writes);
    printf("  avg_decode_latency_us:  %.2f\n", avg_decode_us);
    printf("  p50_decode_latency_us:  %.2f\n", p50_us);
    printf("  p95_decode_latency_us:  %.2f\n", p95_us);
    printf("  p99_decode_latency_us:  %.2f\n", p99_us);
    printf("  max_decode_latency_us:  %.2f\n", stats->max_decode_latency_us);
    printf("  read_throughput_mib_s:  %.2f\n", read_mib_s);
    printf("  write_throughput_mib_s: %.2f\n", write_mib_s);
    printf("TODO: add io_uring implementation.\n");

    free(sorted);
}

int main(int argc, char **argv)
{
    struct kvio_config cfg;
    struct kvio_stats stats;
    pthread_t *threads = NULL;
    struct worker_ctx *workers = NULL;
    volatile bool stop = false;
    unsigned int total_threads;
    unsigned int index = 0;
    unsigned int i;
    off_t third;
    int fd;
    int opt;
    int option_index = 0;

    static const struct option long_options[] = {
        {"file", required_argument, NULL, 'f'},
        {"size", required_argument, NULL, 's'},
        {"block-size", required_argument, NULL, 'b'},
        {"decode-threads", required_argument, NULL, 'd'},
        {"prefetch-threads", required_argument, NULL, 'p'},
        {"write-threads", required_argument, NULL, 'w'},
        {"runtime", required_argument, NULL, 't'},
        {"random-read", no_argument, NULL, 1},
        {"sequential-read", no_argument, NULL, 2},
        {"queue-depth", required_argument, NULL, 'q'},
        {"buffered", no_argument, NULL, 3},
        {0, 0, 0, 0},
    };

    set_defaults(&cfg);

    while ((opt = getopt_long(argc, argv, "f:s:b:d:p:w:t:q:", long_options, &option_index)) != -1) {
        switch (opt) {
        case 'f':
            cfg.file_path = optarg;
            break;
        case 's':
            cfg.file_size_bytes = parse_size(optarg, "size");
            break;
        case 'b':
            cfg.block_size_bytes = (size_t)parse_size(optarg, "block-size");
            break;
        case 'd':
            cfg.decode_threads = (unsigned int)parse_size(optarg, "decode-threads");
            break;
        case 'p':
            cfg.prefetch_threads = (unsigned int)parse_size(optarg, "prefetch-threads");
            break;
        case 'w':
            cfg.write_threads = (unsigned int)parse_size(optarg, "write-threads");
            break;
        case 't':
            cfg.runtime_seconds = (unsigned int)parse_size(optarg, "runtime");
            break;
        case 'q':
            cfg.queue_depth = (unsigned int)parse_size(optarg, "queue-depth");
            break;
        case 1:
            cfg.random_read = true;
            break;
        case 2:
            cfg.random_read = false;
            break;
        case 3:
            cfg.use_direct = false;
            break;
        default:
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }

    validate_config(&cfg);
    fd = open_target(&cfg);
    prepare_file(fd, &cfg);
    stats_init(&stats);

    total_threads = cfg.decode_threads + cfg.prefetch_threads + cfg.write_threads;
    threads = calloc(total_threads, sizeof(*threads));
    workers = calloc(total_threads, sizeof(*workers));
    if (threads == NULL || workers == NULL) {
        perror("calloc");
        return EXIT_FAILURE;
    }

    third = (off_t)cfg.file_size_bytes / 3;
    third -= third % (off_t)cfg.block_size_bytes;
    if (third == 0)
        third = (off_t)cfg.block_size_bytes;

    for (i = 0; i < cfg.decode_threads; i++, index++) {
        workers[index] = (struct worker_ctx){
            .fd = fd, .cfg = &cfg, .stats = &stats, .worker_id = i,
            .kind = WORKER_DECODE, .stop = &stop, .region_start = 0, .region_length = third
        };
        pthread_create(&threads[index], NULL, worker_main, &workers[index]);
    }

    for (i = 0; i < cfg.prefetch_threads; i++, index++) {
        workers[index] = (struct worker_ctx){
            .fd = fd, .cfg = &cfg, .stats = &stats, .worker_id = i,
            .kind = WORKER_PREFETCH, .stop = &stop, .region_start = third, .region_length = third
        };
        pthread_create(&threads[index], NULL, worker_main, &workers[index]);
    }

    for (i = 0; i < cfg.write_threads; i++, index++) {
        workers[index] = (struct worker_ctx){
            .fd = fd, .cfg = &cfg, .stats = &stats, .worker_id = i,
            .kind = WORKER_WRITE, .stop = &stop,
            .region_start = third * 2, .region_length = (off_t)cfg.file_size_bytes - (third * 2)
        };
        if (workers[index].region_length < (off_t)cfg.block_size_bytes) {
            workers[index].region_start = 0;
            workers[index].region_length = (off_t)cfg.file_size_bytes;
        }
        pthread_create(&threads[index], NULL, worker_main, &workers[index]);
    }

    sleep(cfg.runtime_seconds);
    stop = true;

    for (i = 0; i < total_threads; i++)
        pthread_join(threads[i], NULL);

    print_summary(&cfg, &stats);

    free(threads);
    free(workers);
    stats_destroy(&stats);
    close(fd);
    return 0;
}
