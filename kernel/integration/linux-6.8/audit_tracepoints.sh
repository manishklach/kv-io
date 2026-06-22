#!/usr/bin/env bash
# Stage 8: Audit Kairo tracepoint support in a Linux 6.8 tree.
#
# Checks for:
#   - Standard tracepoint infrastructure (include/trace/events/, define_trace.h)
#   - Kairo-specific tracepoint header and symbols (if a patched tree is supplied)
#
# Usage:
#   ./audit_tracepoints.sh /path/to/linux-6.8 [--stdout]
#
# If --stdout is given, output goes to stdout instead of a results file.
# If the tree is unpatched, only infrastructure checks are performed.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"

LINUX_TREE=""
STDOUT_MODE=false

fail() {
  echo "[audit-tracepoints] ERROR: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 <path-to-linux-6.8> [--stdout]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stdout) STDOUT_MODE=true; shift ;;
    -*)
      if [[ -z "$LINUX_TREE" ]]; then
        LINUX_TREE="$1"
      else
        usage
      fi
      shift ;;
    *)
      if [[ -z "$LINUX_TREE" ]]; then
        LINUX_TREE="$1"
      else
        usage
      fi
      shift ;;
  esac
done

if [[ -z "$LINUX_TREE" ]]; then
  usage
fi

[[ -d "$LINUX_TREE" ]] || fail "Linux source tree not found: $LINUX_TREE"

RESULTS_DIR="$REPO_ROOT/results/kernel-audit"
RESULTS_FILE="$RESULTS_DIR/tracepoints-$TIMESTAMP.log"

if ! $STDOUT_MODE; then
  mkdir -p "$RESULTS_DIR"
  exec > "$RESULTS_FILE" 2>&1
fi

echo "Kairo Tracepoint Audit"
echo "======================"
echo "Linux tree: $LINUX_TREE"
echo "Timestamp:  $TIMESTAMP"
echo ""

failed=0
pass_count=0
fail_count=0

check_present() {
  local file="$1" symbol="$2" label="$3"
  local full_path="$LINUX_TREE/$file"
  if [[ ! -f "$full_path" ]]; then
    echo "  FAIL   $label: file not found: $file"
    ((fail_count++)) || true
    return
  fi
  if grep -q "$symbol" "$full_path" 2>/dev/null; then
    echo "  OK     $label"
    ((pass_count++)) || true
  else
    echo "  FAIL   $label: '$symbol' not found in $file"
    ((fail_count++)) || true
  fi
}

echo "--- Standard tracepoint infrastructure ---"

check_present "include/trace/events" "" "include/trace/events/ directory exists"
check_present "include/trace/define_trace.h" "TRACE_EVENT" "define_trace.h with TRACE_EVENT"
check_present "include/trace/define_trace.h" "TRACE_SYSTEM" "define_trace.h with TRACE_SYSTEM"
check_present "include/linux/tracepoint.h" "DECLARE_EVENT_CLASS" "tracepoint.h with DECLARE_EVENT_CLASS"

echo ""
echo "--- Tracepoint-enabled block layer files ---"

check_present "block/mq-deadline.c" "DEFINE_EVENT" "mq-deadline: trace event macros"
check_present "block/blk-mq.c" "trace_" "blk-mq: trace function calls"
check_present "block/blk-merge.c" "trace_" "blk-merge: trace function calls"

echo ""
echo "--- Kairo-specific tracepoint checks ---"

if [[ -f "$LINUX_TREE/include/trace/events/kairo.h" ]]; then
  echo "  FOUND  include/trace/events/kairo.h (patched tree)"
  check_present "include/trace/events/kairo.h" "TRACE_SYSTEM kairo" "kairo.h: TRACE_SYSTEM kairo"
  check_present "include/trace/events/kairo.h" "kairo_request_classified" "kairo_request_classified tracepoint"
  check_present "include/trace/events/kairo.h" "kairo_scheduler_decision" "kairo_scheduler_decision tracepoint"
  check_present "include/trace/events/kairo.h" "kairo_decode_dispatch" "kairo_decode_dispatch tracepoint"
  check_present "include/trace/events/kairo.h" "kairo_prefetch_dispatch" "kairo_prefetch_dispatch tracepoint"
  check_present "include/trace/events/kairo.h" "kairo_write_demoted" "kairo_write_demoted tracepoint"
  check_present "include/trace/events/kairo.h" "kairo_merge_decision" "kairo_merge_decision tracepoint"
  check_present "include/trace/events/kairo.h" "kairo_semantic_classified" "kairo_semantic_classified tracepoint"
  check_present "include/trace/events/kairo.h" "kairo_placement_classified" "kairo_placement_classified tracepoint"
  check_present "include/trace/events/kairo.h" "kairo_backend_mapped" "kairo_backend_mapped tracepoint"
else
  echo "  ABSENT include/trace/events/kairo.h (clean stock tree)"
fi

echo ""
echo "--- Summary ---"
echo "  Passed: $pass_count"
echo "  Failed: $fail_count"

if (( fail_count > 0 )); then
  echo ""
  echo "Some checks failed. Review FAIL lines above."
  exit 1
fi

echo "  All checks passed."
exit 0
