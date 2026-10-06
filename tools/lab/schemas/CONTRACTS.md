# Scenario and evidence v2

Author: Timur Isaev

## Authority and migration

The JSON schemas describe structure. `alloy_lab.scenario.validate` and
`alloy_lab.evidence.validate` are the normative cross-field validators; their
checks also cover canonical digests, templates, ordered lifecycle data and actual
artifact bytes. No third-party schema library or network resolution is needed.
Unknown fields, duplicate JSON keys, nonfinite numbers, boolean numeric values,
unsafe relative paths, unbound tokens and incomplete identities fail closed.

`migrate-v1` accepts the existing LAB-001 validator's complete v1 format. It
retains the original decoded definition and original-file SHA-256 under `legacy`,
including the committed clean/seeded known-answer oracle. Its seven observations
are four complete frame hashes and the three subject counters. Migration also
binds the actual subject and Python executable. Re-reading the serialized v2
record preserves the entire definition. Existing spike source and result links
remain untouched. Migration is performed on the intended Mac; a different Python
binary requires an explicit new runtime binding, not an invented portable hash.

## Scenario

A scenario has its own ID/revision, subject kind and bytes, an explicit runtime
manifest, host requirements, input files, setup/run/teardown steps, observables,
a timing flag, total deadline, bounded retry policy and provenance context.
`context` identifies the game build, profile and automation by digest, names the
cache state, and limits this local tool to inputs without account secrets.

The runtime digest is SHA-256 of canonical JSON containing `kind`, `executable`
and the complete declared `files` mapping. Every file has a relative path, byte
count and SHA-256. The runtime root and input root are bound by the submission
caller, outside the portable scenario definition. Runtime files and the subject
are verified before and after execution. The manifest identifies declared runtime
inputs; it does not claim to hash the OS, firmware or Python standard library.
The observed host class covers that environment separately. Wine callers must
inventory every staged runtime component; a launcher-only digest is insufficient.

Each command is an argv array whose executable is a declared runtime file. There
is no shell interpolation. Tokens are `{runtime}`, `{runtime_root}`, `{runtime_file:ID}`, `{subject}`,
`{input:ID}`, `{work}`, `{control}` and `{attempt}`. They are expanded by the runner,
never by a shell. Setup, run and teardown are ordered, with at least one run step.
Every step has its own timeout and expected exit status; total time is bounded.
Scenarios are trusted local automation, not a sandbox for hostile executables.

Comparison classes follow doc 07: exact, numeric tolerance, behavioral,
performance, informational and visual. File hashes, JSON keys, exit statuses and
measured step duration are explicit observation sources. A performance comparison
or duration observation requires the exclusive timing flag. Numeric tolerances
are declared absolute/relative limits with an explicit direction. Visual policy
has a representation for a future adapter; a missing visual comparator must
report INCOMPARABLE, never silently count as a pass. Windows-reference subjects
have a format slot but are not executable on this Mac.

The control label records clean/seeded/hang/error/flaky instrumentation. It never
determines a comparison verdict. A later retry may add observations but cannot
erase an earlier failure. Runtime changes require explicit baseline selection;
a digest mismatch is not a regression measurement.

## Evidence

Evidence includes the complete scenario and original source digest, run/job/attempt
IDs, UTC timestamps, monotonic durations and lifecycle events, expanded commands,
exit statuses, observations, artifact digests, named failures and checksum. The
provenance binds runner and scheduler source identities, privacy-safe hardware/OS/
firmware capabilities, scenario digest, expected/pre/post runtime and subject
identities, expected/pre/post input identities, and environment/lock health.
No serial number, hardware UUID, account identifier or host name belongs in the
host class. An unavailable capability is disclosed rather than guessed.

COMPLETED requires every expected step, expected exit status and observation,
stable matching execution inputs, satisfied host requirements and the appropriate
held resource lock. It is a lifecycle outcome, not a certification or comparator
pass. Failed/cancelled/deadline/interrupted/incomparable records retain reasons.
With an artifact directory, validation re-hashes files and independently extracts
JSON observations; a re-sealed record cannot invent a different captured answer.
File-hash observations must match the artifact inventory even without file access.

Canonical JSON uses sorted keys, compact separators, ASCII escapes and finite
numbers. The checksum omits the entire `integrity` field. This detects accidental
edits; it is not a signature, trusted execution attestation or certification.
Evidence is explicitly `local-engineering-not-certification`. Limits bound JSON,
command counts, retries, individual artifacts and aggregate artifact bytes.

## Scope decisions

Python stdlib preserves the working prototype's implementation and avoids adding
a second runtime or dependencies. The spike is wrapped rather than moved so its
historic result URLs and reproducibility tools continue to work. Host requirements
are explicit equality constraints in addition to OS, architecture and memory;
missing required capabilities make a run incomparable. Full signing, Windows
reference execution, real title/account workflows and cloud storage stay outside
this epic. Docs are read-only; this package records the decisions it consumes.
