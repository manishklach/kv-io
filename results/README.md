# Results

This directory is intentionally empty by default.

Suggested layout:

- `raw/` for direct benchmark outputs such as `fio` JSON
- `stats/` for `iostat`, `nvme-cli`, trace, and debug snapshots
- summary plots or markdown reports committed only after runs are reproducible

When publishing numbers, record:

- SSD model
- kernel version
- scheduler configuration
- benchmark parameters
- whether KV-aware kernel patches were applied
