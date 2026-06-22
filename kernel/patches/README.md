# Kairo Patch Series

This directory contains the local Kairo RFC/POC multi-patch kernel series.

## Foundation Patches (compile-targeted)

```text
kernel/patches/foundation/
  0001-kairo-request-classification.patch
  0002-kairo-mq-deadline-decode-priority.patch
  0003-kairo-prefetch-prefill-evict-policy.patch
  0004-kairo-mq-deadline-sysfs-counters.patch
```

## RFC/POC Architecture Series

### Core classification and scheduling

- `0001-rfc-kairo-mq-deadline-decode-priority.patch` — decode read priority in mq-deadline
- `0002-rfc-kairo-request-classification.patch` — request classification scaffolding

### Hint plumbing and coalescing

- `0003-rfc-kairo-io-uring-hint-plumbing.patch` — io_uring / RWF_* hint propagation
- `0004-rfc-kairo-large-block-coalescing.patch` — merge-bias and coalescing hooks

### Policy, semantics, and placement

- `0005-rfc-kairo-prefetch-deadline-hints.patch` — prefetch deadline and budget policy
- `0006-rfc-kairo-ephemeral-cache-semantics.patch` — ephemeral and recomputable cache flags
- `0007-rfc-kairo-placement-lifetime-hints.patch` — model/session/cache-pool/lifetime metadata

### Backend mapping and counters

- `0008-rfc-kairo-nvme-zns-fdp-mapping.patch` — generic NVMe backend mapping scaffold
- `0009-rfc-kairo-sysfs-debug-counters.patch` — sysfs counters across all stages

### Supernova patches (structural hardening)

- `0010-rfc-kairo-request-classification-real.patch` — real ioprio-to-class at request init time
- `0011-rfc-kairo-write-antistarvation-deadline.patch` — per-write expiry deadline
- `0012-rfc-kairo-nvme-tag-reservation.patch` — blk-mq tag reservation for decode reads
- `0013-rfc-kairo-mq-deadline-dispatch-O1.patch` — O(1) decode/prefetch dispatch FIFOs
- `0014-rfc-kairo-io-uring-sqe-hint-flag.patch` — IORING_SQE_KAIRO_CLASS per-IO flag
- `0015-rfc-kairo-merge-bias-real.patch` — real merge bias with safety checks
- `0016-rfc-kairo-bpf-dispatch-hook.patch` — BPF_PROG_TYPE_KAIRO_SCHED hook

### Observability

- `0017-rfc-kairo-tracepoints-observability.patch` — 9 TRACE_EVENT tracepoints across the I/O lifecycle

These are experimental kernel path artifacts intended for local validation and
benchmark-driven POC work on generic NVMe SSDs.
