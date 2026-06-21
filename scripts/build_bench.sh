#!/usr/bin/env bash
set -euo pipefail

echo "[kv-io] building benchmark"
gcc -O2 -Wall -pthread -o kvio_bench bench/kvio_bench.c
