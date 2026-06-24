#!/usr/bin/env bash
#
# run_stage10_latency_controller_experiment.sh
#
# Stage 10: adaptive decode tail-latency controller experiment harness.
#
# Runs six canonical cases comparing static vs controller-driven scheduling
# under decode pressure, prefetch-heavy, and write-heavy workloads.
#
# Usage:
#   ./run_stage10_latency_controller_experiment.sh <file-path> <block-device> [options]
#
# Options:
#   --duration SEC          Per-case runtime in seconds (default: 30)
#   --bench PATH            Benchmark binary path
#   --results-dir PATH      Override output directory
#   --hint-mode MODE        ioprio|rwf|both (default: both)
#   --skip-counters         Skip sysfs counter collection
#   --dry-run               Print commands without executing
#   --help                  Show this help

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# ---- defaults ----
FILE_PATH=""
BLOCK_DEVICE=""
DURATION=30
HINT_MODE="both"
SKIP_COUNTERS=false
DRY_RUN=false
RESULTS_DIR=""

# ---- arg parsing ----
usage() {
  sed -n 's/^# \?//p' "$0" | head -50
  exit 0
}

resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PWD" "$path"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --bench) BENCH_PATH="$2"; shift 2 ;;
    --results-dir) RESULTS_DIR="$2"; shift 2 ;;
    --hint-mode) HINT_MODE="$2"; shift 2 ;;
    --skip-counters) SKIP_COUNTERS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage ;;
    --*) echo "Unknown option: $1"; usage ;;
    *)
      if [[ -z "$FILE_PATH" ]]; then
        FILE_PATH="$(resolve_path "$1")"
      elif [[ -z "$BLOCK_DEVICE" ]]; then
        BLOCK_DEVICE="$1"
      else
        echo "Unexpected argument: $1"; usage
      fi
      shift
      ;;
  esac
done

if [[ -z "$FILE_PATH" || -z "$BLOCK_DEVICE" ]]; then
  echo "Usage: $0 <file-path> <block-device> [options]"
  exit 1
fi

# ---- helper functions ----
dry_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[DRY_RUN] %s\n' "$*"
  else
    "$@"
  fi
}

COUNTER_NAMES=(
  kairo_decode_dispatches
  kairo_normal_dispatches
  kairo_prefetch_dispatches
  kairo_prefill_dispatches
  kairo_evict_dispatches
  kairo_prefill_demotions
  kairo_evict_demotions
  kairo_starvation_escapes
  # Stage 10 controller counters
  kairo_controller_updates
  kairo_controller_boost_events
  kairo_controller_relax_events
  kairo_controller_prefetch_throttles
  kairo_controller_write_releases
  kairo_controller_insufficient_samples
)

collect_counters() {
  local label="$1"
  local sysfs_dir="/sys/block/$BLOCK_DEVICE/mq-deadline"
  local outdir="$RESULTS_DIR/$label/counters-before"
  if [[ "$2" == "after" ]]; then
    outdir="$RESULTS_DIR/$label/counters-after"
  fi
  mkdir -p "$outdir"
  for c in "${COUNTER_NAMES[@]}"; do
    local path="$sysfs_dir/$c"
    if [[ -r "$path" ]]; then
      dry_cmd sh -c "cat '$path' > '$outdir/$c'"
    fi
  done
}

bench_exe() {
  if [[ -n "${BENCH_PATH:-}" ]]; then
    printf '%s\n' "$BENCH_PATH"
  elif [[ -x "$REPO_ROOT/build/bench/kairo_bench" ]]; then
    printf '%s\n' "$REPO_ROOT/build/bench/kairo_bench"
  elif [[ -x "$REPO_ROOT/bench/kairo_bench" ]]; then
    printf '%s\n' "$REPO_ROOT/bench/kairo_bench"
  else
    printf '%s\n' "kairo_bench"
  fi
}

run_case() {
  local case_name="$1"
  shift
  local case_desc="$1"
  shift
  # remaining args are extra benchmark options

  local case_dir="$RESULTS_DIR/$case_name"
  mkdir -p "$case_dir"
  printf '%s\n' "$case_desc" > "$case_dir/command.txt"

  echo "[stage10] Case: $case_name - $case_desc"

  # Collect pre-run counters
  if [[ "$SKIP_COUNTERS" != true ]]; then
    collect_counters "$case_name" "before"
  fi

  # Build benchmark command
  local bench_cmd="$(bench_exe) --duration $DURATION --hint-mode $HINT_MODE"
  if [[ "$case_name" == *"baseline"* ]]; then
    bench_cmd="$bench_cmd --decode-ratio 0.3 --prefetch-ratio 0.3 --write-ratio 0.3"
  elif [[ "$case_name" == *"decode-pressure"* ]]; then
    bench_cmd="$bench_cmd --decode-ratio 0.7 --prefetch-ratio 0.15 --write-ratio 0.1"
  elif [[ "$case_name" == *"prefetch-heavy"* ]]; then
    bench_cmd="$bench_cmd --decode-ratio 0.2 --prefetch-ratio 0.6 --write-ratio 0.15"
  elif [[ "$case_name" == *"write-heavy"* ]]; then
    bench_cmd="$bench_cmd --decode-ratio 0.2 --prefetch-ratio 0.2 --write-ratio 0.55"
  fi
  bench_cmd="$bench_cmd $*"

  # Detect controller knobs
  local ctrl_sysfs="/sys/block/$BLOCK_DEVICE/mq-deadline/kairo_controller_enable"

  if [[ "$case_name" == *"controller-adaptive"* ]]; then
    if [[ -w "$ctrl_sysfs" ]]; then
      dry_cmd sh -c "echo 2 > '$ctrl_sysfs' 2>/dev/null || true"
    fi
  elif [[ "$case_name" == *"controller-observe"* ]]; then
    if [[ -w "$ctrl_sysfs" ]]; then
      dry_cmd sh -c "echo 1 > '$ctrl_sysfs' 2>/dev/null || true"
    fi
  else
    if [[ -w "$ctrl_sysfs" ]]; then
      dry_cmd sh -c "echo 0 > '$ctrl_sysfs' 2>/dev/null || true"
    fi
  fi

  # Run benchmark
  local bench_log="$case_dir/bench.log"
  local summary_log="$case_dir/summary.log"
  dry_cmd sh -c "$bench_cmd 2>&1" > "$bench_log" || true
  dry_cmd sh -c "$bench_cmd --stats-only 2>&1 || true" > "$summary_log"

  # Collect post-run counters
  if [[ "$SKIP_COUNTERS" != true ]]; then
    collect_counters "$case_name" "after"
  fi

  # Reset controller
  if [[ -w "$ctrl_sysfs" ]]; then
    dry_cmd sh -c "echo 0 > '$ctrl_sysfs' 2>/dev/null || true"
  fi

  echo "[stage10] Case $case_name done."
}

# ---- setup ----
if [[ -z "$RESULTS_DIR" ]]; then
  RESULTS_DIR="$REPO_ROOT/results/stage10/$(date -u +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RESULTS_DIR"

# Copy this script into results for reproducibility
dry_cmd cp "$0" "$RESULTS_DIR/"

echo "[stage10] Stage 10 Adaptive Latency Controller Experiment"
echo "[stage10] File: $FILE_PATH"
echo "[stage10] Device: $BLOCK_DEVICE"
echo "[stage10] Duration: ${DURATION}s per case"
echo "[stage10] Hint mode: $HINT_MODE"
echo "[stage10] Results: $RESULTS_DIR"
echo ""

# ---- canonical cases ----

# Case 1: baseline static
run_case "01-baseline-static" \
  "baseline static: read-mostly, no controller" \
  "--file $FILE_PATH --device $BLOCK_DEVICE"

# Case 2: decode pressure static
run_case "02-decode-pressure-static" \
  "decode pressure static: high decode ratio, no controller" \
  "--file $FILE_PATH --device $BLOCK_DEVICE"

# Case 3: decode pressure with controller in OBSERVE mode
run_case "03-decode-pressure-controller-observe" \
  "decode pressure observe: controller collects stats only" \
  "--file $FILE_PATH --device $BLOCK_DEVICE"

# Case 4: decode pressure with ADAPTIVE controller
run_case "04-decode-pressure-controller-adaptive" \
  "decode pressure adaptive: controller adjusts budgets based on observed p99" \
  "--file $FILE_PATH --device $BLOCK_DEVICE"

# Case 5: prefetch-heavy with ADAPTIVE controller
run_case "05-prefetch-heavy-controller-adaptive" \
  "prefetch heavy adaptive: prefetch-heavy workload with controller" \
  "--file $FILE_PATH --device $BLOCK_DEVICE"

# Case 6: write-heavy with ADAPTIVE controller
run_case "06-write-heavy-controller-adaptive" \
  "write heavy adaptive: write-heavy workload with controller" \
  "--file $FILE_PATH --device $BLOCK_DEVICE"

# ---- summary ----
echo ""
echo "[stage10] All cases complete."
echo "[stage10] Generating summary.csv..."
SUMMARY_CSV="$RESULTS_DIR/summary.csv"
printf "case,controller_mode,target_decode_p99_us,decode_p99_us,decode_p95_us,decode_avg_us,write_MBps,prefetch_read_MBps,adaptive_decode_budget,adaptive_prefetch_budget\n" > "$SUMMARY_CSV"
for case_dir in "$RESULTS_DIR"/*/; do
  case_name="$(basename "$case_dir")"
  if [[ -f "$case_dir/summary.log" ]]; then
    # Extract fields from summary.log (parser will handle full detail)
    printf "%s,NA,NA,NA,NA,NA,NA,NA,NA,NA\n" "$case_name" >> "$SUMMARY_CSV"
  fi
done

echo "[stage10] Summary: $SUMMARY_CSV"
echo "[stage10] Done."
