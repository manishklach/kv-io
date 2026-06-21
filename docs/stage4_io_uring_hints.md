# Stage 4: io_uring Hint Propagation

Stage 4 exists because `ioprio` is only a temporary signaling mechanism for the
Kairo benchmark. It is useful for local validation, but it does not look like a
real AI runtime expressing decode, prefetch, prefill, or recompute intent.

## Why `ioprio` Is Temporary

- it overloads a generic priority mechanism instead of carrying explicit KV-cache intent
- it is awkward for future `io_uring`-style submission paths
- it makes it harder to tell whether classification came from explicit Kairo metadata or a fallback

## Desired Hint Path

Kairo Stage 4 scaffolds this local RFC/POC path:

```text
userspace benchmark
  -> preadv2/pwritev2 or io_uring SQE flags
  -> kiocb Kairo flags
  -> bio Kairo metadata
  -> request Kairo hints
  -> blk-mq classification
  -> mq-deadline scheduling
```

## Local RWF Flags

Stage 4 uses local RFC flags:

```c
#define RWF_KAIRO_DECODE      ((__kernel_rwf_t)0x10000000)
#define RWF_KAIRO_PREFETCH    ((__kernel_rwf_t)0x20000000)
#define RWF_KAIRO_PREFILL     ((__kernel_rwf_t)0x40000000)
#define RWF_KAIRO_RECOMPUTE   ((__kernel_rwf_t)0x80000000)
```

These are local experimental flags only. They are not presented as stable UAPI.

## Kernel Metadata Flow

- `fs/read_write.c` is the local `preadv2()` / `pwritev2()` ingress point
- `io_uring/rw.c` is the local SQE-to-`kiocb` ingress point
- `kiocb_set_kairo_flags()` mirrors userspace flags into `IOCB_KAIRO_*`
- `kairo_class_from_kiocb()` provides the conceptual class mapping
- `bio_set_kairo_from_kiocb()` and `rq_set_kairo_from_bio()` show how intent moves into block-layer metadata
- `kairo_classify_rq()` then prioritizes explicit Kairo hints before `ioprio` fallback

## Fallback Behavior

The benchmark keeps `--hint-mode ioprio` as the default.

When `--hint-mode rwf` or `--hint-mode both` is used on an unpatched kernel:

- `preadv2()` / `pwritev2()` is attempted with `RWF_KAIRO_*`
- if the syscall returns `EINVAL`, `EOPNOTSUPP`, or `ENOSYS`, the benchmark falls back
- normal `pread()` / `pwrite()` continues the run
- failure counters are recorded in the summary

## Counters That Prove The Path

Stage 4 extends observability with:

- `kairo_ioprio_hinted_requests`
- `kairo_rwf_hinted_requests`
- `kairo_bio_hinted_requests`
- `kairo_hint_fallback_requests`
- existing dispatch counters such as `kairo_decode_dispatches`

These counters are scaffolded as the intended proof points for future kernel validation.

## How To Run

Build the benchmark locally:

```bash
gcc -O2 -Wall -pthread -Iinclude -o kairo_bench bench/kairo_bench.c
```

Run the Stage 4 experiment:

```bash
./scripts/run_stage4_hint_experiment.sh <file-path> <block-device>
```

This runs:

- `--hint-mode ioprio`
- `--hint-mode rwf`
- `--hint-mode both`

and captures benchmark logs plus Kairo counter snapshots under `results/stage4/`.
