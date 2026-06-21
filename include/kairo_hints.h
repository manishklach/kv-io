#ifndef KAIRO_HINTS_H
#define KAIRO_HINTS_H

/*
 * Kairo experimental user-space hint definitions.
 *
 * These constants are for the internal RFC/POC benchmark path only. They are
 * not a Linux UAPI proposal. The first prototype maps these logical classes to
 * existing Linux ioprio values so a local mq-deadline patch can classify block
 * requests without inventing a permanent interface.
 */

#define KAIRO_CLASS_DECODE_READ    0
#define KAIRO_CLASS_PREFETCH_READ  1
#define KAIRO_CLASS_PREFILL_WRITE  2
#define KAIRO_CLASS_EVICT          3
#define KAIRO_CLASS_NORMAL         4

/* Temporary ioprio mapping for the local POC:
 *
 *   IOPRIO_CLASS_RT, prio 0, READ  -> KAIRO_DECODE_READ
 *   IOPRIO_CLASS_RT, prio 1, READ  -> KAIRO_PREFETCH_READ
 *   IOPRIO_CLASS_BE, prio 7, WRITE -> KAIRO_PREFILL_WRITE
 *   discard/write-zeroes           -> KAIRO_EVICT
 */

#endif /* KAIRO_HINTS_H */
