<!-- Author: Timur Isaev -->

# Alloy profile compiler

`AlloyProfileCompiler` is EPIC-004 (issue #101): the standalone package that
turns a signed game profile, a runtime manifest, this exact Mac, and the
exact game build into one reproducible `LaunchSpecification`. It is a
small, self-contained program — no game, no account, and no signing identity
required to run its tests.

## Milestone 1: schema and fixture conformance core

The first milestone (see issue #101 for the full plan) delivered the
foundation: hand-written,
strict decoders for the two signed-object schemas, and proof that they track
those schemas exactly.

### What is here

- **Strict validators** for
  [`game-profile.schema.json`](../../docs/schemas/game-profile.schema.json)
  and
  [`runtime-manifest.schema.json`](../../docs/schemas/runtime-manifest.schema.json),
  read against [doc 05](../../docs/docs/05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md)
  for field meaning. `GameProfileValidator.validate(_:)` and
  `RuntimeManifestValidator.validate(_:)` take raw JSON `Data` and return a
  fully typed, decoded document or throw a `ValidationFailure` — never a bare
  "invalid". Every case names the exact JSON path and the exact rule broken:
  an unknown key, a missing required key, the wrong JSON type, a `const` or
  `enum` mismatch, a failed `pattern` or `date-time` format, a number outside
  its `minimum`/`maximum`, an array shorter than `minItems` or holding a
  `uniqueItems` duplicate, an object under `minProperties`, or none of an
  `anyOf` group's keys present.

  The technique follows the precedent in
  [`spikes/WINE-001/policy-probe/Sources/AlloyPolicySnapshot`](../../spikes/WINE-001/policy-probe/Sources/AlloyPolicySnapshot):
  hand-rolled `Codable` decoding with explicit key and value checks, no
  generic JSON-Schema engine. The one addition here is `strictContainer`
  (`Sources/AlloyProfileCompiler/JSONSupport.swift`): decoding a JSON object
  through a sibling `CodingKey` type that accepts any string recovers every
  key actually present, which is how `additionalProperties: false` gets
  enforced from inside a normal `Decodable.init(from:)` — the same object
  could not be re-derived from `KeyedDecodingContainer.allKeys` on the real
  `CodingKeys` type, which only ever reports keys it was asked about.

- **A fixture corpus** under `Tests/Fixtures/{GameProfile,RuntimeManifest}/`:
  - `valid/` holds the converted
    [`example-game-profile.yaml`](../../docs/examples/example-game-profile.yaml),
    a hand-built `minimal.json` (only the fields each schema actually
    requires) and `maximal.json` (every optional field populated) for both
    schemas, plus `boundary-maximums.json`/`boundary-minimums.json` (game
    profile) and `boundary-minimums.json` (runtime manifest): every
    `minimum`/`maximum`-bounded numeric field set to its exact inclusive
    limit, not just a value comfortably inside it — `minimal`/`maximal`
    happen to hit some bounds (`revision: 1`, `priority: 0`) but miss most of
    them (`priority`'s own maximum, `telemetry.sampling`, `memoryClassesGiB`,
    `deadlineSeconds`, every `size`/`peTimestamp`, `healthWindowSessions`).
  - `invalid/` holds 33 game-profile and 16 runtime-manifest documents, each
    breaking **exactly one** rule and named for it (for example
    `profile-id-pattern.json`, `empty-storefronts.json`,
    `process-match-empty.json`, `rm-component-size-wrong-type.json`). A
    numeric fixture that breaks a `minimum`/`maximum` rule sits one unit past
    the limit (e.g. `priority: 100001` against a maximum of `100000`), not
    far outside it, so it stays sensitive to an off-by-one in the bounds
    check itself. Every `ValidationFailure` case but one has at least one
    fixture that triggers it; `.malformed` — thrown only when the input is
    not syntactically JSON at all — cannot be expressed as a `.json` fixture
    without itself failing `tools/lint.sh`'s JSON-validity check, so it is
    instead covered by a direct unit test in `ConformanceTests.swift` that
    feeds literal non-JSON bytes straight to each validator's `validate(_:)`.

- **A conformance suite** (`Tests/AlloyProfileCompilerTests/ConformanceTests.swift`,
  `swift test`): every `valid/` fixture must decode; `example-game-profile`,
  `minimal`, and `maximal` are additionally checked field-by-field, and the
  `boundary-*` fixtures are checked field-by-field against the exact
  `minimum`/`maximum` each field decoded to, so a bounds check rejecting a
  legal edge value fails here, not just a crash or a silent accept; every
  `invalid/` fixture must be rejected with the one specific, pre-computed
  `ValidationFailure` it was built to trigger — not merely "some error". A
  companion test asserts the fixture table and the `invalid/` directory name
  exactly the same set of files in both directions, so a fixture added
  without a table entry (or vice versa) fails loudly instead of going
  untested.

- **A schema-drift suite** (`SchemaDriftTests.swift`): reads the two live
  schema files at test time (`SchemaDocument.swift` resolves their `$ref`s
  against `$defs` the same way a JSON Schema consumer would) and compares
  every object's declared `properties`/`required` and every `enum`/`const`
  against the validator's own `CodingKeys.allCases`, `requiredKeys`, and
  enum `allCases`. A schema edit that adds, removes, or renames a property, a
  required field, or an enum value turns the matching assertion red — the
  comparison always runs schema-file-against-validator, never the reverse.

- **A seeded mutation suite** (`MutationTests.swift`, `MutationSupport.swift`):
  walks a valid fixture in lockstep with the live schema and collects every
  admissible single structural mutation — drop a present required key, add
  an unknown key to an object, swap a scalar's declared JSON type for an
  incompatible one, or replace an `enum` value with one outside the list —
  pairing each with the exact `ValidationFailure` it must produce, computed
  from the mutation itself rather than from running the validator first. A
  fixed-seed (`mutationSeed`) deterministic shuffle (splitmix64, conforming
  to `RandomNumberGenerator`) samples a bounded number per fixture — the
  full admissible pool is large (60–300+ mutations depending on the
  fixture), re-running it every `swift test` would be wasteful, so a fixed
  seed keeps the sample reproducible without needing to run it all. Every
  sampled mutant must be rejected, for its exact precomputed reason, with no
  case ever reaching an uncaught trap.

### Why this design, concretely

Five deliberate-breakage drills (CLAUDE.md's measurement discipline — a
test does not get trusted until it is made to fail on purpose) found real
bugs or confirmed real sensitivity during this milestone's own development,
and are worth recording here as evidence the suites are not vacuous:

1. Removing a schema-driven key from a decoder's enforced required set,
   while leaving its `requiredKeys` constant (and so the schema-drift check)
   untouched, and with no named fixture happening to cover that exact key —
   caught **only** by the mutation suite, which computes its candidate pool
   from the live schema file, not from the validator's own constants.
2. Deleting one case from a Swift enum without touching the schema file —
   caught by the schema-drift suite, not the conformance suite (no fixture
   exercises every enum case directly).
3. Disabling one `pattern` check — caught by exactly the one named
   conformance fixture built for it, and no other.
4. Relaxing `checkPattern` back to "found a match" instead of "the match
   spans the whole string" — caught only by `profile-id-trailing-newline`
   and `rm-generation-id-trailing-newline`, which append one `\n` to an
   otherwise-valid pattern-checked value. NSRegularExpression's `$` (ICU)
   matches just before a trailing line terminator even without the
   multiline option, unlike the ECMA-262 `$` that JSON Schema `pattern`
   means, so "found a match" and "the whole string matches" do not coincide
   the way an anchored `^...$` pattern suggests they would.
5. Widening `checkBounds`'s maximum comparison from `value > maximum` to
   `value >= maximum` — caught only by `boundary-maximums.json` (and the
   mirror case on the minimum side, by `boundary-minimums.json` and
   `minimal.json`), because no other fixture sets a bounded field to its
   exact inclusive limit.

Each drill was reverted immediately after confirming the failure.

A non-obvious implementation detail the drills also surfaced: the mutation
sampler's input list must be built from a **sorted** iteration of each
schema object's `required` set. Swift randomizes a process's `String` hash
seed on every launch, so iterating a `Set<String>` without sorting first
changes the input order to `.shuffled(using:)` between runs — and a
differently-ordered input shuffled with the same fixed seed produces a
different sample, silently defeating "fixed seed, deterministic".
`MutationTests.samplingIsDeterministic()` exists specifically to catch a
regression of this.

### Build and verify

```sh
swift build --package-path runtime/profile-compiler
swift test --package-path runtime/profile-compiler
tools/test-all --tier fast --only profile-compiler-swift-test
```

The package is registered in the fast tier of `tools/test-all`, which the
existing CI job runs on every pull request.

## Milestone 2: canonical bytes, local envelopes, and host selectors

`CanonicalJSON` implements the bounded, versioned encoding described in
[CANONICALIZATION_V1.md](Specs/CANONICALIZATION_V1.md). `TestEnvelope.verify`
authenticates the object type, payload and expiry using an explicitly supplied
CryptoKit Ed25519 test key. Unsigned payloads require explicit Development
Mode. No production trust root is bundled or implied.

`HostCapabilities.current()` uses native macOS and Metal APIs. Host and
manifest selectors match versions, exact OS builds, GPU families, memory,
features, and entitlements. The normalized SHA-256 identity is explicitly
`local-unregistered:…`, never a control-plane host-class identifier.

Milestone 2 added six tests (38 total in seven suites), including a ten-run canonical
byte golden, 24 published numeric vectors, 10,000 independent ECMAScript
number comparisons, signature/expiry/unsigned controls, and real-host
positive and impossible-host negative selectors. Fixtures use only the
committed, publicly disclosed TEST-ONLY keypair.

## Milestone 3: profile and process resolution

`ProfileCandidate`, `ProfileResolver`, and `ProcessResolver` implement build,
launcher, host, client eligibility, all five profile tie-breakers, process
precedence, composed restrictions, explicit inheritance, and conservative
unknown-process defaults. Ambiguous candidates and policies fail closed.
[RESOLUTION_V1.md](Specs/RESOLUTION_V1.md) defines local signed alias/eligibility
metadata and the explicit specificity and bounded regex rules.

The 46-test suite includes five profile and seven process golden pairs, ten
order-reversed evaluations per pair, and one deliberate implementation-defect
control per precedence rule. Each control fails its named test before restored
code passes. Matching also covers exact files, every process match dimension,
all host/client gates, alias tampering, stale history, and expired candidates.

## Milestone 4: existing Wine snapshot format

`PolicySnapshotExporter` projects resolved policies through a local SPM
reference to WINE-001's unchanged `AlloyPolicySnapshot` library. There are no
external dependencies. The exported bytes match the existing CLI and the
preserved July 24 snapshot byte for byte, including its recorded SHA-256.

The export reports `notYetLowered` fields and is explicitly not runtime-ready:
Wine v1 cannot encode CPU, synchronization, network, feature masks, environment,
and other complete policy semantics. [SNAPSHOT_V1.md](Specs/SNAPSHOT_V2.md)
documents every field, the empty-route diagnostic projection, the historical
oracle, and a reproduction command that runs no Wine guest.

All 49 tests in ten suites pass. Corrupting the projected provider breaks the
external golden; hiding the environment coverage gap breaks its paired test.

## Milestone 5: complete local launch export

`LaunchCompiler.compile` verifies the complete input tuple, selects a profile,
validates exact certification/workaround/vendor scope, checks synthetic feature
ceilings and local grants, resolves processes, and emits an immutable
`LaunchSpecification` bound to its component and snapshot digests. `verifyExport`
re-resolves the authoritative inputs and compares complete canonical bytes.
[LAUNCH_V1.md](Specs/LAUNCH_V1.md) defines the local evidence contract and limits.

The unchanged converted example and a minimal fixture both compile reproducibly
across ten runs and order variations. All 56 tests in twelve suites pass.
Paired negatives cover incomplete workarounds, expired/withdrawn certification,
over-ceiling masks, unscoped competitive claims, foreign grants, unsafe root
access, secret/injection environment keys, and unknown evidence fields. Seven
deliberately disabled semantic checks each failed their named test before the
restored suite passed. Competitive scope uses a separate public vendor test key.

Exports always identify their test/development provenance and local host-ID
placeholder. They are not production eligible or runtime ready: all unlowered
process and profile fields remain explicit in the artifact.

## Milestone 6: full-pipeline fuzzing and completion

The complete compiler suite now has **57 tests in 13 suites**, including a
512-iteration structured fuzzer over the profile + manifest + build + host +
evidence tuple. The fixed seed is `0x101600DCAFE`. Each iteration accepts a
coherent clean tuple and rejects a paired invalid tuple; all 14 mutation
categories have seeded controls before the run is trusted. The audit also
checks output identities and component digests against the input documents.

The completed run reports 512 valid compiles, 512 rejections, zero crashes,
and zero false accepts. Full launch-output digests are pinned for both valid
fixtures and checked across ten separate processes. These regression goldens
complement the independent Wine snapshot and ECMAScript number oracles.

[PIPELINE_VERIFICATION.md](Specs/PIPELINE_VERIFICATION.md) records commands,
controls, CI evidence, limits, and the applicable doc 05 pre-signing checklist.
The package remains a library with no external dependencies and no executable
guest requirement. Its one local package dependency is WINE-001's existing
snapshot library, used read-only. No production signing identity or account is
needed; the committed test keys are intentionally public fixtures.
