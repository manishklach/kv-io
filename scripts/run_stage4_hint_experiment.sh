#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BENCH_PATH="$REPO_ROOT/kairo_bench"
BENCH_SOURCE="$REPO_ROOT/bench/kairo_bench.c"
COLLECT="$SCRIPT_DIR/collect_kairo_counters.sh"
PARSE="$SCRIPT_DIR/parse_kairo_bench_summary.py"
RESULTS_DIR="$REPO_ROOT/results/stage4/$(date +%Y%m%d-%H%M%S)"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <file-path> <block-device>" >&2
  exit 1
fi

FILE="$1"
DEV="$2"
IOSCHED_DIR="/sys/block/$DEV/queue/iosched"

if [[ ! -x "$BENCH_PATH" ]]; then
  echo "error: expected benchmark at $BENCH_PATH" >&2
  echo "build it first: gcc -O2 -Wall -pthread -Iinclude -o kairo_bench bench/kairo_bench.c" >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR"

counter_delta() {
  local before_dir="$1"
  local after_dir="$2"
  local counter="$3"
  local before_val=0
  local after_val=0

  [[ -f "$before_dir/$counter.txt" ]] && before_val=$(cat "$before_dir/$counter.txt" 2>/dev/null || echo 0)
  [[ -f "$after_dir/$counter.txt" ]] && after_val=$(cat "$after_dir/$counter.txt" 2>/dev/null || echo 0)
  echo $(( after_val - before_val ))
}

run_case() {
  local case_name="$1"
  local hint_mode="$2"
  local case_dir="$RESULTS_DIR/$case_name"
  mkdir -p "$case_dir"

  if [[ -w "$IOSCHED_DIR/kairo_enable" ]]; then
    echo "1" | sudo tee "$IOSCHED_DIR/kairo_enable" >/dev/null
  fi

  "$COLLECT" "$DEV" "$case_dir/before" 2>/dev/null || true

  "$BENCH_PATH" \
    --file "$FILE" \
    --mode mixed \
    --hint-mode "$hint_mode" \
    --runtime 20 \
    --decode-threads 4 \
    --prefetch-threads 2 \
    --write-threads 2 \
    --evict-threads 1 \
    --block-size 1M \
    --size 4G \
    2>&1 | tee "$case_dir/bench.log"

  "$COLLECT" "$DEV" "$case_dir/after" 2>/dev/null || true

  if command -v python3 >/dev/null 2>&1 && [[ -f "$PARSE" ]]; then
    python3 "$PARSE" "$case_dir/bench.log" > "$case_dir/parsed.log"
  fi

  local decode_p99 decode_p95 ioprio_decode_ok ioprio_decode_fail
  local rwf_decode_attempts rwf_decode_fail hinted_delta unhinted_delta dispatch_delta

  decode_p99=$(grep '^decode_p99_us=' "$case_dir/bench.log" | tail -n1 | cut -d= -f2-)
  decode_p95=$(grep '^decode_p95_us=' "$case_dir/bench.log" | tail -n1 | cut -d= -f2-)
  ioprio_decode_ok=$(grep '^ioprio_decode_ok=' "$case_dir/bench.log" | tail -n1 | cut -d= -f2-)
  ioprio_decode_fail=$(grep '^ioprio_decode_fail=' "$case_dir/bench.log" | tail -n1 | cut -d= -f2-)
  rwf_decode_attempts=$(grep '^rwf_decode_attempts=' "$case_dir/bench.log" | tail -n1 | cut -d= -f2-)
  rwf_decode_fail=$(grep '^rwf_decode_fail=' "$case_dir/bench.log" | tail -n1 | cut -d= -f2-)
  hinted_delta=$(counter_delta "$case_dir/before" "$case_dir/after" "kairo_hinted_requests")
  unhinted_delta=$(counter_delta "$case_dir/before" "$case_dir/after" "kairo_unhinted_requests")
  dispatch_delta=$(counter_delta "$case_dir/before" "$case_dir/after" "kairo_decode_dispatches")

  {
    echo "case=$case_name"
    echo "hint_mode=$hint_mode"
    echo "decode_p99_us=${decode_p99:-0}"
    echo "decode_p95_us=${decode_p95:-0}"
    echo "ioprio_decode_ok=${ioprio_decode_ok:-0}"
    echo "ioprio_decode_fail=${ioprio_decode_fail:-0}"
    echo "rwf_decode_attempts=${rwf_decode_attempts:-0}"
    echo "rwf_decode_fail=${rwf_decode_fail:-0}"
    echo "kairo_hinted_requests_delta=$hinted_delta"
    echo "kairo_unhinted_requests_delta=$unhinted_delta"
    echo "kairo_decode_dispatches_delta=$dispatch_delta"
  } | tee "$case_dir/summary.log"
}

run_case "01-ioprio" "ioprio"
run_case "02-rwf" "rwf"
run_case "03-both" "both"

echo "results_dir=$RESULTS_DIR"
