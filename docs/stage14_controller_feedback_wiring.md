# Stage 14: Controller Feedback Wiring

## Why Adaptive Control Needs Actual Feedback

Stage 10 introduced the adaptive decode latency controller with a
conceptual feedback loop:

- `dd_kairo_controller_note_decode_latency()` was defined
- `observed_decode_p99_us` and `observed_decode_p95_us` were tracked
- Budget adjustment logic was implemented

But the loop was not wired. Stage 10 said:

> decode latency sampling is conceptual and not wired

Stage 14 completes the bridge:

```
request classified as decode
  -> classify_time_ns recorded
  -> decode dispatch
  -> dispatch_time_ns recorded
  -> decode_queue_latency_us computed
  -> controller histogram updated
  -> adaptive budget update uses histogram p95/p99
  -> histogram reset for next window
```

## Timestamp Lifecycle

| Event | Timestamp | Set By |
|-------|-----------|--------|
| Request classification | `classify_time_ns` | `kairo_mark_classify_time()` |
| Dispatch to driver | `dispatch_time_ns` | `kairo_mark_dispatch_time()` |
| Queue latency computed | `decode_queue_latency_us` | `kairo_decode_queue_latency_us()` |

### classify_time_ns

Set when a request's Kairo I/O class is determined. For decode reads
this is during request initialization (`kairo_init_request_hints()` in
blk-mq). This marks the moment the request enters the Kairo scheduling
domain.

### dispatch_time_ns

Set when the scheduler hands the request to the block driver. For
decode reads this happens in `dd_kairo_dispatch_decode_request()`.
This marks the end of scheduling queue delay.

### decode_queue_latency_us

Computed as `(dispatch_time_ns - classify_time_ns) / 1000`.

This is the queue delay — how long the decode request waited in the
scheduler before being dispatched. It does not include device service
time.

## Controller Integration

The feedback loop is wired in `dd_kairo_dispatch_decode_request()`:

1. `kairo_mark_dispatch_time(rq, ktime_get_ns())` records dispatch time
2. `kairo_decode_queue_latency_us(rq, ktime_get_ns())` computes queue delay
3. `dd_kairo_controller_note_decode_latency(dd, latency_us)` feeds into
   the Stage 13 histogram
4. `dd_kairo_controller_update()` uses histogram for p95/p99 estimation
5. Histogram is reset when control window expires

## Missing Timestamp Handling

If `classify_time_ns` is zero (not set), `kairo_decode_queue_latency_us()`
returns 0. The controller detects this and:

- Increments `kairo_controller_missing_timestamp` counter
- Skips the sample (does not add to histogram)

This prevents corrupted latency data from requests that bypassed
normal classification.

## Histogram Integration

The Stage 13 histogram (`struct kairo_latency_histogram`) is embedded
in `struct kairo_latency_controller` as `decode_hist`.

Controller update sequence:

1. `dd_kairo_controller_update_from_hist(ctrl)` — computes observed
   avg, p95, p99 from histogram buckets
2. If `hist->samples < KAIRO_CTRL_MIN_SAMPLES` — insufficient samples,
   reset histogram, increment `controller_insufficient_samples`
3. If `ctrl->mode == KAIRO_CTRL_ADAPTIVE` — apply budget adjustment
4. `kairo_latency_histogram_reset(hist)` — reset for next window

## New Counters

| Counter | Purpose |
|---------|---------|
| `kairo_controller_latency_samples` | Total decode latency samples fed to controller |
| `kairo_controller_missing_timestamp` | Samples skipped due to zero classify_time |
| `kairo_controller_latency_updates` | Number of controller update cycles |
| `kairo_controller_histogram_resets` | Number of histogram resets |
| `kairo_controller_decode_latency_gt_target` | Samples exceeding target_decode_p99_us |

## Tracepoint

A `kairo_controller_sample` tracepoint is documented in patch 0024
comments but not wired. Fields:

- `sector` — request sector
- `nr_bytes` — request size
- `latency_us` — decode queue latency
- `target_decode_p99_us` — controller target
- `samples` — histogram sample count

This tracepoint should be added to the Stage 8 tracepoint set (0017)
after controller feedback validation on a patched kernel.

## Compile-Targeted vs Conceptual

| Component | Status | Annotation |
|-----------|--------|------------|
| `kairo_mark_classify_time()` | compile-targeted | Inline helper in blk-mq.h |
| `kairo_mark_dispatch_time()` | compile-targeted | Inline helper in blk-mq.h |
| `kairo_decode_queue_latency_us()` | compile-targeted | Inline helper in blk-mq.h |
| Timestamp fields in `kairo_request_hints` | compile-targeted | Increases struct size |
| Call site in `dd_kairo_dispatch_decode_request()` | conceptual | LINUX-6.8-CHECK |
| Controller histogram integration | conceptual | CONCEPTUAL-HOOK |
| `kairo_controller_sample` tracepoint | documented only | Not wired |

## WSL Limitations

WSL can validate:
- Experiment script dry-run (all 5 cases)
- Parser output format
- Benchmark user-space histogram output
- Script counter collection format

WSL cannot validate:
- Patched-kernel controller feedback counters
- Timestamp recording in request lifecycle
- Histogram movement from kernel dispatch path
- Tracepoint emission

Stage 14 does **not** claim kernel feedback loop movement unless a
patched kernel is running.

## Files

| File | Purpose |
|------|---------|
| `kernel/patches/0024-rfc-kairo-controller-feedback-wiring.patch` | Kernel scaffold |
| `docs/stage14_controller_feedback_wiring.md` | This document |
| `scripts/run_stage14_controller_feedback_experiment.sh` | Experiment script |
| `scripts/parse_stage14_controller_feedback_summary.py` | Summary parser |
| `scripts/collect_kairo_counters.sh` | Updated with feedback counters |
| `scripts/validate_patch_stack.sh` | Updated with Stage 14 checks |
