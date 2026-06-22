#define _GNU_SOURCE

#include <assert.h>
#include <linux/ioprio.h>
#include <stdio.h>

#define main kairo_bench_program_main
#include "../bench/kairo_bench.c"
#undef main

static void test_ioprio_mapping(void)
{
    assert(ioprio_value_for_worker_kind(KAIRO_WORKER_DECODE) ==
           IOPRIO_PRIO_VALUE(IOPRIO_CLASS_RT, KAIRO_CLASS_DECODE_READ));
    assert(ioprio_value_for_worker_kind(KAIRO_WORKER_PREFETCH) ==
           IOPRIO_PRIO_VALUE(IOPRIO_CLASS_RT, KAIRO_CLASS_PREFETCH_READ));
    assert(ioprio_value_for_worker_kind(KAIRO_WORKER_WRITE) ==
           IOPRIO_PRIO_VALUE(IOPRIO_CLASS_BE, 7));
    assert(ioprio_value_for_worker_kind(KAIRO_WORKER_EVICT) ==
           IOPRIO_PRIO_VALUE(IOPRIO_CLASS_BE, 6));
}

static void test_merge_friendly_defaults(void)
{
    struct kairo_config cfg;

    set_defaults(&cfg);
    cfg.mode = KAIRO_MODE_MERGE_FRIENDLY;
    cfg.decode_threads = 1;
    cfg.prefetch_threads = 0;
    cfg.write_threads = 0;
    apply_mode_defaults(&cfg);

    assert(cfg.access_pattern == KAIRO_ACCESS_SEQUENTIAL);
    assert(cfg.decode_threads == 4);
    assert(cfg.prefetch_threads == 2);
    assert(cfg.write_threads == 2);
    assert(cfg.random_read == false);
    assert(cfg.decode_region_pct == 50);
    assert(cfg.prefill_region_pct == 25);
}

static void test_merge_hostile_defaults(void)
{
    struct kairo_config cfg;

    set_defaults(&cfg);
    cfg.mode = KAIRO_MODE_MERGE_HOSTILE;
    cfg.sessions = 1;
    cfg.models = 1;
    cfg.decode_threads = 1;
    cfg.prefetch_threads = 1;
    cfg.fragment_size_bytes = 0;
    apply_mode_defaults(&cfg);

    assert(cfg.access_pattern == KAIRO_ACCESS_RANDOM);
    assert(cfg.sessions == 4);
    assert(cfg.models == 2);
    assert(cfg.decode_threads == 4);
    assert(cfg.prefetch_threads == 2);
    assert(cfg.fragment_size_bytes == 4096);
    assert(cfg.random_read == true);
    assert(cfg.decode_region_pct == 25);
    assert(cfg.prefill_region_pct == 25);
}

int main(void)
{
    test_ioprio_mapping();
    test_merge_friendly_defaults();
    test_merge_hostile_defaults();
    puts("test_kairo_bench: ok");
    return 0;
}
