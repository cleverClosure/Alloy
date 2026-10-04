<!-- Author: Timur Isaev -->

# Seeded parser harness

Run both packages from any directory:

```sh
runtime/content-store/run-fuzz-harness.sh
runtime/content-store/run-fuzz-harness.sh --seed 1060002 --iterations 256
runtime/content-store/run-fuzz-harness.sh --self-test
```

The default run uses seeds `1060001`, `1060002`, and `1060003`, with 128 structured mutations and 128 byte mutations per parser per seed. Five production parsers run: Steam metadata, generation manifests, activation journals, generation leases, and transport records. The complete run therefore exercises 1,920 structured mutations and 1,920 byte mutations, plus corpus and well-formed controls. No networking is used by the harness; transport records contain an inert synthetic URL and are parsed locally.

## Independent controls

Before accepting a clean run, the script replaces each package's positive-control corpus with a known malformed input. The Steam parser receives invalid UTF-8; the content-store generation reader receives truncated JSON with a matching envelope digest. The same positive-control test that normally succeeds must now exit nonzero. The script also requires the control's execution marker, preventing an empty test filter or build failure from masquerading as detection. These failures come from the real parsers, not an unconditional assertion.

`--self-test` independently verifies successful exits, a deliberately failing command, and a timed-out command with a descendant process. The default gate additionally hangs a real Swift Testing case, records its PID and heartbeat, times out the actual Swift launcher, and verifies that the test process has stopped. This control exposed a real supervision defect: Swift placed its child in a different process group, and killing only the launcher group left that child running. The reusable macOS supervisor now follows bounded descendant identities (PID plus kernel start time), kills owned descendants first, and verifies cleanup. Output is capped at two MiB. This is supervision of cooperative local test tools, not a sandbox against adversarial process creation. Builds have a 180-second limit. Each package's filtered run has a 60-second limit by default (`--timeout 1..300`); individual mutation loops also enforce a 20-second deadline between parser calls. Limits bound hangs but do not measure parser throughput.

## Corpus and oracles

Steam seeds include all ten committed hostile `.acf` fixtures and their clean control under `runtime/store-identity/Tests/Fixtures/SteamMetadata`. Their known rejection categories remain checked. Structured cases generate unsigned-number violations and overflows and assert the complete `SteamMetadataError`, including source, field, and offending value. Every mutation is paired with a valid numeric control.

The JSON corpus includes the committed `main-21136e4-store` generation and journal fixtures, malformed JSON and unsupported-schema shapes already used in hostile reader tests, and deterministic records generated from the production models. Tests invoke `validateReference`, `readJournal`, `readLease`, and `readTransportRecord`; they do not substitute a stand-alone decoder for the production trust boundary. Generation payload mutations receive a recomputed envelope digest so the test reaches parsing and semantic validation instead of merely failing the outer hash check. All files are private synthetic scratch copies.

Structured JSON mutations assert exact named errors for unsupported schemas, mismatched identities, empty layers/digests, invalid nested sizes, unexpected lease fields, invalid process identity, negative byte counts, unsupported URL schemes, and invalid mirror indices. A correct document is reread after every hostile case.

Random byte cases use bounded bit flips, truncations, inserted bytes, and arbitrary byte strings seeded with SplitMix64. Each input is at most 4,097 bytes. These cases may either parse or reject; both outcomes are counted separately. Acceptance is not a failure unless a specific semantic property is violated. The harness reports `oracle=crash-only` for these cases and does not claim that every random string must be rejected, that all malformed forms are recognized, or that coverage has been measured. It is randomized testing, not coverage-guided fuzzing or libFuzzer.

## Defect found and fixed

Before the fix, `operation-a.json` could contain `operationId: operation-b` and `readJournal` accepted it. The dedicated `JournalIdentityBindingTests` regression failed against unmodified base `2356770` with “an error was expected but none was thrown.” The reader now requires the document identity to match the filename and returns `invalidJournal("operation-a")` for this substitution. Matching identities succeed before and after the hostile edit. This closes a parser identity check; it does not implement Custom/Certified policy.

The runner prints `PASS`, `FAIL`, per-parser seed/count records, and a final `SUMMARY`. Swift Testing remains the acceptance oracle, and its nonzero exit propagates. No new toolchain, SwiftPM dependency, package cross-dependency, or CI workflow is introduced here.

Local verification on 4 October 2026: the default three-seed matrix passed in 25 seconds initially and 22 seconds on rerun; both planted controls exited 1 before the clean runs. The runner's three lightweight supervision controls passed; the corrected full gate also passed its mandatory real Swift timeout control in 30 seconds. SIGTERM cancellation independently stopped that real child within three seconds, and a two-MiB-plus-one output control failed with bounded output. On base `2356770` plus this milestone, the full content-store suite passed 78 tests in 14.629 seconds after building. These are local wall-clock observations, not hosted-CI measurements or performance baselines.

Integrated verification after milestone 1: all 85 content-store tests passed in
14.645 seconds; the registered parser suite passed in 19.1 seconds after the cancellation follow-up. Hosted
validation is pending the GitHub account billing block; the milestone PR records
that external limitation rather than claiming an unrun hosted check.
