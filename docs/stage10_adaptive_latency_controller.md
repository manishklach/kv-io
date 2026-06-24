# Stage 10: Adaptive Decode Tail-Latency Controller

Stage 10 is an RFC/POC adaptive scheduling controller.

It does **not** claim production stability.

It does **not** claim kernel boot validation unless tested.

It does **not** claim physical NVMe placement.

## Why Static I/O Priority Is Insufficient for AI Inference

Kairo's static scheduling knobs (`kairo_decode_budget`, `kairo_prefetch_budget`,
write anti-starvation deadline, tag reservation) work well for steady-state
workloads where the ratio of decode reads to prefetch reads to write traffic
is predictable.

AI inference workloads are not steady-state:

- **Decode spikes**: When a new inference request starts, decode reads surge.
  Static budgets may be too low, causing decode p99 to spike above acceptable
  thresholds.
- **Quiet periods**: Between decode bursts, aggressive decode budgets waste
  dispatch slots that prefetch or writes could use.
- **Prefetch interference**: Prefetch helps when decode latency is healthy,
  but hurts when decode p99 is elevated. An adaptive controller should throttle
  prefetch under decode pressure.
- **Write safety**: The anti-starvation deadline prevents indefinite write
  deferral, but the deadline should be preserved (not relaxed) under decode
  stress. However, write progress should be allowed when decode pressure eases.

A static configuration cannot optimize for all three regimes simultaneously.

## Why Decode p99 Is the Control Objective

Decode reads are the latency-critical I/O class in KV-cache inference:

- Every decode read is on the critical path of an inference token generation.
- The tail latency (p99) determines worst-case token generation time.
- Average latency (p50) determines throughput, but p99 determines user-perceived
  quality of service.
- Prefetch reads are speculative — they can tolerate delay.
- Writes (prefill/evict) are throughput-oriented — they can tolerate delay.

Therefore, the controller uses **observed decode p99 latency** as the primary
control signal.

## How the Controller Observes Decode Latency

The controller accumulates decode request completion latencies over a
configurable **control window** (default: 1 second):

```
For each completed decode request:
    samples++
    sum_us += completion_latency_us
    max_us = max(max_us, completion_latency_us)

At end of window:
    avg_us = sum_us / samples
    p95    = avg + (max - avg) / 2
    p99    = avg + 3 * (max - avg) / 4
```

The p95 and p99 computation is intentionally **coarse** — the controller
estimates percentiles from avg/max without a full histogram. A production
implementation would use exponential latency buckets for precise pXX tracking.

## How the Controller Adapts Decode Budget

When `observed_decode_p99_us > target_decode_p99_us`:

```
new_decode_budget = min(adaptive_decode_budget + BOOST_STEP, MAX_DECODE_BUDGET)
```

- Budget increases by `BOOST_STEP` (2) per window, capped at `MAX_DECODE_BUDGET` (32).
- The base budget (user-configured via `kairo_decode_budget` sysfs) is preserved
  as the relaxation target.

When `observed_decode_p99_us <= target_decode_p99_us`:

```
new_decode_budget = max(adaptive_decode_budget - RELAX_STEP, base_decode_budget)
```

- Budget decreases by `RELAX_STEP` (1) per window toward the base.
- The controller never goes below the user-configured base — it only adds headroom
  during decode pressure.

## How the Controller Throttles Prefetch

When decode p99 exceeds target:

```
new_prefetch_budget = max(adaptive_prefetch_budget - BOOST_STEP, MIN_PREFETCH_BUDGET)
```

- Prefetch budget is reduced to conserve I/O resources for decode.
- Minimum prefetch budget is 1 (never zero — prevents complete prefetch starvation).

When decode p99 is healthy:

```
new_prefetch_budget = min(adaptive_prefetch_budget + RELAX_STEP, base_prefetch_budget)
```

- Prefetch budget is gradually restored toward the base.
- Never exceeds the base (user-configured) value.

## How the Controller Preserves Write Anti-Starvation

The controller does not modify the write anti-starvation deadline from patch
0011. That deadline exists independently as a safety mechanism. However, the
controller influences **write demotion pressure**:

- Under decode stress: prefill and evict demotion thresholds shift to yield
  more aggressively to decode reads. The conceptual `KAIRO_CTRL_WRITE_DEMOTE_BOOST`
  signal increases the demotion pressure counter.
- Under relaxed decode: demotion pressure counter decreases.

The anti-starvation deadline in 0011 remains the hard bound on write deferral.
The controller only adjusts the **soft** demotion preference.

## How the Controller Interacts with Tag Reservation

The controller does not modify tag reservation (patch 0012). Tag reservation
gives decode reads a guaranteed minimum tag pool. The controller's decode budget
adjustments operate at the scheduler dispatch level, which is orthogonal to
tag availability at the blk-mq layer.

In a future iteration, the controller could also adjust the tag reservation
ratio dynamically, but that is beyond this RFC/POC.

## Controller Modes

| Mode | Behavior |
|------|----------|
| `OFF` (0) | Controller inactive. Static budgets only. |
| `OBSERVE` (1) | Controller collects decode latency samples and computes p95/p99 but does not adjust budgets. Useful for baseline data collection. |
| `ADAPTIVE` (2) | Controller adjusts budgets based on observed latency. |

## Sysfs Knobs

All knobs under `/sys/block/<dev>/mq-deadline/`:

| Knob | Type | Default | Description |
|------|------|---------|-------------|
| `kairo_controller_enable` | RW | 0 | Enable (OBSERVE) or disable (OFF) the controller |
| `kairo_controller_mode` | RW | 0 | 0=OFF, 1=OBSERVE, 2=ADAPTIVE |
| `kairo_target_decode_p99_us` | RW | 5000 | Target decode p99 latency in microseconds |
| `kairo_control_window_ms` | RW | 1000 | Control window in milliseconds (10–60000) |
| `kairo_adaptive_decode_budget` | RO | — | Current controller-decided decode budget |
| `kairo_adaptive_prefetch_budget` | RO | — | Current controller-decided prefetch budget |
| `kairo_observed_decode_p99_us` | RO | — | Observed decode p99 in last window |
| `kairo_observed_decode_p95_us` | RO | — | Observed decode p95 in last window |
| `kairo_observed_decode_avg_us` | RO | — | Observed decode average in last window |

## Sysfs Counters

All counters under `/sys/block/<dev>/mq-deadline/`:

| Counter | Description |
|---------|-------------|
| `kairo_controller_updates` | Number of controller update cycles |
| `kairo_controller_boost_events` | Count of decode budget boosts |
| `kairo_controller_relax_events` | Count of decode budget relaxations |
| `kairo_controller_prefetch_throttles` | Count of prefetch budget reductions |
| `kairo_controller_write_releases` | Cumulative write demotion pressure signal |
| `kairo_controller_insufficient_samples` | Count of windows skipped due to insufficient samples |

## What Is Implementated vs. Conceptual

### Implemented in 0018

- `enum kairo_controller_mode` and `struct kairo_latency_controller` definition
- Controller initialization, update, and apply logic
- Decode latency sample accumulation
- Coarse p95/p99 computation from avg/max
- Budget adjustment policy (boost, relax, throttle)
- Write demotion pressure signal
- Sysfs knobs and counters for all controller state
- Integration call site in `dd_dispatch_request()`
- Demotion helpers reference controller decode pressure signal

### Conceptual / CONCEPTUAL-HOOK

- **Decode latency measurement**: The `dd_kairo_controller_note_decode_latency()`
  function is defined but has no call site wired. A real implementation needs a
  hook in the blk-mq completion path or a mq-deadline request completion handler.
- **p95/p99 histogram**: The current avg/max heuristic is coarse. A real
  implementation should use exponential latency buckets.
- **Tracepoint**: The `kairo_controller_update` tracepoint is documented but
  not wired into the existing Kairo tracepoint set (patch 0017). Add it once
  the controller is validated.
- **Per-device controller state**: The controller state lives in `deadline_data`,
  which is per-device. Currently, budget adjustments update global `kairo_decode_budget`
  and `kairo_prefetch_budget` variables. A per-device budget would be more correct.
- **Timer-based update**: The controller update is called from `dd_dispatch_request()`.
  A real implementation should use a per-device timer for deterministic update
  intervals, especially when dispatch rate is low.

## How to Run the Experiment

```bash
# Stage 10 experiment harness
./scripts/run_stage10_latency_controller_experiment.sh <file-path> <block-device> [options]

# Dry-run validation (no kernel counters, no real runs)
./scripts/run_stage10_latency_controller_experiment.sh /tmp/kairo.bin loop0 --skip-counters --dry-run --duration 3

# Run all 6 canonical cases
./scripts/run_stage10_latency_controller_experiment.sh /tmp/kairo.bin /dev/nvme0n1

# Parse results
python3 scripts/parse_stage10_latency_controller_summary.py results/stage10/<timestamp>/*/summary.log --pretty
```

## Canonical Cases

| Case | Description |
|------|-------------|
| `01-baseline-static` | Static scheduling, no controller, read-only workload |
| `02-decode-pressure-static` | Static scheduling under decode pressure (many decode reads) |
| `03-decode-pressure-controller-observe` | Controller in OBSERVE mode under decode pressure |
| `04-decode-pressure-controller-adaptive` | Controller in ADAPTIVE mode under decode pressure |
| `05-prefetch-heavy-controller-adaptive` | Prefetch-heavy workload with ADAPTIVE controller |
| `06-write-heavy-controller-adaptive` | Write-heavy workload with ADAPTIVE controller |

## What Remains Unvalidated

- Real decode latency measurement from inside the kernel (requires completion hook)
- Controller behavior on real NVMe hardware under true inference patterns
- Interaction between controller and tag reservation at high IOPS
- Optimal control window size for different workload arrival patterns
- Whether the coarse p95/p99 heuristic converges to reasonable values
- Whether write demotion pressure signal actually improves write latency
- Interaction with BPF dispatch hook (patch 0016) — should the controller
  influence BPF policy or vice versa?
- Boot-time validation of the compiled controller code path
