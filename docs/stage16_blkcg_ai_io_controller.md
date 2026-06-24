# Stage 16: blk-cgroup AI I/O Controller Scaffold

## Why Cgroup Integration Matters for AI Inference Serving

Real AI inference does not run in a vacuum. It runs in:

- **Kubernetes pods** with cgroup CPU/memory limits
- **Multi-tenant GPU serving** platforms (vLLM, TensorRT-LLM, SGLang)
- **Batch inference jobs** sharing a storage device with production traffic
- **Background cache compaction** and **eviction workers** that must not
  interfere with interactive decode latency

Today the Linux block cgroup subsystem (`blk-cgroup`, `blk-iocost`,
`blk-throttle`) provides proportional I/O weights and bandwidth limits,
but it has no understanding of AI inference I/O classes. A production
decode request and a background eviction request from the same cgroup
are indistinguishable to the block layer.

Kairo fixes this at the request level. Stage 16 connects that
request-level classification to the cgroup layer, enabling:

```
decode requests from the production pod  -> weight 100, no throttling
prefetch requests from the production pod -> weight 50,  throttle under pressure
eviction requests from the batch pod      -> weight 10,  always yield
```

## Relationship to Containers, Services, and Tenants

| Concept | Kairo Mapping |
|---------|---------------|
| Container/Pod | `blkcg` (block cgroup) |
| Service (e.g. production decode) | `kairo_blkg_policy_class` (policy class) |
| Tenant | `blkcg` hierarchy + `kairo_blkg_policy` per cgroup |
| Job | Ephemeral cgroup with `KAIRO_BLKG_BATCH_PREFILL` class |
| Background worker | `KAIRO_BLKG_BACKGROUND` class with low weights |

A single container/pod gets one `kairo_blkg_policy` instance. Within
that policy, Kairo's per-request classification (decode vs prefetch
vs write vs eviction) uses the per-class weights to schedule relative
priority.

## Policy Class Model

```
KAIRO_BLKG_DEFAULT (0)
  └── No special policy; Kairo treats this cgroup as best-effort

KAIRO_BLKG_PRODUCTION_DECODE (1)
  └── Interactive decode serving.  High decode weight.
      Prefetch throttled under latency pressure.
      Writes demoted.  Evictions deprioritized.

KAIRO_BLKG_BATCH_PREFILL (2)
  └── Batch prefill / prompt processing.  High write weight.
      Decode weight is secondary.
      Evictions allowed for recomputable data.

KAIRO_BLKG_PREFETCH (3)
  └── Speculative prefetch service.  High prefetch weight.
      Decode weight is low.
      Writes demoted on decode pressure.

KAIRO_BLKG_EVICTION (4)
  └── Dedicated eviction worker.  Only eviction weight counts.
      All other classes deprioritized.

KAIRO_BLKG_BACKGROUND (5)
  └── Non-urgent maintenance.  All weights low.
      Yields to every other class.
```

## How Kairo Request Classes Map to Cgroup Policy

| Kairo io_class | Cgroup weight field | Typical use |
|----------------|---------------------|-------------|
| `KAIRO_IO_DECODE_READ` | `kairo.decode_weight` | Interactive KV-cache decode |
| `KAIRO_IO_PREFETCH_READ` | `kairo.prefetch_weight` | Speculative prefetch |
| `KAIRO_IO_PREFILL_WRITE` | `kairo.write_weight` | KV-cache prefill / batch |
| `KAIRO_IO_EVICT_DISCARD` | `kairo.eviction_weight` | Cache eviction |
| `KAIRO_IO_EVICT_WRITE` | `kairo.eviction_weight` | Eviction with writeback |

The cgroup policy's weight determines how aggressively requests of
that class are dispatched relative to other classes within the same
cgroup, and (in a future multi-cgroup implementation) across cgroups.

## Why This Is a Scaffold, Not a Production Controller

Stage 16 is intentionally limited:

1. **No real cgroup filesystem registration.** The `blkcg_policy`
   struct is `#if 0` — the cgroupfs knobs are documented but not
   mounted.

2. **No dispatch path integration.** All five conceptual hooks
   (`kairo_blkg_allow_decode`, `kairo_blkg_throttle_prefetch`,
   `kairo_blkg_demote_write`, `kairo_blkg_account_dispatch`,
   `kairo_blkg_policy_from_request`) are defined but never called.

3. **No `CONFIG_BLK_CGROUP_KAIRO` Kconfig symbol.** The
   `blk-kairo-blkcg.c` file's Makefile entry is guarded by
   `CONFIG_BLK_CGROUP_KAIRO` which does not exist in upstream Linux.

4. **No per-blkg_stats allocation.** The stats struct exists but
   no `pd_alloc_fn` allocates it.

5. **No multi-cgroup fair scheduling.** The conceptual hooks always
   return conservative defaults (allow decode, don't throttle prefetch,
   don't demote writes).

## Candidate Linux 6.8 blk-cgroup Hook Points

| Hook point | File | Purpose |
|------------|------|---------|
| `blkg_lookup()` | `block/blk-cgroup.c` | Find blkcg_gq from bio's cgroup |
| `bio_blkcg()` | `include/linux/blk-cgroup.h` | Get cgroup from bio |
| `blkg_to_pd()` | `include/linux/blk-cgroup.h` | Get per-policy data from blkg |
| `blkcg_policy_register()` | `block/blk-cgroup.c` | Register a new blkcg policy |
| `.pd_alloc_fn` / `.pd_free_fn` | `blkcg_policy` struct | Alloc/free per-blkg policy data |
| `.cftypes` | `blkcg_policy` struct | cgroup files for the policy |

LINUX-6.8-CHECK: These symbols exist in Linux 6.8 but their signatures
may differ in earlier or later kernels. The blk-iocost and blk-throttle
implementations in 6.8 are the reference patterns.

## How This Differs from Per-Model/Session Fairness (Stage 12)

| Dimension | Stage 12 (Model/Session Fairness) | Stage 16 (blk-cgroup) |
|-----------|-----------------------------------|----------------------|
| Scope | Per-model, per-session within a device | Per-cgroup across containers |
| Unit of fairness | AI model ID, session ID | Linux cgroup (blkcg) |
| Mechanism | Decode credit pools, per-entity accounting | cgroup weights, class-based budgets |
| Multi-tenant | Same kernel, same device | Different cgroups, potential QoS isolation |
| Dispatch hook | `kairo_fairness_allow_decode()` | `kairo_blkg_allow_decode()` |
| Relationship | Complements cgroup policy | Could use cgroup policy as input |

In a production deployment, both would coexist:
- Stage 12 fairness ensures one noisy session within a pod doesn't
  starve other sessions in the same pod.
- Stage 16 blk-cgroup policy ensures one pod's eviction traffic
  doesn't degrade another pod's decode latency.

## WSL Validation Limitations

WSL can validate:
- Experiment script dry-run (all 5 cases)
- Parser output format
- Benchmark tenant field output
- Blkcg audit script syntax check (does not require Linux source tree)

WSL cannot validate:
- Real `blkcg_policy_register()` call
- cgroup filesystem interface visibility
- Per-cgroup stats collection
- Cross-cgroup dispatch ordering
- `blkg_lookup()` in a real kernel

Stage 16 does **not** claim real cgroup controller implementation
unless tested on a patched kernel with `CONFIG_BLK_CGROUP` enabled.

## Files

| File | Purpose |
|------|---------|
| `kernel/patches/0026-rfc-kairo-blkcg-ai-io-controller.patch` | Kernel scaffold |
| `docs/stage16_blkcg_ai_io_controller.md` | This document |
| `scripts/run_stage16_blkcg_experiment.sh` | Experiment script |
| `scripts/parse_stage16_blkcg_summary.py` | Summary parser |
| `kernel/integration/linux-6.8/audit_blkcg_hooks.sh` | blk-cgroup hook audit |
| `scripts/collect_kairo_counters.sh` | Updated with blkcg counters |
| `scripts/validate_patch_stack.sh` | Updated with Stage 16 checks |
