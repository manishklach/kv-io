#!/usr/bin/env python3
"""
Stage 8: Parse Kairo ftrace/bpftrace trace logs into a structured summary.

Usage:
  python3 scripts/parse_stage8_trace_log.py results/stage8/*/trace/kairo_trace.log --csv
  python3 scripts/parse_stage8_trace_log.py results/stage8/*/trace/kairo_trace.log --pretty

The parser uses best-effort regex matching on ftrace output.
Limitations:
  - Full ftrace format varies by kernel version; adjust patterns if needed.
  - Multi-line trace entries are not supported.
  - Binary ftrace data is not supported.
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict


TP_PATTERNS = {
    "kairo_request_classified": re.compile(
        r"kairo_request_classified:\s+"
        r"dev=(?P<dev>\S+)\s+sector=(?P<sector>\S+)\s+nr_bytes=(?P<nr_bytes>\d+)"
    ),
    "kairo_scheduler_decision": re.compile(
        r"kairo_scheduler_decision:\s+"
        r"dev=(?P<dev>\S+)\s+.*io_class=(?P<io_class>\d+)"
    ),
    "kairo_decode_dispatch": re.compile(
        r"kairo_decode_dispatch:\s+"
        r"dev=(?P<dev>\S+)\s+.*nr_bytes=(?P<nr_bytes>\d+)"
    ),
    "kairo_prefetch_dispatch": re.compile(
        r"kairo_prefetch_dispatch:\s+"
        r"dev=(?P<dev>\S+)\s+.*nr_bytes=(?P<nr_bytes>\d+)"
    ),
    "kairo_write_demoted": re.compile(
        r"kairo_write_demoted:\s+"
        r"dev=(?P<dev>\S+)\s+.*io_class=(?P<io_class>\d+)"
    ),
    "kairo_merge_decision": re.compile(
        r"kairo_merge_decision:\s+"
        r"dev=(?P<dev>\S+)\s+.*io_class=(?P<io_class>\d+)"
    ),
    "kairo_semantic_classified": re.compile(
        r"kairo_semantic_classified:\s+"
        r"dev=(?P<dev>\S+)\s+.*ephemeral=(?P<ephemeral>\d+)"
    ),
    "kairo_placement_classified": re.compile(
        r"kairo_placement_classified:\s+"
        r"dev=(?P<dev>\S+)\s+.*lifetime=(?P<lifetime>\d+)"
    ),
    "kairo_backend_mapped": re.compile(
        r"kairo_backend_mapped:\s+"
        r"dev=(?P<dev>\S+)\s+.*backend_class=(?P<backend_class>\d+)"
        r".*noop_fallback=(?P<noop_fallback>\d+)"
    ),
}


def parse_file(filepath):
    """Parse a trace log file and return counts and byte totals per event."""
    counts = defaultdict(int)
    byte_totals = defaultdict(int)
    io_class_counts = defaultdict(lambda: defaultdict(int))
    backend_class_counts = defaultdict(lambda: defaultdict(int))

    if not os.path.isfile(filepath):
        print(f"Warning: file not found: {filepath}", file=sys.stderr)
        return counts, byte_totals, io_class_counts, backend_class_counts

    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            for tp_name, pattern in TP_PATTERNS.items():
                m = pattern.search(line)
                if m:
                    counts[tp_name] += 1
                    nr_bytes = int(m.group("nr_bytes")) if "nr_bytes" in m.groupdict() and m.group("nr_bytes") else 0
                    byte_totals[tp_name] += nr_bytes

                    if "io_class" in m.groupdict():
                        ic = m.group("io_class")
                        io_class_counts[tp_name][ic] += 1

                    if "backend_class" in m.groupdict():
                        bc = m.group("backend_class")
                        nf = m.group("noop_fallback") if "noop_fallback" in m.groupdict() else "?"
                        backend_class_counts[tp_name][(bc, nf)] += 1
                    break
    return counts, byte_totals, io_class_counts, backend_class_counts


def print_pretty(counts, byte_totals, io_class_counts, backend_class_counts):
    """Print a human-readable summary."""
    print("Kairo Trace Log Summary")
    print("=" * 60)

    if not counts:
        print("(no trace events found)")
        return

    print(f"{'Event':<40} {'Count':>10} {'Total Bytes':>15} {'Avg Bytes':>10}")
    print("-" * 75)
    for tp_name in sorted(counts.keys()):
        cnt = counts[tp_name]
        tb = byte_totals[tp_name]
        avg = tb // cnt if cnt > 0 else 0
        print(f"{tp_name:<40} {cnt:>10} {tb:>15} {avg:>10}")

    print()
    for tp_name in sorted(io_class_counts.keys()):
        print(f"  {tp_name} by io_class:")
        for ic, cnt in sorted(io_class_counts[tp_name].items()):
            print(f"    io_class={ic}: {cnt}")

    for tp_name in sorted(backend_class_counts.keys()):
        print(f"  {tp_name} by (backend_class, noop_fallback):")
        for (bc, nf), cnt in sorted(backend_class_counts[tp_name].items()):
            print(f"    backend_class={bc} noop_fallback={nf}: {cnt}")


def print_csv(counts, byte_totals, *_):
    """Print a CSV summary."""
    writer = csv.writer(sys.stdout)
    writer.writerow(["event", "count", "total_bytes", "avg_bytes"])
    for tp_name in sorted(counts.keys()):
        cnt = counts[tp_name]
        tb = byte_totals[tp_name]
        avg = tb // cnt if cnt > 0 else 0
        writer.writerow([tp_name, cnt, tb, avg])


def main():
    parser = argparse.ArgumentParser(
        description="Parse Kairo ftrace/bpftrace trace logs"
    )
    parser.add_argument("files", nargs="+", help="Trace log files to parse")
    parser.add_argument("--csv", action="store_true", help="Output CSV format")
    parser.add_argument("--pretty", action="store_true", help="Output pretty-printed table (default)")

    args = parser.parse_args()

    combined_counts = defaultdict(int)
    combined_bytes = defaultdict(int)
    combined_io_class = defaultdict(lambda: defaultdict(int))
    combined_backend_class = defaultdict(lambda: defaultdict(int))

    for f in args.files:
        c, b, ic, bc = parse_file(f)
        for k, v in c.items():
            combined_counts[k] += v
        for k, v in b.items():
            combined_bytes[k] += v
        for tp_name, ic_dict in ic.items():
            for ic_key, cnt in ic_dict.items():
                combined_io_class[tp_name][ic_key] += cnt
        for tp_name, bc_dict in bc.items():
            for bc_key, cnt in bc_dict.items():
                combined_backend_class[tp_name][bc_key] += cnt

    if args.csv:
        print_csv(combined_counts, combined_bytes)
    else:
        print_pretty(combined_counts, combined_bytes, combined_io_class, combined_backend_class)


if __name__ == "__main__":
    main()
