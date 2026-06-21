#!/usr/bin/env python3
"""
Parse kairo_bench summary output lines (key=value) from one or more log files.

Usage:
    python3 parse_kairo_bench_summary.py results/stage3/*/bench.log

Output (default: key=value per file):
    file=<path>
    decode_p99_us=...
    decode_p95_us=...
    ...

With --csv, output CSV with one header row and one data row per file.
"""

import argparse
import re
import sys


def parse_log(path):
    """Parse key=value lines from a kairo_bench log file."""
    kv = {"file": path}
    pattern = re.compile(r"^(\w[\w_]+)=(.+)$")
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            m = pattern.match(line)
            if m:
                kv[m.group(1)] = m.group(2).strip()
    return kv


def main():
    parser = argparse.ArgumentParser(
        description="Parse kairo_bench summary key=value output"
    )
    parser.add_argument("files", nargs="+", help="kairo_bench log files")
    parser.add_argument("--csv", action="store_true", help="Output CSV format")
    args = parser.parse_args()

    all_kv = []
    seen_keys = set()

    for path in args.files:
        kv = parse_log(path)
        all_kv.append(kv)
        seen_keys.update(kv.keys())

    keys = sorted(seen_keys)

    if args.csv:
        sys.stdout.write(",".join(keys) + "\n")
        for kv in all_kv:
            row = [kv.get(k, "") for k in keys]
            sys.stdout.write(",".join(row) + "\n")
    else:
        for kv in all_kv:
            for k in sorted(kv.keys()):
                sys.stdout.write(f"{k}={kv[k]}\n")
            sys.stdout.write("---\n")


if __name__ == "__main__":
    main()
