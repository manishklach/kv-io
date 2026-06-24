#!/usr/bin/env python3
"""
parse_stage12_fairness_summary.py

Parse Stage 12 fairness experiment summary logs and emit CSV or
pretty-printed tables with fairness counter delta columns.

Usage:
  python3 parse_stage12_fairness_summary.py <summary-log>... [--csv|--pretty]
"""

import argparse
import csv
import glob
import os
import re
import sys


FIELD_NAMES = [
    ("case", "case"),
    ("models", "models"),
    ("sessions", "sessions"),
    ("noisy_model", "noisy_model"),
    ("noisy_session", "noisy_session"),
    ("noisy_multiplier", "noisy_multiplier"),
    ("decode_p99_us", "decode_p99_us"),
    ("decode_p95_us", "decode_p95_us"),
    ("decode_avg_us", "decode_avg_us"),
    ("write_MBps", "write_MBps"),
    ("prefetch_read_MBps", "prefetch_read_MBps"),
    ("kairo_fairness_refills_delta", "kairo_fairness_refills_delta"),
    ("kairo_fairness_model_throttles_delta", "kairo_fairness_model_throttles_delta"),
    ("kairo_fairness_session_throttles_delta", "kairo_fairness_session_throttles_delta"),
    ("kairo_noisy_session_events_delta", "kairo_noisy_session_events_delta"),
    ("kairo_protected_decode_dispatches_delta", "kairo_protected_decode_dispatches_delta"),
    ("kairo_prefetch_fairness_throttles_delta", "kairo_prefetch_fairness_throttles_delta"),
    ("kairo_write_fairness_demotions_delta", "kairo_write_fairness_demotions_delta"),
]


def parse_summary_log(path):
    """Extract fields from a Stage 12 summary.log."""
    fields = {
        "case": os.path.basename(os.path.dirname(path)),
        "models": "NA",
        "sessions": "NA",
        "noisy_model": "NA",
        "noisy_session": "NA",
        "noisy_multiplier": "NA",
        "decode_p99_us": "NA",
        "decode_p95_us": "NA",
        "decode_avg_us": "NA",
        "write_MBps": "NA",
        "prefetch_read_MBps": "NA",
        "kairo_fairness_refills_delta": "NA",
        "kairo_fairness_model_throttles_delta": "NA",
        "kairo_fairness_session_throttles_delta": "NA",
        "kairo_noisy_session_events_delta": "NA",
        "kairo_protected_decode_dispatches_delta": "NA",
        "kairo_prefetch_fairness_throttles_delta": "NA",
        "kairo_write_fairness_demotions_delta": "NA",
    }

    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return fields

    # Extract key=value lines
    for line in text.splitlines():
        line = line.strip()
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        if key in fields:
            fields[key] = val

    # If summary.csv sidecar exists with counter deltas, prefer those
    summary_csv = os.path.join(os.path.dirname(path), "summary.csv")
    if os.path.isfile(summary_csv):
        try:
            with open(summary_csv) as f:
                reader = csv.DictReader(f)
                for row in reader:
                    for native_name, field_name in FIELD_NAMES:
                        val = row.get(field_name, "NA")
                        if val != "NA" and val != "":
                            fields[field_name] = val
        except (csv.Error, OSError):
            pass

    return fields


def case_sort_key(case_name):
    m = re.match(r"(\d+)", case_name)
    if m:
        return (0, int(m.group(1)), case_name)
    return (1, 0, case_name)


def emit_csv(rows, outfile):
    writer = csv.DictWriter(outfile, fieldnames=[n for n, _ in FIELD_NAMES])
    writer.writeheader()
    writer.writerows(rows)


def emit_pretty(rows):
    col_widths = {}
    for row in rows:
        for _, native_name in FIELD_NAMES:
            val = str(row.get(native_name, ""))
            col_widths[native_name] = max(
                col_widths.get(native_name, len(native_name)), len(val)
            )
    sep = "+" + "+".join("-" * (w + 2) for w in col_widths.values()) + "+"
    header = (
        "| "
        + " | ".join(
            native_name.ljust(col_widths[native_name])
            for _, native_name in FIELD_NAMES
        )
        + " |"
    )
    print(sep)
    print(header)
    print(sep.replace("-", "="))
    for row in rows:
        line = (
            "| "
            + " | ".join(
                str(row.get(native_name, "")).ljust(col_widths[native_name])
                for _, native_name in FIELD_NAMES
            )
            + " |"
        )
        print(line)
        print(sep)


def main():
    parser = argparse.ArgumentParser(
        description="Parse Stage 12 fairness summary logs"
    )
    parser.add_argument("summary_logs", nargs="+", help="Path(s) to summary.log")
    parser.add_argument("--csv", action="store_true", help="Output CSV (default)")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print table")
    args = parser.parse_args()

    paths = []
    for p in args.summary_logs:
        expanded = glob.glob(p)
        if expanded:
            paths.extend(expanded)
        else:
            paths.append(p)

    rows = []
    for path in paths:
        fields = parse_summary_log(path)
        row = {}
        for _, native_name in FIELD_NAMES:
            row[native_name] = fields.get(native_name, "NA")
        rows.append(row)

    if not rows:
        print("No summary logs found.", file=sys.stderr)
        sys.exit(1)

    rows.sort(key=lambda r: case_sort_key(r.get("case", "")))

    use_csv = not args.pretty

    if use_csv:
        emit_csv(rows, sys.stdout)
    else:
        emit_pretty(rows)


if __name__ == "__main__":
    main()
