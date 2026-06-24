#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# audit_io_uring_hooks.sh — Audit Linux 6.8 kernel source for io_uring
# hook points relevant to the Kairo KV region hint scaffold (Stage 17).
#
# Usage:
#   ./audit_io_uring_hooks.sh /path/to/linux-6.8 [--stdout]
#
# If --stdout is given, results are printed to stdout instead of using
# a pager.  If no Linux tree is provided, a dry-run summary is printed.

set -euo pipefail

LINUX_TREE="${1:-}"
MODE="${2:---pager}"

if [[ -z "$LINUX_TREE" || ! -d "$LINUX_TREE" ]]; then
  cat <<EOF
[audit_io_uring_hooks] No Linux source tree provided (or not found).
[audit_io_uring_hooks] Run with:
    ./audit_io_uring_hooks.sh /path/to/linux-6.8

Skipping real audit.  Known candidate hook points (Linux 6.8):

  io_uring/io_uring.c
    io_init_req()           (request init)
    io_issue_sqe()          (SQE issue)
    io_uring_register()     (registration dispatch)
    IORING_REGISTER_BUFFERS (buffer registration)
    IORING_REGISTER_FILES   (file registration)

  io_uring/rw.c
    io_read()               (read path)
    io_write()              (write path)

  io_uring/opdef.c
    io_op_defs[]            (operation definition table)

  include/uapi/linux/io_uring.h
    IORING_REGISTER_BUFFERS (opcode constant)
    IORING_REGISTER_FILES   (opcode constant)

EOF
  exit 0
fi

[[ -d "$LINUX_TREE" ]] || { echo "error: not a directory: $LINUX_TREE" >&2; exit 1; }
[[ -f "$LINUX_TREE/io_uring/io_uring.c" ]] || { echo "error: $LINUX_TREE/io_uring/io_uring.c not found" >&2; exit 1; }

RESULTS=""
PASS=0
MISS=0
REVIEW=0

check() {
  local file="$1" symbol="$2" tag="$3"
  local full_path="$LINUX_TREE/$file"
  if [[ ! -f "$full_path" ]]; then
    RESULTS+="MISSING  $file ($tag)\n"
    MISS=$((MISS + 1))
    return
  fi
  if grep -qF "$symbol" "$full_path"; then
    RESULTS+="FOUND    $file: $symbol ($tag)\n"
    PASS=$((PASS + 1))
  else
    RESULTS+="MISSING  $file: $symbol ($tag)\n"
    MISS=$((MISS + 1))
  fi
}

review() {
  local file="$1" pattern="$2" note="$3"
  local full_path="$LINUX_TREE/$file"
  if [[ ! -f "$full_path" ]]; then
    RESULTS+="MISSING  $file ($note)\n"
    MISS=$((MISS + 1))
    return
  fi
  if grep -qF "$pattern" "$full_path"; then
    RESULTS+="REVIEW   $file: $pattern ($note)\n"
    REVIEW=$((REVIEW + 1))
  else
    RESULTS+="MISSING  $file: $pattern ($note)\n"
    MISS=$((MISS + 1))
  fi
}

# io_uring core symbols
check "io_uring/io_uring.c" "io_init_req" "request init function"
check "io_uring/io_uring.c" "io_issue_sqe" "SQE issue function"
check "io_uring/io_uring.c" "io_uring_register" "registration dispatch"
check "io_uring/io_uring.c" "IORING_REGISTER_BUFFERS" "buffer registration"
check "io_uring/io_uring.c" "IORING_REGISTER_FILES" "file registration"

# io_uring read/write path
check "io_uring/rw.c" "io_read" "read path"
check "io_uring/rw.c" "io_write" "write path"

# io_uring opdef
check "io_uring/opdef.c" "io_op_defs" "operation definition table"

# uapi header
check "include/uapi/linux/io_uring.h" "IORING_REGISTER_BUFFERS" "uapi constant"
check "include/uapi/linux/io_uring.h" "IORING_REGISTER_FILES" "uapi constant"

# Review: candidates for future hook placement
review "io_uring/io_uring.c" "io_kiocb" "per-IO request struct"
review "io_uring/io_uring.c" "io_alloc_req" "request allocation point"
review "io_uring/rw.c" "struct io_rw" "read/write request struct"

# Summary
total=$((PASS + MISS + REVIEW))
cat <<EOF

=== io_uring Hook Audit ===
Linux tree: $LINUX_TREE

Results:
  FOUND:   $PASS
  MISSING: $MISS
  REVIEW:  $REVIEW
  TOTAL:   $total

$RESULTS
EOF

if [[ "$MISS" -gt 0 ]]; then
  echo "[audit_io_uring_hooks] Some expected symbols were not found."
  echo "[audit_io_uring_hooks] This may be expected for kernel versions != 6.8"
fi
