#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <file-path> <fio-job>" >&2
  exit 1
fi

TARGET_FILE="$1"
JOB="$2"
JOB_NAME="$(basename "$JOB" .fio)"

echo "[kv-io] kv-aware run"
echo "file:   $TARGET_FILE"
echo "job:    $JOB"
echo "mode:   experimental placeholder"

mkdir -p results/raw
fio --filename="$TARGET_FILE" "$JOB" --output="results/raw/kvio-${JOB_NAME}.json" --output-format=json
