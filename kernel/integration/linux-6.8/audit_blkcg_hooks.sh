#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# audit_blkcg_hooks.sh — Audit Linux 6.8 kernel source for blk-cgroup
# hook points relevant to the Kairo AI I/O controller (Stage 16).
#
# Usage:
#   ./audit_blkcg_hooks.sh /path/to/linux-6.8 [--stdout]
#
# If --stdout is given, results are printed to stdout instead of using
# a pager.  If no Linux tree is provided, a dry-run summary is printed.

set -euo pipefail

LINUX_TREE="${1:-}"
MODE="${2:---pager}"

if [[ -z "$LINUX_TREE" || ! -d "$LINUX_TREE" ]]; then
  cat <<EOF
[audit_blkcg_hooks] No Linux source tree provided (or not found).
[audit_blkcg_hooks] Run with:
    ./audit_blkcg_hooks.sh /path/to/linux-6.8

Skipping real audit.  Known candidate hook points (Linux 6.8):

  block/blk-cgroup.c
    struct blkcg
    struct blkcg_gq
    blkg_lookup()
    blkcg_policy_register()
    blkcg_policy_unregister()

  block/blk-iocost.c
    ioc_weight_parse()          (cgroup file write pattern)
    ioc_pd_alloc()              (per-blkg allocation pattern)

  block/blk-throttle.c
    throtl_pd_alloc()
    throtl_pd_free()
    throtl_pd_init()

  include/linux/blk-cgroup.h
    struct blkcg_policy
    bio_blkcg()                 (get cgroup from bio)
    blkg_to_pd()                (get policy data from blkg)

EOF
  exit 0
fi

[[ -d "$LINUX_TREE" ]] || { echo "error: not a directory: $LINUX_TREE" >&2; exit 1; }
[[ -f "$LINUX_TREE/block/blk-cgroup.c" ]] || { echo "error: $LINUX_TREE/block/blk-cgroup.c not found" >&2; exit 1; }

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

# blk-cgroup core symbols
check "block/blk-cgroup.c" "struct blkcg" "core cgroup structure"
check "block/blk-cgroup.c" "struct blkcg_gq" "per-queue cgroup structure"
check "block/blk-cgroup.c" "blkg_lookup" "find blkcg_gq from cgroup"
check "block/blk-cgroup.c" "blkcg_policy_register" "register policy"
check "block/blk-cgroup.c" "blkcg_policy_unregister" "unregister policy"

# blk-iocost patterns
check "block/blk-iocost.c" "ioc_weight_parse" "weight parse helper"
check "block/blk-iocost.c" "ioc_pd_alloc" "per-blkg alloc pattern"
check "block/blk-iocost.c" "ioc_pd_free" "per-blkg free pattern"

# blk-throttle patterns
check "block/blk-throttle.c" "throtl_pd_alloc" "per-blkg alloc"
check "block/blk-throttle.c" "throtl_pd_free" "per-blkg free"
check "block/blk-throttle.c" "throtl_pd_init" "per-blkg init"

# blk-cgroup header
check "include/linux/blk-cgroup.h" "struct blkcg_policy" "policy registration struct"
check "include/linux/blk-cgroup.h" "bio_blkcg" "get cgroup from bio"
check "include/linux/blk-cgroup.h" "blkg_to_pd" "get policy data from blkg"

# Review: candidates for future hook placement
review "block/blk-cgroup.c" "blkcg_activate_policy" "policy activation hook point"
review "block/blk-cgroup.c" "blkcg_deactivate_policy" "policy deactivation hook point"
review "block/blk-cgroup.c" "bio_associate_blkg_from_css" "bio-to-cgroup association"

# Summary
total=$((PASS + MISS + REVIEW))
cat <<EOF

=== blk-cgroup Hook Audit ===
Linux tree: $LINUX_TREE

Results:
  FOUND:   $PASS
  MISSING: $MISS
  REVIEW:  $REVIEW
  TOTAL:   $total

$RESULTS
EOF

if [[ "$MISS" -gt 0 ]]; then
  echo "[audit_blkcg_hooks] Some expected symbols were not found."
  echo "[audit_blkcg_hooks] This may be expected for kernel versions != 6.8"
fi
