# WINE-001 — deterministic pre-import policy hook and rebase readiness

**Author:** Timur Isaev
**Date:** 24 July 2026
**Wine branch:** `alloy/spike-wine-001`
**Policy patch:** `47e4cdb75d7bf25ce7fecc6301a12bf9aa317b90`
**Upstream base:** `5bb70f23d1278088d9ea55d44efe7d51f87d35bd`

## Decision

Gate 4 passes. Wine can select process-local DLL providers from exact executable
identity before normal executable imports resolve, without a global environment or
registry race. A launcher, its game child, and an unknown child ran in one Wine
session and loaded three different physical implementations of the same statically
imported DLL name.

Gate 5 remains open for an external reason: official Wine `master` had not advanced
past this patchset's base when checked. A rebase onto the identical commit would
provide no drift or conflict-cost evidence.

## Contract proven

The `alloy_policy_bootstrap` call is in `loader_init()` after
`ProcessParameters` and the default DLL path exist, and before WoW64 initialization,
`kernel32`, and normal executable import fixups.

When `ALLOY_POLICY_SNAPSHOT_FD` is absent, the Unix query returns
`STATUS_NOT_FOUND`; Wine performs no image hash, changes no loader state, and
continues on its stock path. When present:

1. Wine hashes the exact process image with SHA-256.
2. The Unix side accepts only an inherited read-only descriptor for a regular file
   no larger than 16 MiB.
3. It maps that descriptor privately and read-only, validates a fixed versioned
   binary layout, binary-searches sorted exact-image entries, and otherwise selects
   entry zero as the restricted default.
4. It installs process-local load-order routes and prepends the selected provider
   directory to the process-local PE search path.
5. Any malformed or unsupported snapshot terminates the process before imports.

The environment carries only the inherited descriptor number. The policy itself is
not serialized into environment variables, `WINEDLLOVERRIDES` is explicitly unset
by the proof, and no registry state is changed.

## Snapshot and harness

The first-party Swift package in `spikes/WINE-001/policy-probe` provides:

- strict JSON decoding with unknown-key rejection;
- semantic normalization and deterministic ordering;
- duplicate digest and duplicate route rejection;
- bounded ASCII identifiers and absolute Windows provider paths with injection
  characters rejected;
- a fixed 64-byte header and 968-byte entries;
- `compile`, `inspect`, and `sha256` commands.

The runner builds freestanding ARM64 PE marker providers and guests. All three guest
programs statically import `alloygraphics.dll`; only the policy-selected provider
directory changes. The launcher creates both children with `CreateProcessA`, so the
snapshot descriptor and Wine session are shared naturally.

The runner compiles identical input twice and requires byte-for-byte equality, opens
the snapshot read-only on descriptor 9, unlinks it before launch, and checks both
Wine traces and guest-observed provider IDs.

## Reproducible results

Commands:

```sh
env PATH="$PWD/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  make -C spikes/WINE-001/work/build-2 -j8 \
  dlls/ntdll/ntdll.so dlls/ntdll/aarch64-windows/ntdll.dll

env SWIFT_MODULECACHE_PATH=/tmp/alloy-policy-swift-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/alloy-policy-clang-cache \
  swift test --disable-sandbox --package-path spikes/WINE-001/policy-probe

spikes/WINE-001/policy-probe/run-policy-proof.sh
```

Results:

- native Unix `ntdll.so` and hybrid ARM64/ARM64EC `ntdll.dll`: built;
- Swift validation/determinism suite: 5/5 passed;
- snapshot size: 2,968 bytes;
- snapshot SHA-256:
  `39adf17b81e5b35dd7120d66ebe17bae58007ed506fbb51e866e9e209ac700f5`;
- canonical source digest:
  `0ed8c8a6225e2c269ebe16d902bc1b590448cfe05efb8946994dcd69a9536348`;
- launcher image:
  `1fbae6162be04099e54d4d5aabf8fe86ce9b5db53d7eca4c4fd5e13c640e0e4f`;
- game image:
  `02db127009a1e2c30b4b7968de2b96732b15c4dd69b96ee3b9291ceb0cfbd30e`.

Selection evidence:

```text
selected policy launcher graphics dxmt default 0 ... before imports
PROBE role=launcher provider=dxmt id=11
selected policy game graphics metal12 default 0 ... before imports
PROBE role=game provider=metal12 id=12
selected policy unknown-restricted graphics restricted default 1 ... before imports
PROBE role=unknown provider=restricted id=0
SESSION game=0 unknown=0
PASS WINE-001 policy hook
```

The load trace resolves those imports from the physical `providers/dxmt`,
`providers/metal12`, and `providers/restricted` directories respectively.

Fail-closed evidence:

- descriptor opened read-write: `STATUS_ACCESS_DENIED` (`c0000022`);
- schema version patched from 1 to 2: `STATUS_REVISION_MISMATCH`
  (`c0000059`);
- absent descriptor: `cmd.exe` printed `POLICY-HOOK-STOCK-OK` and exited 0.

Existing low-VA allocation and missing-FreeType diagnostics remain visible on this
host and are independent of the policy selection result.

## Patch budget

The Wine patch adds 491 lines across eight files:

| Area | Added lines | Purpose |
| --- | ---: | --- |
| PE loader | 99 | Query, image hash, apply path, trace, fail closed |
| Unix snapshot parser | 274 | FD checks, fixed-layout validation, lookup, routing |
| Shared ABI | 79 | Bounds, fixed records, bootstrap parameters |
| Process-local load order | 31 | In-memory route insertion/update |
| Build and Unix-call wiring | 8 | Registration |

The full local Wine delta is six commits. The hook is isolated to one startup call,
one new parser, one small load-order API, and interface wiring.

## Rebase readiness check

At `2026-07-23T21:02:25Z`:

```text
local patch base: 5bb70f23d1278088d9ea55d44efe7d51f87d35bd
git fetch --depth=1 origin master: 5bb70f23d1278088d9ea55d44efe7d51f87d35bd
git ls-remote origin refs/heads/master: 5bb70f23d1278088d9ea55d44efe7d51f87d35bd
patch commits above base: 6
working tree: clean
```

Once official `master` advances, run the drill on a disposable branch:

```sh
git switch -c alloy/spike-wine-001-rebase-drill alloy/spike-wine-001
git rebase --onto <new-origin-master> 5bb70f2
```

Record elapsed time, conflicted files, manual resolutions, new commit IDs, both
`ntdll` build targets, the five Swift tests, and the full policy proof. Preserve the
original evidence branch.

## Deliberate Phase-0 limits

- Startup currently reopens and hashes the process image. Production should use a
  SessionAgent-cached identity bound to file identity and the immutable launch
  specification, both to avoid TOCTOU and to meet the sub-millisecond lookup target.
- The source digest is carried in the snapshot but is not cryptographically verified
  inside Wine. This proof trusts an inherited, unlinked, read-only descriptor;
  production should bind its digest to the launch specification.
- The version-1 bounds are 511 ASCII path bytes and eight DLL routes per policy.
- CPU-provider initialization and SessionAgent registration are not part of this
  patch. The hook location and fixed ABI provide bounded extension points for them.
- The provider-path prepend is one-shot process-lifetime state.
