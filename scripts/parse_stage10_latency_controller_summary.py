#!/usr/bin/env python3
"""
parse_stage10_latency_controller_summary.py

Parse Stage 10 latency controller experiment summary logs and emit
CSV or pretty-printed tables.

Usage:
  python3 parse_stage10_latency_controller_summary.py <summary-log>... [--csv|--pretty]
"""

import argparse
import csv
import glob
import os
import re
import sys


COUNTER_DELTA_FIELDS = [
    ("kairo_controller_updates", "kairo_controller_updates_delta"),
    ("kairo_controller_boost_events", "kairo_controller_boost_events_delta"),
    ("kairo_controller_relax_events", "kairo_controller_relax_events_delta"),
    ("kairo_controller_prefetch_throttles",
     "kairo_controller_prefetch_throttles_delta"),
    ("kairo_controller_write_releases",
     "kairo_controller_write_releases_delta"),
    ("kairo_controller_insufficient_samples",
     "kairo_controller_insufficient_samples_delta"),
]


def read_counter(path):
    """Read a single integer from a sysfs counter file, or None."""
    try:
        with open(path) as f:
            val = f.read().strip()
            return int(val)
    except (FileNotFoundError, ValueError, OSError):
        return None


def get_counters(case_dir, suffix):
    """Return dict of counter -> value from counters-{suffix}/ directory."""
    counter_dir = os.path.join(case_dir, f"counters-{suffix}")
    if not os.path.isdir(counter_dir):
        return {}
    result = {}
    for name in os.listdir(counter_dir):
        path = os.path.join(counter_dir, name)
        if os.path.isfile(path):
            val = read_counter(path)
            if val is not None:
                result[name] = val
    return result


def compute_deltas(before, after):
    """Compute after - before for each counter. Returns None if missing."""
    result = {}
    for name, label in COUNTER_DELTA_FIELDS:
        if name in before and name in after:
            result[label] = after[name] - before[name]
        else:
            result[label] = None
    return result


def parse_summary_log(summary_path):
    """Extract decode latency stats and throughput from a summary log."""
    fields = {
        "controller_mode": "NA",
        "target_decode_p99_us": "NA",
        "decode_p99_us": "NA",
        "decode_p95_us": "NA",
        "decode_avg_us": "NA",
        "write_MBps": "NA",
        "prefetch_read_MBps": "NA",
        "adaptive_decode_budget": "NA",
        "adaptive_prefetch_budget": "NA",
    }
    patterns = {
        "decode_p99_us": re.compile(r"decode_p99_us[=:]?\s*(\d+)"),
        "decode_p95_us": re.compile(r"decode_p95_us[=:]?\s*(\d+)"),
        "decode_avg_us": re.compile(r"decode_avg_us[=:]?\s*(\d+)"),
        "write_MBps": re.compile(r"write_(?:MBps|throughput)[=:]?\s*([\d.]+)"),
        "prefetch_read_MBps": re.compile(
            r"prefetch_(?:read_)?(?:MBps|throughput)[=:]?\s*([\d.]+)"
        ),
    }
    try:
        with open(summary_path) as f:
            text = f.read()
    except FileNotFoundError:
        return fields

    for key, pat in patterns.items():
        m = pat.search(text)
        if m:
            fields[key] = m.group(1)

    # Look for controller fields in the summary
    ctrl_pats = {
        "controller_mode": re.compile(r"controller_mode[=:]?\s*(\d+)"),
        "target_decode_p99_us": re.compile(r"target_decode_p99_us[=:]?\s*(\d+)"),
        "adaptive_decode_budget": re.compile(r"adaptive_decode_budget[=:]?\s*(\d+)"),
        "adaptive_prefetch_budget": re.compile(
            r"adaptive_prefetch_budget[=:]?\s*(\d+)"
        ),
    }
    for key, pat in ctrl_pats.items():
        m = pat.search(text)
        if m:
            fields[key] = m.group(1)

    return fields


def case_sort_key(case_name):
    """Sort cases by numeric prefix if present."""
    m = re.match(r"(\d+)-", case_name)
    if m:
        return (0, int(m.group(1)), case_name)
    return (1, 0, case_name)


def emit_csv(rows, outfile):
    writer = csv.DictWriter(outfile, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)


def emit_pretty(rows):
    col_widths = {}
    for row in rows:
        for key, val in row.items():
            col_widths[key] = max(col_widths.get(key, len(key)), len(str(val)))
    sep = "+" + "+".join("-" * (w + 2) for w in col_widths.values()) + "+"
    header = (
        "| "
        + " | ".join(k.ljust(col_widths[k]) for k in col_widths.keys())
        + " |"
    )
    print(sep)
    print(header)
    print(sep.replace("-", "="))
    for row in rows:
        line = (
            "| "
            + " | ".join(str(row[k]).ljust(col_widths[k]) for k in col_widths.keys())
            + " |"
        )
        print(line)
        print(sep)


def main():
    parser = argparse.ArgumentParser(
        description="Parse Stage 10 latency controller summary logs"
    )
    parser.add_argument("summary_logs", nargs="+", help="Path(s) to summary.log")
    parser.add_argument(
        "--csv", action="store_true", help="Output CSV (default)"
    )
    parser.add_argument(
        "--pretty", action="store_true", help="Pretty-print table"
    )
    args = parser.parse_args()

    # Expand globs
    paths = []
    for p in args.summary_logs:
        expanded = glob.glob(p)
        if expanded:
            paths.extend(expanded)
        else:
            paths.append(p)

    rows = []
    for path in paths:
        case_dir = os.path.dirname(path)
        case_name = os.path.basename(case_dir)

        fields = parse_summary_log(path)
        before = get_counters(case_dir, "before")
        after = get_counters(case_dir, "after")
        deltas = compute_deltas(before, after)

        row = {
            "case": case_name,
            "controller_mode": fields["controller_mode"],
            "target_decode_p99_us": fields["target_decode_p99_us"],
            "decode_p99_us": fields["decode_p99_us"],
            "decode_p95_us": fields["decode_p95_us"],
            "decode_avg_us": fields["decode_avg_us"],
            "write_MBps": fields["write_MBps"],
            "prefetch_read_MBps": fields["prefetch_read_MBps"],
            "adaptive_decode_budget": fields["adaptive_decode_budget"],
            "adaptive_prefetch_budget": fields["adaptive_prefetch_budget"],
        }
        for label, val in deltas.items():
            if val is None:
                row[label] = "NA"
            else:
                row[label] = val

        rows.append(row)

    if not rows:
        print("No summary logs found.", file=sys.stderr)
        sys.exit(1)

    rows.sort(key=lambda r: case_sort_key(r["case"]))

    use_csv = not args.pretty

    if use_csv:
        emit_csv(rows, sys.stdout)
    else:
        emit_pretty(rows)


if __name__ == "__main__":
    main()
