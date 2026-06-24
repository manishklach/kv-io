# Stage 17: io_uring KV Region Hints

## Why AI Runtimes Know KV Region Identity

AI inference runtimes manage KV-cache memory in explicit regions:

| Region | Content | Access Pattern | Recompute? |
|--------|---------|----------------|------------|
| Decode cache | Active KV-cache entries for the current request | Random read, latency-critical | No |
| Session cache | KV-cache entries shared across a conversation | Read after write, session-scoped | No |
| Model cache | KV-cache entries shared across model instances | Read after write, model-scoped | Depends |
| Prefetch cache | Pre-loaded KV-cache for speculative decoding | Sequential read, deadline-sensitive | Yes |
| Recomputable cache | Cache entries that can be regenerated from scratch | Read, but loss is acceptable | Yes |

The runtime knows which region each memory allocation belongs to —
it allocated them.  But this information is lost by the time I/O
reaches the kernel.

## Why Per-Request Hints May Be Too Repetitive

Kairo already supports per-request hints via ioprio and RWF flags.
But for KV-cache traffic where the same region is accessed repeatedly
over the lifetime of an inference session, per-request hints repeat
the same metadata on every I/O:

```
preadv2(fd, ..., RWF_DECODE)    // hint on every call
preadv2(fd, ..., RWF_DECODE)    // hint on every call
preadv2(fd, ..., RWF_PREFETCH)  // hint on every call
```

A region-level interface lets the runtime register KV region properties
once (at buffer registration or file region setup time), and the kernel
infers per-request semantics from the region metadata.  This reduces
runtime overhead and eliminates the possibility of per-request hint
inconsistency.

## Registered Buffers and Fixed Files as Natural Hint Carriers

Linux io_uring already has two mechanisms that are natural carriers
for region hints:

1. **Registered buffers** (`IORING_REGISTER_BUFFERS`): Buffers pinned
   in memory and indexed by a `buf_index`.  Each registered buffer
   could carry a `struct kairo_kv_region_hint` that the kernel uses
   to classify I/O to that buffer.

2. **Fixed files** (`IORING_REGISTER_FILES`): File descriptors pinned
   in the io_uring context.  File-backed KV-cache regions could be
   tagged with region metadata that applies to all I/O to that file
   within a given file offset range.

The conceptual opcodes `IORING_REGISTER_KAIRO_KV_REGION` (42) and
`IORING_REGISTER_KAIRO_KV_REGIONS` (43) are reserved for this purpose.

## Difference Between Region Hint and Request Class

| Dimension | Request Class (io_class) | KV Region Hint |
|-----------|--------------------------|----------------|
| Scope | Per-I/O operation | Per-registered buffer or file range |
| Lifetime | Single request | Region registration lifetime |
| Setting | ioprio / RWF flag per syscall | io_uring registration opcode |
| Granularity | Decode vs prefetch vs write vs evict | Decode cache vs session cache vs model cache vs prefetch cache vs recomputable cache |
| Model/Session | Per-request model_id, session_id | Inherited from region |
| Recompute ok | Per-request flag | Inherited from region |
| Benefit | Fine-grained, flexible | Low overhead, consistent, batch-applied |

In a full implementation, both would coexist: the KV region hint sets
defaults, and per-request flags can override them.

## Linux 6.8 io_uring Hook Candidates

| Hook point | File | Purpose |
|------------|------|---------|
| `io_init_req()` | `io_uring/io_uring.c` | Apply region hint at request init time |
| `io_issue_sqe()` | `io_uring/io_uring.c` | Apply region hint at SQE issue time |
| `io_read()` / `io_write()` | `io_uring/rw.c` | Apply region hint before bio allocation |
| `IORING_REGISTER_BUFFERS` | `io_uring/io_uring.c` | Registration path for buffer-tagged regions |
| `IORING_REGISTER_FILES` | `io_uring/io_uring.c` | Registration path for file-tagged regions |
| opdef table | `io_uring/opdef.c` | New opcodes for KV region registration |

LINUX-6.8-CHECK: These symbols exist in Linux 6.8 but their signatures
may differ in earlier or later kernels. The io_uring registration
patterns (`io_uring_register`, `io_sqe_buffer_register`) are the
reference implementation.

## Why This Is a Bench-Only Model

Stage 17 is intentionally limited:

1. **No real io_uring registration path.** The `IORING_REGISTER_KAIRO_KV_REGION`
   and `IORING_REGISTER_KAIRO_KV_REGIONS` opcodes are `#define` only — no
   handler function is wired.

2. **No region store.** There is no kernel data structure that stores
   registered KV region hints.

3. **No dispatch path integration.** `kairo_request_has_kv_region()`
   always returns false. `kairo_apply_kv_region_hint()` is a no-op.

4. **No io_uring worker in the benchmark.** The benchmark uses `pread`/
   `pwrite`, not io_uring. KV region fields are modeled in the config
   and printed in output, but do not affect I/O behavior.

5. **User-space header only.** `struct kairo_user_kv_region_hint` and
   related enums/flags are defined in `include/kairo_hints.h` for
   benchmark use.

## WSL Validation Limitations

WSL can validate:
- Experiment script dry-run (all 5 cases)
- Parser output format
- Benchmark KV region output fields
- io_uring audit script syntax check (does not require Linux source)

WSL cannot validate:
- Real `IORING_REGISTER_KAIRO_KV_REGION` opcode
- io_uring buffer registration path
- Per-request region hint application in the kernel
- Dispatch path integration

Stage 17 does **not** claim stable io_uring ABI or real registered-buffer
tagging unless tested on a patched kernel with io_uring KV region
registration.

## Files

| File | Purpose |
|------|---------|
| `kernel/patches/0027-rfc-kairo-io-uring-kv-region-hints.patch` | Kernel scaffold |
| `docs/stage17_io_uring_kv_region_hints.md` | This document |
| `include/kairo_hints.h` | User-space KV region structs and flags |
| `scripts/run_stage17_io_uring_region_experiment.sh` | Experiment script |
| `scripts/parse_stage17_io_uring_region_summary.py` | Summary parser |
| `kernel/integration/linux-6.8/audit_io_uring_hooks.sh` | io_uring hook audit |
