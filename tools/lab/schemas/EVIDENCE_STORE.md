# Evidence, baselines and retries

Author: Timur Isaev

Every scheduled attempt publishes its validated v2 record and artifacts into
`<queue>/evidence-store/objects/<sha256-prefix>/<sha256>`. The record binds the
scenario, host class, expected and observed runtime/subject/input digests,
expanded commands, logs, observations, archived runner sources and observed
runtime manifests. Raw attempt directories remain inspectable. Runtime binaries
are identified by digest; the lab does not duplicate whole runtime generations.

Publication writes and fsyncs a private temporary file, links it exclusively into
the object namespace, then commits a FULL-synchronous SQLite index transaction.
A bounded kernel file lease serializes initial journal/schema setup across
processes; normal WAL transactions remain concurrent. Objects are read-only and
never overwritten. A crash may leave an orphan object,
but cannot expose a partially indexed record. Reads rehash objects and reconstruct
the bounded artifact tree for independent evidence validation. Existing corrupt
objects are refused. Checksums detect accidental corruption; they are not signatures
or protection against an owner rewriting the entire database and object graph.
Retention and orphan collection are deliberately manual in this first version.

Baselines are keyed by effective scenario SHA-256, host-class SHA-256 and runtime
digest. They are **explicit**, never automatically learned from a candidate. A
baseline freezes clean completed calibration records, runner/scheduler identity,
subject/input identities, comparison algorithm digest and derived limits. Replacing
one requires its previous object digest and retains an append-only reference
history. Reading one recomputes the limits from its bound records. Changing code,
inputs or host/runtime identity yields INCOMPARABLE against an explicit baseline;
without a matching keyed reference the result is UNBASELINED, never CLEAN.

Exact and behavioral values must agree across calibration runs. Numeric thresholds
use the scenario's absolute/relative tolerance. Performance gates require eight
distinct calibration runs and use the larger of that tolerance and four times the
observed range; seconds-valued gates also retain LAB-001's 50 ms floor. A candidate
must start after freezing and cannot reuse a calibration run. This envelope is an
engineering guard, not a confidence interval or a certification claim. Visual
comparison is reserved and returns INCOMPARABLE; informational observations do not
gate. A baseline must include at least one gating observation.

```sh
python3 tools/lab/lab.py status /private/tmp/lab-queue
python3 tools/lab/lab.py baseline-set /private/tmp/lab-queue RECORD_SHA256
python3 tools/lab/lab.py work /private/tmp/lab-queue --drain --require-clean
python3 tools/lab/lab.py evidence /private/tmp/lab-queue RECORD_SHA256
python3 tools/lab/lab.py compare /private/tmp/lab-queue RECORD_SHA256
```

Every terminal attempt retains its evidence address, chosen baseline, verdict and
reasons. The scenario permits zero to three additional attempts, within the same
absolute job deadline. Failure, regression, incomparable and interrupted attempts
may retry; cancellation and deadline expiry never do. Recovery records interrupted
attempts even when no evidence survived. Queue schema 1 upgrades transactionally;
its prior completed attempts become UNBASELINED rather than fabricated passes.

History is the authority: job summaries are recomputed from checksummed attempt
comparisons. Different verdicts classify the job as FLAKY, preserving the worst
verdict and whether any attempt regressed. Only an all-CLEAN history passes a gate.
The reported failure probability is the observed fraction of non-CLEAN attempts,
not an estimated population probability. A failed first attempt followed by CLEAN
is FLAKY with fraction 0.5, never passed. Re-comparison is an explicit read operation
and does not retroactively rewrite recorded history. The work CLI returns nonzero
for flaky/failing outcomes; `--require-clean` also refuses UNBASELINED capture runs.
