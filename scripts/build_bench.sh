#!/usr/bin/env bash
set -euo pipefail

echo "[kairo] building benchmark"
gcc -O2 -Wall -pthread -Iinclude -o kairo_bench bench/kairo_bench.c
