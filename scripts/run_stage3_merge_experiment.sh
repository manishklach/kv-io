#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BENCH_DIR="$REPO_ROOT/bench"
RESULTS_DIR="$REPO_ROOT/results/stage3/$(date +%Y%m%d-%H%M%S)"
COLLECT="$SCRIPT_DIR/collect_kairo_counters.sh"
PARSE="$SCRIPT_DIR/parse_kairo_bench_summary.py"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <file-path> <block-device>" >&2
  echo
  echo "  file-path      path to the test file (e.g., /mnt/test/kairo.bin)"
  echo "  block-device   device name for sysfs counters (e.g., nvme0n1)"
  exit 1
fi

FILE="$1"
DEV="$2"

if [[ ! -x "$BENCH_DIR/kairo_bench" ]] && [[ ! -f "$BENCH_DIR/kairo_bench.c" ]]; then
  echo "error: kairo_bench not found in $BENCH_DIR" >&2
  echo "Build it first: cd $BENCH_DIR && make kairo_bench" >&2
  exit 1
fi

BENCH="$BENCH_DIR/kairo_bench"
if [[ ! -x "$BENCH" ]]; then
  echo "warning: kairo_bench not compiled, using source path" >&2
  BENCH="$BENCH_DIR/kairo_bench.c"
fi

mkdir -p "$RESULTS_DIR"
echo "results dir: $RESULTS_DIR"

run_case() {
  local case_name="$1"
  local kairo_enable="$2"
  local merge_bias="$3"
  local access_pattern="$4"
  local fragment_size="$5"
  shift 5

  local case_dir="$RESULTS_DIR/$case_name"
  mkdir -p "$case_dir"

  # collect before-counters
  "$COLLECT" "$DEV" "$case_dir/before" 2>/dev/null || true

  echo "--- Running: $case_name ---"
  set +e
  if [[ "$BENCH" == *.c ]]; then
    echo "  (benchmark source only - run manually or build first)"
    echo "  expected command:"
    echo "    $BENCH_DIR/kairo_bench --file $FILE --mode mixed \\"
    echo "      --access-pattern $access_pattern --runtime 30 \\"
    [ -n "$fragment_size" ] && echo "      --fragment-size $fragment_size \\"
    echo "      ${@:+$@}"
    # write a placeholder log
    echo "kairo_bench summary" > "$case_dir/bench.log"
    echo "mode=mixed" >> "$case_dir/bench.log"
    echo "access_pattern=$access_pattern" >> "$case_dir/bench.log"
    echo "fragment_size_bytes=${fragment_size:-0}" >> "$case_dir/bench.log"
  else
    local bench_args=(
      --file "$FILE"
      --mode mixed
      --access-pattern "$access_pattern"
      --runtime 30
    )
    if [[ -n "$fragment_size" ]]; then
      bench_args+=(--fragment-size "$fragment_size")
    fi
    "$BENCH" "${bench_args[@]}" "$@" 2>&1 | tee "$case_dir/bench.log"
  fi
  set -e

  # collect after-counters
  "$COLLECT" "$DEV" "$case_dir/after" 2>/dev/null || true

  # compute deltas
  if command -v python3 &>/dev/null && [[ -f "$PARSE" ]]; then
    python3 "$PARSE" "$case_dir/bench.log" > "$case_dir/parsed.log" 2>/dev/null || true
  fi

  echo "--- Completed: $case_name ---"
  echo ""
}

# Experiment 1: merge-friendly baseline (Kairo disabled)
run_case \
  "01-merge-friendly-baseline" \
  "0" "0" "sequential" "" \
  --decode-threads 4 --prefetch-threads 2 --write-threads 2 \
  --block-size 1M --size 4G

# Experiment 2: merge-friendly Kairo enabled
run_case \
  "02-merge-friendly-kairo" \
  "1" "1" "sequential" "" \
  --decode-threads 4 --prefetch-threads 2 --write-threads 2 \
  --block-size 1M --size 4G

# Experiment 3: merge-hostile baseline (Kairo disabled)
run_case \
  "03-merge-hostile-baseline" \
  "0" "0" "random" "4K" \
  --decode-threads 4 --prefetch-threads 2 --write-threads 2 \
  --sessions 4 --models 2 \
  --block-size 1M --size 4G

# Experiment 4: merge-hostile Kairo enabled
run_case \
  "04-merge-hostile-kairo" \
  "1" "1" "random" "4K" \
  --decode-threads 4 --prefetch-threads 2 --write-threads 2 \
  --sessions 4 --models 2 \
  --block-size 1M --size 4G

# Experiment 5: strided access with Kairo
run_case \
  "05-strided-kairo" \
  "1" "1" "strided" "" \
  --decode-threads 4 --prefetch-threads 2 --write-threads 2 \
  --stride-blocks 16 --block-size 1M --size 4G

# Experiment 6: clustered access with Kairo
run_case \
  "06-clustered-kairo" \
  "1" "1" "clustered" "" \
  --decode-threads 4 --prefetch-threads 2 --write-threads 2 \
  --cluster-size-blocks 8 --block-size 1M --size 4G

echo "========================================"
echo "Stage 3 merge experiments complete"
echo "Results: $RESULTS_DIR"
echo "========================================"

# print summary across all cases
for case_dir in "$RESULTS_DIR"/*/; do
  if [[ -f "$case_dir/bench.log" ]]; then
    echo ""
    echo "=== $(basename "$case_dir") ==="
    grep -E 'decode_p99_us|decode_p95_us|decode_read_MBps|write_MBps' "$case_dir/bench.log" 2>/dev/null || true
    # print counter deltas if after counters exist
    if [[ -d "$case_dir/after" ]]; then
      for counter in kairo_merge_attempts kairo_merge_successes \
                     kairo_decode_merge_successes kairo_prefetch_merge_successes \
                     kairo_small_decode_reads kairo_large_decode_reads; do
        local before_val=0 after_val=0
        [[ -f "$case_dir/before/$counter.txt" ]] && before_val=$(cat "$case_dir/before/$counter.txt" 2>/dev/null || echo 0)
        [[ -f "$case_dir/after/$counter.txt" ]] && after_val=$(cat "$case_dir/after/$counter.txt" 2>/dev/null || echo 0)
        local delta=$(( after_val - before_val ))
        echo "${counter}_delta=${delta}"
      done
    fi
  fi
done
