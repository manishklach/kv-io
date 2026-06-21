# Stage 3: Kairo Request-Shape and Merge Instrumentation

## Why Request Shape Matters for AI KV-Cache

AI inference KV-cache workloads are read-dominant and typically issue large-block,
semi-sequential accesses to cached key-value data. When the block layer fragments
these reads into small, randomly-placed requests, the result is:

- higher per-request overhead (device command submission, completion interrupts)
- inflated tail latency (more I/O operations to satisfy the same logical read)
- lower effective throughput (device reaches IOPS limits before bandwidth limits)

Kairo Stage 3 addresses this by:

1. adding merge-instrumentation flags to track whether Kairo-classified reads are
   coalescing in `blk-merge`'s `attempt_merge` path
2. adding request-size counters and a per-class histogram so experiments can prove
   whether reads are large (>= 1 MiB) or fragmenting into tiny requests
3. adding conservative merge-bias helpers that encourage safe merges after normal
   queue-limit and compatibility checks pass

## What Kairo Tracks

### Per-Request Flags (set in `blk-merge`, consumed at dispatch)

- `KAIRO_HINT_MERGE_ATTEMPTED` -- set when `attempt_merge` or `blk_mq_bio_merge`
  sees a Kairo-classified request and a candidate bio
- `KAIRO_HINT_MERGE_SUCCESS` -- set when the merge actually completed

These flags travel on `rq->kairo_hints.flags` and are read by the mq-deadline
scheduler's `dd_kairo_account_merge()` at dispatch time.

### Scheduler Counters (sysfs, under `/sys/block/<dev>/queue/iosched/`)

Merge instrumentation:

- `kairo_merge_attempts` -- total Kairo merge attempts observed
- `kairo_merge_successes` -- total Kairo merges that succeeded
- `kairo_merge_rejects` -- Kairo merge attempts that failed blk-merge checks
- `kairo_decode_merge_attempts` -- attempts for decode reads only
- `kairo_decode_merge_successes` -- successful decode-read merges
- `kairo_prefetch_merge_attempts` -- attempts for prefetch reads only
- `kairo_prefetch_merge_successes` -- successful prefetch-read merges

Request-size classification:

- `kairo_small_decode_reads` / `kairo_large_decode_reads` -- split by `kairo_large_read_kb`
- `kairo_small_prefetch_reads` / `kairo_large_prefetch_reads`
- `kairo_large_read_kb` (tunable, default 1024 KiB)

Request-size histogram per class:

- `kairo_decode_read_4k`, `kairo_decode_read_16k`, `kairo_decode_read_64k`,
  `kairo_decode_read_256k`, `kairo_decode_read_1m`, `kairo_decode_read_4m`,
  `kairo_decode_read_gt4m`
- same buckets for `kairo_prefetch_read_*`

### Merge-Bias Helpers

- `kairo_should_bias_merge(rq, bio)` -- returns true for decode/prefetch reads
  within the Kairo large-read sector target
- `kairo_merge_within_limits(q, rq, bio)` -- double-checks queue max sectors and
  segment size constraints
- `kairo_merge_bias_enable` (tunable, default 1) -- global enable for merge bias

Important: Kairo merge bias must not bypass queue limits. All standard blk-merge
safety rules (max sectors, segment limits, integrity, zone, bio compatibility)
are checked before any bias is applied.

## Merge-Friendly vs Merge-Hostile

### Merge-Friendly

- sequential or clustered read placement
- large block size (e.g., 1 MiB)
- low session/model interleaving
- few concurrent workers per region
- expected result: high merge success, large reads dominate

### Merge-Hostile

- random or strided read placement
- small fragment size (e.g., 4 KiB)
- high session/model interleaving
- many concurrent workers sharing a region
- expected result: low merge success, small reads dominate

The benchmark modes `--mode merge-friendly` and `--mode merge-hostile` set
sensible defaults for these patterns.

## Which Counters Prove the Path Was Hit

After running a Stage 3 experiment:

```bash
# merge instrumentation
cat /sys/block/nvme0n1/queue/iosched/kairo_merge_attempts
cat /sys/block/nvme0n1/queue/iosched/kairo_merge_successes
cat /sys/block/nvme0n1/queue/iosched/kairo_decode_merge_successes

# request-size profile
cat /sys/block/nvme0n1/queue/iosched/kairo_large_decode_reads
cat /sys/block/nvme0n1/queue/iosched/kairo_small_decode_reads

# histogram (decode reads)
cat /sys/block/nvme0n1/queue/iosched/kairo_decode_read_1m
cat /sys/block/nvme0n1/queue/iosched/kairo_decode_read_4k
```

Non-zero merge counters confirm the blk-merge instrumentation path is active.
A merge-friendly run should show higher `kairo_merge_successes` and
`kairo_large_decode_reads` than a merge-hostile run.  If decode p99 is lower
in the merge-friendly case, that correlates better request geometry with
better tail latency.

## How to Run the Stage 3 Experiment

```bash
# Ensure mq-deadline is the active scheduler
echo mq-deadline > /sys/block/nvme0n1/queue/scheduler

# Full experiment suite
./scripts/run_stage3_merge_experiment.sh /mnt/test/kairo.bin nvme0n1
```

This runs six experiments:

| Case | Kairo | Pattern | Fragment |
| --- | --- | --- | --- |
| merge-friendly baseline | disabled | sequential | none |
| merge-friendly Kairo | enabled | sequential | none |
| merge-hostile baseline | disabled | random | 4K |
| merge-hostile Kairo | enabled | random | 4K |
| strided Kairo | enabled | strided | none |
| clustered Kairo | enabled | clustered | none |

Results are saved under `results/stage3/<timestamp>/`. The parser script can
summarize them:

```bash
python3 scripts/parse_kairo_bench_summary.py results/stage3/<timestamp>/*/bench.log
```

## RFC/POC Scaffold: Not Yet Compile-Validated

The merge-instrumentation and request-size counter code in patches `0004` and
`0009` is an RFC/POC scaffold. It has not been compile-tested against a real
Linux 6.8.x kernel tree. The per-request flag approach was chosen to avoid
cross-subsystem counter plumbing until the merge-bias strategy is validated
in local experiments.
