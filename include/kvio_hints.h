#ifndef KVIO_HINTS_H
#define KVIO_HINTS_H

/*
 * Local user-space classification hints for the KV-IO benchmark path.
 *
 * Current ioprio mapping used by the RFC/POC:
 *   KVIO_CLASS_DECODE_READ   -> IOPRIO_CLASS_RT, prio 0
 *   KVIO_CLASS_PREFETCH_READ -> IOPRIO_CLASS_RT, prio 1
 *   KVIO_CLASS_PREFILL_WRITE -> IOPRIO_CLASS_BE, prio 7
 *   KVIO_CLASS_EVICT         -> discard / cleanup path
 */

#define KVIO_CLASS_DECODE_READ   0
#define KVIO_CLASS_PREFETCH_READ 1
#define KVIO_CLASS_PREFILL_WRITE 2
#define KVIO_CLASS_EVICT         3

#endif
