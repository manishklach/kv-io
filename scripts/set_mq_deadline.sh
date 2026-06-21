#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <block-device>" >&2
  exit 1
fi

DEV="$1"
echo mq-deadline | sudo tee "/sys/block/$DEV/queue/scheduler" >/dev/null
cat "/sys/block/$DEV/queue/scheduler"
