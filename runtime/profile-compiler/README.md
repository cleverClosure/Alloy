<!-- Author: Tim Isaev -->

# Alloy profile compiler

`AlloyProfileCompiler` is EPIC-004 (issue #101): the standalone package that
will turn a signed game profile, a runtime manifest, this exact Mac, and the
exact game build into one reproducible `LaunchSpecification`. It is a
small, self-contained program — no game, no account, and no signing identity
required to run its tests.

## Milestone 1: schema and fixture conformance core

This is the first of six milestones (see issue #101 for the full plan). It
delivers only the foundation everything else is built on: hand-written,
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
    plus a hand-built `minimal.json` (only the fields each schema actually
    requires) and `maximal.json` (every optional field populated) for both
    schemas.
  - `invalid/` holds 32 game-profile and 15 runtime-manifest documents, each
    breaking **exactly one** rule and named for it (for example
    `profile-id-pattern.json`, `empty-storefronts.json`,
    `process-match-empty.json`, `rm-component-size-wrong-type.json`). Every
    `ValidationFailure` case has at least one fixture that triggers it.

- **A conformance suite** (`Tests/AlloyProfileCompilerTests/ConformanceTests.swift`,
  `swift test`): every `valid/` fixture must decode; three of them
  (`example-game-profile`, `minimal`, `maximal`) are additionally checked
  field-by-field; every `invalid/` fixture must be rejected with the one
  specific, pre-computed `ValidationFailure` it was built to trigger — not
  merely "some error". A companion test asserts the fixture table and the
  `invalid/` directory name exactly the same set of files in both
  directions, so a fixture added without a table entry (or vice versa) fails
  loudly instead of going untested.

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

Three deliberate-breakage drills (CLAUDE.md's measurement discipline — a
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
```

### What milestone 1 does not cover yet

Everything past schema conformance is later milestones of issue #101, in
order: canonicalization and envelope-signature verification against a local
test key (milestone 2); real host-selector matching against this Mac's
actual capabilities, and build/host/process-policy selector precedence and
conflict resolution (milestones 2–3); lowering a resolved process policy
into WINE-001's existing policy-snapshot wire format (milestone 4); the
`LaunchSpecification` export itself, plus certification, workaround, and
feature-mask validation (milestone 5); and a full-pipeline fuzzer with CI
wiring and the canonicalization/field-coverage write-up (milestone 6). None
of that — selectors, precedence, canonicalization, signing, or
`LaunchSpecification` — exists in this milestone. This package also does not
yet have a CLI or any executable target; it is a library only.
