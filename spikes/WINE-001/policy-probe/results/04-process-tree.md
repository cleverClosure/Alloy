<!-- Author: Timur Isaev -->

# Snapshot v2 process-tree proof

Milestone 4 of #177, measured on 5 October 2026. All **210** actual Wine runs
passed: 14 positive/negative integration controls and 196 separate malformed
snapshot processes. The [machine-readable result](04-process-tree-proof.json)
records guest hashes, exact observations, named failures, mapped translator paths
and the verified runtime identity. Raw logs remain in
`/private/tmp/alloy-177-tree-b1`; the committed report extracts observations and
failure reasons from those logs after the run without repeating execution.

## One session, three policies

The actual profile compiler's development exporter lowered the trusted resolved
tuple into one snapshot with digest
`sha256:8ff543bdfc8b5d0d9b3d8f7b8e3329deb3103211b910dcb5535a171f91db38c2`.
Its report is `runtimeReady: true`, with no coverage gaps and
`productionEligible: false`. The native launcher started both children using
`CreateProcessA`, retaining the same unlinked read-only snapshot descriptor and
expected digest. No per-child host harness substituted a policy.

| Guest | Selected marker DLL | CPU | LANG | cwd suffix |
| --- | --- | --- | --- | --- |
| launcher, exact SHA | dxmt | native ARM64, no FEX | launcher | cwd-launcher |
| game, exact SHA | metal12 | x64 through FEX | game | cwd-game |
| unknown, default | restricted | native ARM64, no FEX | unknown | cwd-unknown |

Every value was observed in the selected DLL's attach routine before the guest
entry point, then observed again in the guest. Exact provider paths were checked.
The launcher reported `SESSION children=0` after both children exited successfully.
The labels name synthetic DLLs and prove routing, not graphics rendering.

The unknown default denies `alloyblocked`; the DLL is present and loads in the
stock control (`allowed=1`) but does not load in the managed unknown child
(`allowed=0`). An unlisted x64 executable receives the default native-only CPU
policy and fails `policy-cpu-incompatible`. This default restricts CPU admission
and DLL loading. Neutral service modes are explicit development inputs; network
denial and crash-only collection remain unlowered in complete launch plans.

## Integrity and malformed controls

- Corrupted bytes with the original expected digest and a deliberately mismatched
  expected digest fail `policy-expected-digest`.
- Corrupted bytes with a recomputed expected digest fail `policy-integrity`,
  proving the internal integrity check independently.
- Dropping the descriptor while retaining the required flag and expected digest
  fails `policy-descriptor-missing`.
- All 196 malformed corpus cases fail with a named policy reason, nonzero exit,
  and no guest import or entry marker. This includes v1, truncation, trailing
  data, checksum-preserving semantic corruption, duplicates and seeded mutation.
- The ten milestone-2 controls also pass, including stock field absence, disabled
  imports, explicit FEX selection and native-only rejection of x64.

The exact FEX image loaded from the materialized generation's builtin location.
The private prefix had no FEX registry registration. The runtime tree is the
fresh completed milestone-2 build, recipe
`5865d2c35cacafc63ea25d1cd30623bd2db99d852d782e161f09538536481f39`,
generation `rtg_76def2c40743993cff2ce99c7a1f5fd93a2b9bc246977e050a2184b340943c00`.
Materializer verification before and after matched. All owned guest and server
processes were cleaned up; the shared Wine branch, dirty edits and build-2 were
not changed.

The [session handoff](../SESSION_HANDOFF_V2.md) specifies transport, readiness,
identity, cleanup and residual limitations for the following launch epic.

## Combined repository validation

All 43 fast suites have passing results against the combined milestone changes.
The first run passed 42 and exposed the parser harness choosing llvm-mingw's
`clang` from PATH instead of the macOS compiler. Milestone 2 fixes that selection
with `xcrun --sdk macosx clang`; the focused rerun passes all 9 snapshot tests and
392 malformed-input parser processes under ASan/UBSan with that same PATH.
No runtime source, snapshot format or recipe changed for the harness fix.
The development export command's two positive and four rejection controls pass.
