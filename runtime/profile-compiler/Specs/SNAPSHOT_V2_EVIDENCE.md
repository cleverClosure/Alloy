<!-- Author: Timur Isaev -->

# Snapshot v2 compiler evidence

Milestone 3 of #177, measured on 5 October 2026.

- The complete profile compiler suite passes: 59 tests in 13 suites, including
  512 fuzz pairs and 14 seeded controls with no false accepts or crashes.
- A schema-valid profile resolves FEX, graphics, environment and working directory
  with neutral service modes, and exports a ready v2 process policy. Eight
  single-field mutations each make it not ready and identify the unsupported
  CPU, synchronization, network, diagnostics, feature-mask or service requirement.
- The frozen v1 source still reproduces its original recorded bytes exactly.
  V2 rejects those bytes with a named legacy-version error. V2 exports remain
  identical across ten reversed input orderings.
- Zero DLL routes is represented directly. Duplicate process identities,
  traversal and 33 routes reject. Environment, cwd and CPU appear in decoded
  v2 output and no longer appear as artificial coverage gaps.
- The development executable passes two positive controls (fully covered and
  diagnostic projection with a named gap) plus four rejection controls: unknown
  field, duplicate key, oversized input and existing output directory. Complete
  file SHA-256, read-only output mode and production ineligibility are checked.

Compiler version is 0.7.0. Updated complete-launch golden digests are:

| Fixture | SHA-256 |
| --- | --- |
| minimal | `877dad036f0d223f4ecef81e6bc6d710831aeb71301995c141daf9f0396cd588` |
| example | `c9e8e15bbae48ea93ba43e55503ac6b560adb15d83d0b158eea33acd40c4181e` |

Complete launches still include their conservative unknown-process deny/crash-only
requirements and other profile-level requirements. These remain genuine coverage
gaps; their readiness stays false. See [the contract](SNAPSHOT_V2.md) for the
distinction between ready process-policy exports and full session authorization.

The initial hosted run reported 41 passes, zero failures and two existing host
memory skips (the standard runner reports 7 GiB; session proofs require 8 GiB).
It then exceeded the 15-minute job budget during cleanup. Local validation runs
all 43 fast suites without skips. The CI job budget is now 20 minutes to admit
normal runner variance and cleanup; suite deadlines and coverage are unchanged.
