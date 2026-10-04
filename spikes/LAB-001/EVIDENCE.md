<!-- Author: Timur Isaev -->

# LAB-001 evidence v1

`evidence.py` creates local engineering records from published `raw.json`
runs. It uses only Python's standard library. A record is not certification,
a reviewer approval, an external attestation, or an authenticated signature.

```sh
python3 spikes/LAB-001/runner.py --output /tmp/lab-evidence-example
python3 spikes/LAB-001/evidence.py capture /tmp/lab-evidence-example
python3 spikes/LAB-001/evidence.py validate /tmp/lab-evidence-example/evidence.json --artifacts /tmp/lab-evidence-example
```

Choose a fresh run directory. The capture command preserves the complete raw
lifecycle, including named failures, and writes `evidence.json`. Validation
without `--artifacts` checks structure, semantics, internal identities, and the
record checksum. With `--artifacts`, it additionally checks every bound file's
type, size, and bytes, rejects symlinks, verifies the raw record and stdout
metrics, and recomputes the captured frames' pixel sum. Unrelated output files
are not included in the claim.

The strict versioned record contains:

- Git commit and dirty-state disclosure, plus archived non-test Python files
  with individual sizes and SHA-256 values. New first-party Python modules in
  this directory automatically enter the inventory.
- Python executable path, binary hash, implementation and version; host OS,
  OS build information, architecture, CPU count, and physical memory.
- Effective scenario definition and digest, original scenario-file digest,
  subject digest, exact argv, execution-input hashes before and after the run,
  lifecycle events, measured timings, counters, and complete raw record.
- Request, operation and session IDs; synthetic game/build, host class,
  runtime-generation, profile, process policy, provider, test-plan, scenario,
  runner, and local release-ring correlation fields based on doc 10 §5.
- Explicit metric units, provisional engineering thresholds, no approvals or
  waivers, and the synthetic-only limitations from issue #77. Empty thresholds
  mean that this evidence slice has not calibrated an envelope. Populated
  bounds must name their calibration digest; they are not doc 07 certification
  policy values.
- Byte counts and SHA-256 bindings for all frames, stdout, stderr, raw JSON,
  and archived source files.

For completed runs, the four selected execution inputs (runner, scenario
validator, subject and Python executable) must match before and after
execution and match the files identified at evidence capture. Auxiliary
modules added by later milestones are archived at capture time. These are
selected-file checks, not a complete Python standard-library or OS dependency
closure, and not independent proof that the reported commands executed.
Failed runs preserve their observed failure even when inputs changed.

The effective scenario definition and archived sources permit reconstruction
without relying on the dirty working tree. Use the recorded interpreter and
host class, reconstruct the scenario from `raw.scenario_definition`, and pick
a fresh output directory. UUIDs, timestamps, elapsed times and host scheduling
are expected to differ; image bytes and deterministic counters have the
separate known-answer contract in `SCENARIO.md`.

The integrity field is SHA-256 of UTF-8 canonical JSON: sorted keys, compact
separators, ASCII escapes, finite numbers, and the entire `integrity` field
omitted. It detects accidental edits when the original checksum is retained.
Anyone able to edit the record can recompute the checksum. It provides no
signer identity or malicious-edit protection, needs no Apple Developer ID,
and does not satisfy production signing or certification requirements.

The public API is `build_record(raw, output, session_id=None)`,
`validate(record, artifact_dir=None)`, and `write_record(record, path)`.
`canonical(value)`, `hash_value(value)` and `seal(record)` support later local
report producers. After adding calibrated thresholds, call `seal` and then
`validate`; sealing is deliberately named separately from validation.

The independent hand-authored test fixture does not call the record builder.
Tests reject missing fields, wrong types including booleans as integers,
truncated digests, unexpected fields, nonfinite timings, inconsistent sums,
execution-input drift, invalid correlation, unsafe paths, duplicate artifact
entries, unsupported claims, missing calibration identity and checksum
tampering. Real run controls verify byte corruption and symlink rejection.
Two CLI validations of the same fixture must produce identical output.
