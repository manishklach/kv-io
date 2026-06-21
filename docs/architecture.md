# KV-IO Architecture

## 1. Motivation

KV-IO explores whether Linux can schedule AI inference-like storage traffic more intelligently on generic NVMe SSDs. The project starts from a simple observation: decode-critical reads should not be treated the same way as background cache-construction writes.

## 2. AI Inference Storage Pressure

Long-context and agentic inference increase storage pressure when KV-cache state outgrows fast memory tiers. That pressure shows up as repeated read access to previously written inference state and creates sensitivity to tail latency.

## 3. KV-Cache Workload Model

The target workload is:

- large-block
- read-dominant during decode
- append-written during prefill
- mostly immutable after write
- session and model scoped
- often recomputable

## 4. Prefill Vs Decode I/O Behavior

Prefill is write-oriented cache creation. Decode is read-dominant and latency-sensitive. Prefetch sits between them: useful soon, but not yet blocking token generation.

## 5. Why Ordinary Linux Block Scheduling Is Insufficient

Generic block scheduling optimizes broadly for fairness and mixed workload behavior. It does not explicitly represent:

- decode urgency
- prefetch timing
- background prefill demotion
- ephemeral/recomputable semantics

## 6. KV-IO Architecture Overview

KV-IO spans:

- user-space workload generation and hinting
- block-layer request classification
- `mq-deadline` priority behavior
- optional backend mappings

## 7. I/O Classes

```text
KV_DECODE_READ      highest priority
KV_PREFETCH_READ    high priority, deadline-aware
KV_PREFILL_WRITE    lower priority background write
KV_EVICT            lowest priority discard/cleanup
NORMAL_IO           ordinary traffic
```

## 8. `io_uring` / `O_DIRECT` User-Space Hint Path

The initial benchmark uses `pread()` and `pwrite()` for simplicity, but the architectural path includes:

- `io_uring`
- `O_DIRECT`
- registered buffers
- user-space classification and placement hints

## 9. Block Request Classification

The internal model uses experimental classification concepts and current local mapping through `ioprio`.

## 10. `mq-deadline` Priority Lanes

The first patch adds a decode-priority fast path that checks for eligible decode reads before normal dispatch.

## 11. Large-Block Coalescing

Large KV-cache reads should be eligible for merge-friendly handling when that improves throughput without harming decode latency.

## 12. Prefetch And Deadline-Aware Scheduling

Prefetch traffic should remain above ordinary background work but below decode-critical reads.

## 13. Ephemeral/Recomputable Cache Semantics

KV cache often does not require the same durability assumptions as database or filesystem metadata traffic.

## 14. Model/Session/Lifetime Placement Hints

Longer-term architecture includes:

- `model_id`
- `session_id`
- `placement_id`
- lifetime class
- recomputable flag

## 15. Optional NVMe/ZNS/Streams/FDP Backend Mapping

Backend-specific mapping remains optional and should never be a project dependency.

## 16. Benchmarking And Validation

Validation is benchmark-driven and focuses on p50, p95, and p99 latency plus throughput and interference behavior.

## 17. Risks And Limits

- scheduler changes may not dominate device behavior
- `ioprio` is only a temporary signal
- user-space benchmarks only approximate real inference pipelines

## 18. Future Work

- true `io_uring` worker paths
- explicit prefetch scheduling
- merge heuristics for KV reads
- placement and lifetime plumbing
