#!/usr/bin/env python3
"""Summarize kvio-bench logs into a compact comparison table."""

from __future__ import annotations

import re
import sys
from pathlib import Path

FIELDS = [
    "total_decode_reads",
    "total_prefetch_reads",
    "total_writes",
    "p95_decode_latency_us",
    "p99_decode_latency_us",
    "read_throughput_mib_s",
    "write_throughput_mib_s",
]


def parse_file(path: Path) -> dict[str, str]:
    result: dict[str, str] = {"file": str(path)}
    pattern = re.compile(r"^\s*([a-z0-9_]+):\s+(.+?)\s*$")
    for line in path.read_text().splitlines():
        match = pattern.match(line)
        if match:
            result[match.group(1)] = match.group(2)
    return result


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} <benchmark-log> [benchmark-log...]", file=sys.stderr)
        return 1

    rows = [parse_file(Path(arg)) for arg in argv[1:]]
    print("file\t" + "\t".join(FIELDS))
    for row in rows:
        print(row["file"] + "\t" + "\t".join(row.get(field, "n/a") for field in FIELDS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
