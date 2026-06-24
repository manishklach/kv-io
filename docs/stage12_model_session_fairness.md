# Stage 12: Per-Model / Per-Session Fairness

Stage 12 adds a conceptual per-model and per-session fairness scheduler
concept to Kairo. It is an RFC/POC scaffold, not a production quality
fairness implementation.

## Why AI Serving Needs Per-Model/Session Fairness

AI inference serving is inherently multi-tenant. Multiple models (e.g.,
Llama 3, Mistral, GPT-4-class) and multiple user sessions share the same
storage device through the same mq-deadline scheduler.

Without per-model/session fairness, one noisy session can:
- Exhaust its decode budget but continue issuing decode requests
- Crowd out another session's decode-critical reads
- Destroy another session's decode p99 tail latency
- Cause QoS violations for well-behaved tenants

Global decode priority (Stage 1) is not enough. It prioritizes decode reads
over background traffic, but does not distinguish between decode reads from
different tenants. A single session issuing 10x the normal decode rate can
still monopolize dispatch service.

## Why Global Decode Priority Is Not Enough

Stage 1 decode priority gives decode reads priority over prefetch reads and
writes for the entire device. This is correct for single-tenant workloads or
controlled multi-tenant deployments where each tenant's decode volume is
bounded.

In unregulated multi-tenant AI serving:

```
Session A: 1000 decode IOPS, well-behaved
Session B: 10000 decode IOPS, noisy
```

Session B's decode volume causes it to occupy most dispatch slots, pushing
Session A's decode latency higher even though both are in the decode class.
Fairness scheduling adds per-entity credit accounting so that Session A
retains its proportional share of decode service.

## Fairness Credit Model

The fairness scheduler uses a simple credit-based model:

1. Each fairness entity (model or session) has a credit pool.
2. Decode dispatch consumes one credit from the session entity.
3. Credits are refilled periodically up to the configured pool limit.
4. An entity with zero remaining credits:
   - Has its prefetch requests throttled first
   - Then has its non-critical writes demoted
   - Decode requests are blocked until credits are refilled
5. Starvation-escape writes are never blocked.

Credit values are configurable via sysfs:
- `kairo_model_decode_credit`: per-model credit pool size
- `kairo_session_decode_credit`: per-session credit pool size
- `kairo_fairness_refill_ms`: refill interval in milliseconds

## Noisy Session Detection

A session is flagged as "noisy" when its decode dispatch count exceeds the
configured `kairo_noisy_session_threshold`. Once flagged:

- Its prefetch is throttled even if credits remain
- Write demotion pressure is increased
- The `kairo_noisy_session_events` counter is incremented
- A detection log is emitted (conceptual; real dmesg integration deferred)

Noisy session detection prevents a single abusive session from degrading
service for other tenants even before its credits run out.

## How Prefetch Is Throttled Before Decode

The throttling hierarchy under fairness pressure:

1. Prefetch is throttled first (`kairo_fairness_throttle_prefetch`)
2. Non-critical writes are demoted (`kairo_fairness_demote_write`)
3. Decode is only blocked when credits are exhausted

This ordering preserves the Kairo principle that decode is the most critical
I/O class. Prefetch is the best candidate for throttling because it is
performance-enhancing but not correctness-critical.

## How Write Anti-Starvation Is Preserved

The fairness write demotion hook (`kairo_fairness_demote_write`) always
checks for starvation-escape writes and never demotes them. This preserves
the Stage 11 guarantee that writes cannot be deferred indefinitely.

Additionally, the fairness policy applies demotion pressure at the entity
level. If one session's writes are being demoted due to fairness, other
sessions' writes are unaffected. This isolates the impact of misbehaving
sessions.

## Fairness Entity Lookup

Current implementation uses linear scan of a fixed-size array for entity
lookup. This is acceptable for the initial scaffold with up to 256 sessions
and 64 models. Production deployment would replace this with a hash table
or radix tree.

## Sysfs Interface

Tunables:
```
kairo_fairness_enable              (0/1)
kairo_model_decode_credit          (per-model credit pool)
kairo_session_decode_credit        (per-session credit pool)
kairo_fairness_refill_ms           (refill interval in ms)
kairo_noisy_session_threshold      (decode dispatch threshold)
```

Counters:
```
kairo_fairness_refills                (total refill events)
kairo_fairness_model_throttles        (model entity throttles)
kairo_fairness_session_throttles      (session entity throttles)
kairo_noisy_session_events            (noisy session detections)
kairo_protected_decode_dispatches     (decode dispatches preserved)
kairo_prefetch_fairness_throttles     (prefetch throttles under fairness)
kairo_write_fairness_demotions        (write demotions under fairness)
```

## Conceptual Hook Points

The fairness logic integrates at these points in the scheduler:

| Hook | Location | Purpose |
|------|----------|---------|
| `kairo_fairness_allow_decode` | `dd_kairo_dispatch_decode_request` | Gate decode dispatch on credits |
| `kairo_fairness_throttle_prefetch` | `dd_kairo_dispatch_prefetch_request` | Throttle prefetch under pressure |
| `kairo_fairness_demote_write` | `dd_kairo_should_demote_prefill/evict` | Increase demotion pressure |
| `kairo_fairness_account_dispatch` | Post-dispatch in decode/prefetch paths | Update entity counters |
| `kairo_fairness_refill_if_needed` | Dispatch loop or timer | Periodic credit refill |

## What Is Conceptual vs Implemented

| Component | Status |
|-----------|--------|
| Fairness data structures | RFC/POC scaffold |
| Entity lookup (linear scan) | Conceptual |
| Credit refill mechanism | Conceptual (static state, not per-device) |
| Sysfs tunables and counters | Defined but not wired in sysfs boilerplate |
| Noisy session detection | Conceptual |
| Tracepoints | Conceptual (commented out) |
| Fairness dispatch gating | Conceptual (returns true, no enforcement) |
| Prefetch throttling | Conceptual (returns false, no enforcement) |
| Write demotion | Conceptual (returns false, no enforcement) |
| Entity accounting | Conceptual (hooks defined but not called) |
| Per-device state embedding | Conceptual (NULL fs pointer) |

## Benchmark Noisy-Session Experiment

The experiment script `scripts/run_stage12_fairness_experiment.sh` runs five
canonical cases:

1. **01-balanced-multisession**: Multiple sessions with balanced decode load.
2. **02-noisy-session-no-fairness**: One session generates extra decode
   traffic; fairness disabled.
3. **03-noisy-session-fairness-observe**: Fairness enabled in observe-only
   mode (counters active, no throttling).
4. **04-noisy-session-fairness-enabled**: Fairness enabled with active
   throttling of the noisy session.
5. **05-noisy-model-fairness-enabled**: One model generates extra decode
   traffic; per-model fairness enabled.

Each case measures decode tail latency (p99, p95, avg), throughput, and
fairness counter deltas.

The benchmark supports `--noisy-session N`, `--noisy-model N`, and
`--noisy-multiplier N` flags to create the noisy traffic pattern.

## What Remains Unvalidated

- Real multi-tenant inference workload on patched kernel
- Effectiveness of fairness on real NVMe hardware
- Optimal credit pool sizes for different inference patterns
- Interaction with Stage 10 adaptive latency controller
- Interaction with BPF dispatch hook (patch 0016)
- Timer-based credit refill (currently called from dispatch path)
- Hash-table entity lookup for production scale
- Tracepoint integration with Stage 8 observability
