# KV-IO

Linux block-layer extensions for AI inference KV-cache storage

Status: Internal RFC/POC

This project is not intended for LKML submission at this stage.

KV cache is neither ordinary file data nor ordinary memory. It is large-block, read-dominant, latency-sensitive, session-scoped, and often recomputable inference state. KV-IO explores whether Linux can schedule and place this traffic more intelligently on generic NVMe SSDs.

## Problem Statement

Modern long-context and agentic AI inference creates a storage workload that Linux does not currently treat as first-class. Decode reads are latency-critical. Prefetch reads are important but not immediately blocking. Prefill writes are background relative to decode. Eviction and discard are lowest priority. When this inference state spills onto SSD-backed tiers, decode-critical reads can compete with background writes, cleanup traffic, filesystem activity, and unrelated storage work.

## Why AI KV-Cache I/O Is Different

AI KV-cache traffic has a distinctive shape:

```text
large-block reads
read-dominant decode phase
append-heavy prefill writes
deadline-aware prefetch
session/model scoping
immutable-after-write cache objects
large-chunk eviction
recomputable inference state
```

Traditional Linux block scheduling does not explicitly recognize that combination of urgency, mutability, and reuse.

## Architecture

```text
+---------------------------------------------------------+
| AI Runtime / Synthetic Benchmark                        |
| - decode reads                                          |
| - prefetch reads                                        |
| - prefill writes                                        |
| - eviction/discard                                      |
+---------------------------------------------------------+
| User-Space Hint Path                                    |
| - io_uring                                              |
| - O_DIRECT                                              |
| - registered buffers                                    |
| - ioprio / placement / lifetime hints                   |
+---------------------------------------------------------+
| KV-IO Block Layer                                       |
| - request classification                                |
| - decode-critical priority lane                         |
| - prefetch-aware scheduling                             |
| - large-block coalescing                                |
| - ephemeral/recomputable semantics                      |
| - model/session/lifetime propagation                    |
+---------------------------------------------------------+
| Generic NVMe Backend                                    |
| - mq-deadline extensions                                |
| - blk-mq metadata                                       |
| - optional ZNS / Streams / FDP mapping                  |
| - fallback to generic behavior                          |
+---------------------------------------------------------+
```

## Full Architecture Scope

KV-IO is intentionally broader than a single scheduler tweak. The repository explores:

- KV-cache I/O classification
- `mq-deadline` decode-critical read priority
- prefill/background write demotion
- prefetch-aware scheduling
- large-block I/O coalescing
- `io_uring` and `O_DIRECT` benchmark paths
- model/session/lifetime placement hints
- ephemeral/recomputable cache semantics
- optional ZNS, NVMe Streams, and FDP backend mapping
- benchmark-driven validation

## Initial Kernel Patch Strategy

The first working patch starts in `mq-deadline` and uses existing `ioprio` metadata as a temporary local classification mechanism:

```text
RT prio 0 read  -> KVIO_DECODE_READ
RT prio 1 read  -> KVIO_PREFETCH_READ
BE prio 7 write -> KVIO_PREFILL_WRITE
discard         -> KVIO_EVICT
```

This is an internal RFC/POC mechanism only. It is not a permanent UAPI proposal.

Initial patch artifacts:

- [0001-rfc-kvio-mq-deadline-decode-priority.patch](/C:/Users/ManishKL/Documents/Playground/kv-io/kernel/patches/0001-rfc-kvio-mq-deadline-decode-priority.patch)
- [0002-rfc-kvio-block-request-classification.patch](/C:/Users/ManishKL/Documents/Playground/kv-io/kernel/patches/0002-rfc-kvio-block-request-classification.patch)
- [0003-rfc-kvio-debugfs-scheduler-stats.patch](/C:/Users/ManishKL/Documents/Playground/kv-io/kernel/patches/0003-rfc-kvio-debugfs-scheduler-stats.patch)

## Benchmark Strategy

The primary benchmark path is [bench/kvio_bench.c](/C:/Users/ManishKL/Documents/Playground/kv-io/bench/kvio_bench.c), a compilable pthreads benchmark that models:

- decode reader threads
- prefetch reader threads
- prefill writer threads
- large-block reads and writes
- direct I/O where available
- per-thread `ioprio` assignment

`fio` profiles in [bench/fio](/C:/Users/ManishKL/Documents/Playground/kv-io/bench/fio) provide quick workload variants for decode-heavy, mixed interference, multi-model, and eviction-pressure scenarios.

## Success Metrics

Primary metric:

- p99 decode-read latency under mixed prefill-write pressure

Secondary metrics:

- p95 decode-read latency
- average decode-read latency
- write throughput
- aggregate throughput
- starvation behavior
- multi-model interference

## Non-Goals

- vendor-specific SSD, GPU, DPU, or inference dependencies
- permanent UAPI design at this stage
- production-readiness claims
- guaranteed speedup claims

## Build Benchmark

```bash
gcc -O2 -Wall -pthread -o kvio_bench bench/kvio_bench.c
```

Or:

```bash
./scripts/build_bench.sh
```

## Run Baseline

```bash
./scripts/run_baseline.sh /mnt/nvme/kvio.test nvme0n1
```

## Run KV-IO POC

```bash
./scripts/set_mq_deadline.sh nvme0n1
./scripts/run_kvio_poc.sh /mnt/nvme/kvio.test nvme0n1
```

## Repository Layout

- [docs/architecture.md](/C:/Users/ManishKL/Documents/Playground/kv-io/docs/architecture.md)
- [docs/aggressive_poc_plan.md](/C:/Users/ManishKL/Documents/Playground/kv-io/docs/aggressive_poc_plan.md)
- [docs/kernel_patch_plan.md](/C:/Users/ManishKL/Documents/Playground/kv-io/docs/kernel_patch_plan.md)
- [docs/benchmark_plan.md](/C:/Users/ManishKL/Documents/Playground/kv-io/docs/benchmark_plan.md)
- [docs/api_hints.md](/C:/Users/ManishKL/Documents/Playground/kv-io/docs/api_hints.md)
- [docs/storage_semantics.md](/C:/Users/ManishKL/Documents/Playground/kv-io/docs/storage_semantics.md)
- [docs/placement_lifetime_hints.md](/C:/Users/ManishKL/Documents/Playground/kv-io/docs/placement_lifetime_hints.md)
- [include/kvio_hints.h](/C:/Users/ManishKL/Documents/Playground/kv-io/include/kvio_hints.h)
- [kernel/patches/README.md](/C:/Users/ManishKL/Documents/Playground/kv-io/kernel/patches/README.md)
- [bench/README.md](/C:/Users/ManishKL/Documents/Playground/kv-io/bench/README.md)
