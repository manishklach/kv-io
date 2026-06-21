# API Hints

KV-IO is not defining a permanent UAPI yet. The current repository only captures experimental hint concepts.

Useful hint channels include:

- `ioprio`
- `O_DIRECT`
- `io_uring`
- registered buffers
- `posix_fadvise()`
- write-life hints

Local classification mapping:

```text
RT prio 0 read  -> KVIO_DECODE_READ
RT prio 1 read  -> KVIO_PREFETCH_READ
BE prio 7 write -> KVIO_PREFILL_WRITE
discard         -> KVIO_EVICT
```

Future hint plumbing may include:

- `placement_id`
- `session_id`
- `model_id`
- lifetime class
- recomputable flag
