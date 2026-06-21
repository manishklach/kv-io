#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/ioprio.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "kairo_hints.h"

#ifndef IOPRIO_WHO_PROCESS
#define IOPRIO_WHO_PROCESS 1
#endif

#define DEFAULT_SIZE_BYTES   (8ULL * 1024ULL * 1024ULL * 1024ULL)
#define DEFAULT_BLOCK_BYTES  (1024ULL * 1024ULL)
#define DEFAULT_RUNTIME_SEC  60
#define MAX_LAT_SAMPLES      1048576

struct config {
    const char *path;
    uint64_t file_size;
    uint64_t block_size;
    int decode_threads;
    int prefetch_threads;
    int write_threads;
    int runtime_sec;
    bool random_read;
};

struct stats {
    atomic_ulong decode_reads;
    atomic_ulong prefetch_reads;
    atomic_ulong writes;
    atomic_ullong decode_ns_total;
    atomic_ullong decode_ns_max;
    uint64_t *lat_samples;
    atomic_ulong lat_count;
};

struct worker_arg {
    int fd;
    int id;
    int kind;
    struct config *cfg;
    struct stats *st;
    atomic_bool *stop;
};

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int set_ioprio(int class, int prio)
{
    int value = IOPRIO_PRIO_VALUE(class, prio);
    return syscall(SYS_ioprio_set, IOPRIO_WHO_PROCESS, 0, value);
}

static uint64_t parse_size(const char *s)
{
    char *end = NULL;
    double v = strtod(s, &end);
    if (!end || end == s) return 0;
    if (*end == 'G' || *end == 'g') return (uint64_t)(v * 1024.0 * 1024.0 * 1024.0);
    if (*end == 'M' || *end == 'm') return (uint64_t)(v * 1024.0 * 1024.0);
    if (*end == 'K' || *end == 'k') return (uint64_t)(v * 1024.0);
    return (uint64_t)v;
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s --file PATH [--size 8G] [--block-size 1M] "
        "[--decode-threads N] [--prefetch-threads N] [--write-threads N] "
        "[--runtime SEC] [--random-read]\n", prog);
}

static int parse_args(int argc, char **argv, struct config *cfg)
{
    cfg->path = NULL;
    cfg->file_size = DEFAULT_SIZE_BYTES;
    cfg->block_size = DEFAULT_BLOCK_BYTES;
    cfg->decode_threads = 4;
    cfg->prefetch_threads = 1;
    cfg->write_threads = 2;
    cfg->runtime_sec = DEFAULT_RUNTIME_SEC;
    cfg->random_read = false;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--file") && i + 1 < argc) cfg->path = argv[++i];
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) cfg->file_size = parse_size(argv[++i]);
        else if (!strcmp(argv[i], "--block-size") && i + 1 < argc) cfg->block_size = parse_size(argv[++i]);
        else if (!strcmp(argv[i], "--decode-threads") && i + 1 < argc) cfg->decode_threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--prefetch-threads") && i + 1 < argc) cfg->prefetch_threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--write-threads") && i + 1 < argc) cfg->write_threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--runtime") && i + 1 < argc) cfg->runtime_sec = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--random-read")) cfg->random_read = true;
        else { usage(argv[0]); return -1; }
    }

    if (!cfg->path || cfg->block_size == 0 || cfg->file_size < cfg->block_size) {
        usage(argv[0]);
        return -1;
    }
    return 0;
}

static void update_max(atomic_ullong *maxv, uint64_t val)
{
    uint64_t old = atomic_load(maxv);
    while (val > old && !atomic_compare_exchange_weak(maxv, &old, val)) {}
}

static void record_decode_latency(struct stats *st, uint64_t ns)
{
    atomic_fetch_add(&st->decode_ns_total, ns);
    update_max(&st->decode_ns_max, ns);
    unsigned long idx = atomic_fetch_add(&st->lat_count, 1);
    if (idx < MAX_LAT_SAMPLES) st->lat_samples[idx] = ns;
}

static int cmp_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a;
    uint64_t y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static uint64_t percentile(uint64_t *v, unsigned long n, double p)
{
    if (n == 0) return 0;
    unsigned long idx = (unsigned long)((p / 100.0) * (double)(n - 1));
    return v[idx];
}

static void *worker(void *opaque)
{
    struct worker_arg *arg = opaque;
    struct config *cfg = arg->cfg;
    struct stats *st = arg->st;
    void *buf = NULL;

    if (posix_memalign(&buf, 4096, cfg->block_size) != 0) {
        perror("posix_memalign");
        return NULL;
    }
    memset(buf, (arg->id & 0xff), cfg->block_size);

    if (arg->kind == KAIRO_CLASS_DECODE_READ) set_ioprio(IOPRIO_CLASS_RT, 0);
    else if (arg->kind == KAIRO_CLASS_PREFETCH_READ) set_ioprio(IOPRIO_CLASS_RT, 1);
    else if (arg->kind == KAIRO_CLASS_PREFILL_WRITE) set_ioprio(IOPRIO_CLASS_BE, 7);

    uint64_t blocks = cfg->file_size / cfg->block_size;
    uint64_t pos = (uint64_t)arg->id % blocks;
    unsigned int seed = (unsigned int)(time(NULL) ^ (arg->id * 2654435761U));

    while (!atomic_load(arg->stop)) {
        if (cfg->random_read && arg->kind != KAIRO_CLASS_PREFILL_WRITE)
            pos = rand_r(&seed) % blocks;
        off_t off = (off_t)(pos * cfg->block_size);

        if (arg->kind == KAIRO_CLASS_PREFILL_WRITE) {
            ssize_t rc = pwrite(arg->fd, buf, cfg->block_size, off);
            if (rc > 0) atomic_fetch_add(&st->writes, 1);
        } else {
            uint64_t t0 = now_ns();
            ssize_t rc = pread(arg->fd, buf, cfg->block_size, off);
            uint64_t dt = now_ns() - t0;
            if (rc > 0) {
                if (arg->kind == KAIRO_CLASS_DECODE_READ) {
                    atomic_fetch_add(&st->decode_reads, 1);
                    record_decode_latency(st, dt);
                } else {
                    atomic_fetch_add(&st->prefetch_reads, 1);
                }
            }
        }
        pos = (pos + 1) % blocks;
    }

    free(buf);
    return NULL;
}

int main(int argc, char **argv)
{
    struct config cfg;
    if (parse_args(argc, argv, &cfg) != 0) return 1;

    int fd = open(cfg.path, O_CREAT | O_RDWR | O_DIRECT, 0644);
    if (fd < 0 && errno == EINVAL) {
        fprintf(stderr, "O_DIRECT unavailable; falling back to buffered I/O\n");
        fd = open(cfg.path, O_CREAT | O_RDWR, 0644);
    }
    if (fd < 0) { perror("open"); return 1; }
    if (ftruncate(fd, (off_t)cfg.file_size) != 0) { perror("ftruncate"); return 1; }

    struct stats st = {0};
    st.lat_samples = calloc(MAX_LAT_SAMPLES, sizeof(uint64_t));
    if (!st.lat_samples) { perror("calloc"); return 1; }

    int nthreads = cfg.decode_threads + cfg.prefetch_threads + cfg.write_threads;
    pthread_t *threads = calloc(nthreads, sizeof(*threads));
    struct worker_arg *args = calloc(nthreads, sizeof(*args));
    atomic_bool stop = false;

    int t = 0;
    for (int i = 0; i < cfg.decode_threads; i++, t++)
        args[t] = (struct worker_arg){fd, t, KAIRO_CLASS_DECODE_READ, &cfg, &st, &stop};
    for (int i = 0; i < cfg.prefetch_threads; i++, t++)
        args[t] = (struct worker_arg){fd, t, KAIRO_CLASS_PREFETCH_READ, &cfg, &st, &stop};
    for (int i = 0; i < cfg.write_threads; i++, t++)
        args[t] = (struct worker_arg){fd, t, KAIRO_CLASS_PREFILL_WRITE, &cfg, &st, &stop};

    uint64_t start = now_ns();
    for (int i = 0; i < nthreads; i++) pthread_create(&threads[i], NULL, worker, &args[i]);
    sleep(cfg.runtime_sec);
    atomic_store(&stop, true);
    for (int i = 0; i < nthreads; i++) pthread_join(threads[i], NULL);
    uint64_t elapsed_ns = now_ns() - start;

    unsigned long reads = atomic_load(&st.decode_reads);
    unsigned long prefetch = atomic_load(&st.prefetch_reads);
    unsigned long writes = atomic_load(&st.writes);
    unsigned long samples = atomic_load(&st.lat_count);
    if (samples > MAX_LAT_SAMPLES) samples = MAX_LAT_SAMPLES;
    qsort(st.lat_samples, samples, sizeof(uint64_t), cmp_u64);

    double sec = (double)elapsed_ns / 1e9;
    double avg_us = reads ? ((double)atomic_load(&st.decode_ns_total) / (double)reads) / 1000.0 : 0.0;

    printf("Kairo benchmark summary\n");
    printf("file=%s size=%" PRIu64 " block=%" PRIu64 " runtime=%.2f sec\n", cfg.path, cfg.file_size, cfg.block_size, sec);
    printf("decode_reads=%lu prefetch_reads=%lu writes=%lu\n", reads, prefetch, writes);
    printf("decode_avg_us=%.2f p50_us=%.2f p95_us=%.2f p99_us=%.2f max_us=%.2f\n",
           avg_us,
           percentile(st.lat_samples, samples, 50.0) / 1000.0,
           percentile(st.lat_samples, samples, 95.0) / 1000.0,
           percentile(st.lat_samples, samples, 99.0) / 1000.0,
           atomic_load(&st.decode_ns_max) / 1000.0);
    printf("decode_read_MBps=%.2f write_MBps=%.2f\n",
           ((double)reads * (double)cfg.block_size / (1024.0 * 1024.0)) / sec,
           ((double)writes * (double)cfg.block_size / (1024.0 * 1024.0)) / sec);

    free(st.lat_samples);
    free(threads);
    free(args);
    close(fd);
    return 0;
}
