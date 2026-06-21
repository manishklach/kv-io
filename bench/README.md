# KV-IO Bench

This directory contains the real compilable benchmark scaffold for KV-IO.

## Workload Roles

- decode readers: RT class, prio 0
- prefetch readers: RT class, prio 1
- prefill writers: BE class, prio 7

## Build

```bash
gcc -O2 -Wall -pthread -o kvio_bench bench/kvio_bench.c
```

## Example

```bash
./kvio_bench --file /mnt/nvme/kvio.test --size 8G --block-size 1M --decode-threads 4 --prefetch-threads 1 --write-threads 2 --runtime 60 --random-read
```

## Notes

- the current version uses `pread()` and `pwrite()`
- `io_uring` remains a planned next step
- the benchmark prints per-role totals plus decode latency percentiles
