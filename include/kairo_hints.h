#ifndef KAIRO_HINTS_H
#define KAIRO_HINTS_H

/*
 * Experimental Kairo user-space hint definitions.
 *
 * This is a local RFC/POC metadata path. It is not a proposed stable UAPI.
 *
 * Current local ioprio mapping:
 *   KAIRO_CLASS_DECODE_READ   -> IOPRIO_CLASS_RT, prio 0
 *   KAIRO_CLASS_PREFETCH_READ -> IOPRIO_CLASS_RT, prio 1
 *   KAIRO_CLASS_PREFILL_WRITE -> IOPRIO_CLASS_BE, prio 7
 *   KAIRO_CLASS_EVICT         -> discard / punch-hole path or BE prio 6 fallback
 */

#define KAIRO_CLASS_DECODE_READ   0
#define KAIRO_CLASS_PREFETCH_READ 1
#define KAIRO_CLASS_PREFILL_WRITE 2
#define KAIRO_CLASS_EVICT         3

#define KAIRO_RWF_DECODE      (1ULL << 28)
#define KAIRO_RWF_PREFETCH    (1ULL << 29)
#define KAIRO_RWF_PREFILL     (1ULL << 30)
#define KAIRO_RWF_RECOMPUTE   (1ULL << 31)

enum kairo_hint_mode {
    KAIRO_HINT_MODE_IOPRIO = 0,
    KAIRO_HINT_MODE_RWF = 1,
    KAIRO_HINT_MODE_BOTH = 2,
};

static inline const char *kairo_hint_mode_name(enum kairo_hint_mode mode)
{
    switch (mode) {
    case KAIRO_HINT_MODE_IOPRIO:
        return "ioprio";
    case KAIRO_HINT_MODE_RWF:
        return "rwf";
    case KAIRO_HINT_MODE_BOTH:
        return "both";
    default:
        return "ioprio";
    }
}

#endif
