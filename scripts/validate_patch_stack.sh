#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PATCH_DIR="$REPO_ROOT/kernel/patches"

required_patches=(
  "0001-rfc-kairo-mq-deadline-decode-priority.patch"
  "0002-rfc-kairo-request-classification.patch"
  "0003-rfc-kairo-io-uring-hint-plumbing.patch"
  "0004-rfc-kairo-large-block-coalescing.patch"
  "0005-rfc-kairo-prefetch-deadline-hints.patch"
  "0006-rfc-kairo-ephemeral-cache-semantics.patch"
  "0007-rfc-kairo-placement-lifetime-hints.patch"
  "0008-rfc-kairo-nvme-zns-fdp-mapping.patch"
  "0009-rfc-kairo-sysfs-debug-counters.patch"
)

for patch in "${required_patches[@]}"; do
  if [[ ! -f "$PATCH_DIR/$patch" ]]; then
    echo "[kairo] missing patch: $patch" >&2
    exit 1
  fi
done

if ! grep -Eq 'kairo_is_decode_read|kairo_classify_rq' "$PATCH_DIR/0001-rfc-kairo-mq-deadline-decode-priority.patch"; then
  echo "[kairo] 0001 does not reference shared Kairo classification helpers" >&2
  exit 1
fi

if ! grep -q 'enum kairo_io_class' "$PATCH_DIR/0002-rfc-kairo-request-classification.patch"; then
  echo "[kairo] 0002 does not define enum kairo_io_class" >&2
  exit 1
fi

if ! grep -q 'kairo_should_bias_merge' "$PATCH_DIR/0004-rfc-kairo-large-block-coalescing.patch"; then
  echo "[kairo] 0004 does not define kairo_should_bias_merge" >&2
  exit 1
fi

if ! grep -q 'attempt_merge\|blk-merge' "$PATCH_DIR/0004-rfc-kairo-large-block-coalescing.patch"; then
  echo "[kairo] 0004 does not reference attempt_merge or blk-merge" >&2
  exit 1
fi

if ! grep -q 'kairo_decode_dispatches' "$PATCH_DIR/0009-rfc-kairo-sysfs-debug-counters.patch"; then
  echo "[kairo] 0009 does not expose kairo_decode_dispatches" >&2
  exit 1
fi

if ! grep -q 'kairo_merge_attempts' "$PATCH_DIR/0009-rfc-kairo-sysfs-debug-counters.patch"; then
  echo "[kairo] 0009 does not reference kairo_merge_attempts" >&2
  exit 1
fi

if ! grep -q 'kairo_merge_successes' "$PATCH_DIR/0009-rfc-kairo-sysfs-debug-counters.patch"; then
  echo "[kairo] 0009 does not reference kairo_merge_successes" >&2
  exit 1
fi

if ! grep -q 'access_pattern\|merge-friendly' "$REPO_ROOT/bench/kairo_bench.c"; then
  echo "[kairo] benchmark does not support access_pattern or merge-friendly mode" >&2
  exit 1
fi

echo "[kairo] patch stack consistency checks passed"
