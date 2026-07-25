<!-- Author: Timur Isaev -->

# Alloy activation journal 1.0

## Purpose

The activation journal is the durable recovery record for one
`activate-generation` operation. Its JSON representation MUST validate against
[`activation-journal.v1.schema.json`](activation-journal.v1.schema.json).
Files are encoded with sorted keys, written to a same-directory temporary file,
fsynced, renamed over the prior record, and followed by a directory fsync.

The journal is local recovery state. It is not the signed runtime manifest from
doc 05 and is never accepted as artifact authorization.

## State machine

```text
started
→ downloaded
→ verified
→ published
→ materialized
→ candidate-prepared
→ rollback-recorded
→ active-switched
→ health-checked
→ retained
→ complete
```

`aborted` is terminal and is used when a `started` operation cannot recover a
complete verified download set. `complete` and `aborted` journals are immutable
terminal records.

For each nonterminal transition:

1. replay the stage's filesystem action idempotently;
2. inject the `after-<stage>-action` fault boundary;
3. advance and durably replace the journal;
4. inject the `after-<stage>` fault boundary.

Recovery reads every nonterminal journal under the single-writer lock and
replays from its recorded state. It rejects an unsupported schema version,
unknown operation kind, invalid identifier, empty layer list, or malformed
layer descriptor.

## Activation invariant

An active reference is written only after:

- every layer's authorized size and SHA-256 digest validates;
- every CAS object is durably published;
- the complete ordered generation manifest is durably materialized;
- the candidate reference validates;
- the previous active reference is durably retained as rollback.

A failed health result restores the previous valid active reference before the
journal advances to `health-checked`. Candidate cleanup never traverses save
volumes.

## Evolution

Version 1 readers accept only schema `1.0`. Persisted semantic changes require
a new schema and an explicit migration or bounded compatibility reader. A
client MUST reject an unknown version instead of attempting best-effort replay.
