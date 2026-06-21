# Aggressive POC Plan

This project intentionally starts with kernel patches, not only documentation. The objective is to validate behavior quickly with a benchmark-driven prototype.

## Milestone 1

Build a benchmark that creates decode-read versus prefill-write interference.

## Milestone 2

Patch `mq-deadline` for decode-critical read priority.

## Milestone 3

Add request classification and stats.

## Milestone 4

Add prefetch-aware scheduling.

## Milestone 5

Add large-block coalescing experiments.

## Milestone 6

Add placement and lifetime hint abstraction.

## Milestone 7

Test optional ZNS, NVMe Streams, and FDP mapping where hardware supports it.

## First Validation Target

Reduce p99 decode-read latency under mixed prefill/decode pressure.
