# Storage Semantics

KV-cache storage differs from ordinary durable application data.

## Key Properties

- frequently immutable after write
- often recomputable after loss
- tied to session and model context
- latency-sensitive on the decode read path

## POC Implications

- direct I/O is useful to reduce page-cache distortion
- cache creation writes can be demoted relative to decode reads
- discard and eviction can be backgrounded
- local experiments can test relaxed assumptions without designing a new permanent interface
