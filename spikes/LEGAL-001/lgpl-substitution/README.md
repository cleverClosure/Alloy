# LGPL-2.1 §6 modified-runtime path — proof and recipient instructions

**Author:** Tim Isaev
**As of:** 3 October 2026
**Covers:** counsel checklist item 4, the item the
[pre-counsel verdict](../../../docs/research/SPIKE-LEGAL-001-verdict.md) calls the
most concrete infringement risk on the list.

## What the obligation actually requires

Signing, notarization and content addressing are **not** inherently incompatible
with LGPL-2.1 §6, and the official release may stay immutable. The violation
would be if library validation, hash checks, launcher policy or signature
requirements rejected *every* substituted library — leaving a recipient with no
supported way to run their own build of an LGPL component.

So the obligation is to keep **one** working path open, and to prove it stays
open. That is what `prove-substitution.sh` asserts.

## Proven, 25 July 2026

A deliberately modified Wine `ntdll.so` (LGPL-2.1) was built from the tree in
`third_party/src/wine`, ad-hoc signed as a recipient would sign it, substituted
into a runtime, and executed:

```text
codesign -dv → flags=0x2(adhoc)
err:virtual:virtual_init ALLOY_LGPL_SUBSTITUTION_PROOF modified ntdll is live   (×8)
hello from x64 guest                                                     exit 0
```

The marker fires from `virtual_init()`, which every Wine process runs at
startup, so its presence proves the **modified** library is what executed —
not merely that nothing complained. The guest continued to work.

### Why nothing refuses substitution today

Measured rather than assumed:

| mechanism | state | would it refuse a substituted library? |
| --- | --- | --- |
| loader code signature | ad-hoc, no hardened runtime | No |
| library validation entitlement | absent | No |
| `alloy_policy` image pinning | `imageSHA256` keys the **guest executable**, selecting a provider; provider libraries are named by directory and load order, not by hash | No |
| content-addressed runtime | addresses a generation; does not verify member libraries at load | No |

The hatch is architecturally open. It is **not** guaranteed to stay open: adding
a hardened runtime with library validation, or extending policy pinning to
provider libraries, would close it. That is precisely why this is a CI gate and
not a one-off note.

## Proven from the bundle, 3 October 2026

The July proof built the modified library from the lab's own Wine checkout,
which a recipient does not have. `prove-bundle.sh` repeats it from what a
recipient does have — the corresponding-source bundle of a release:

```text
== 1. the bundle is intact                      28 files verified
== 4. configure as the bundle records           --with-mingw --without-x --enable-archs=arm64ec,aarch64
== 5. build the modified library from the bundled source
== 7. control: the runtime as shipped           marker absent; guest ran
== 9. run with the substituted library          marker observed 9 times; guest ran
== PASS                                         the supplied runtime is unchanged   (71 s)
```

Three things make this stronger than the July run:

- **Nothing of ours but the bundle.** The source is unpacked from
  `wine-src.tar.gz` and configured with the arguments read out of the bundle's
  own `BUILD-INPUTS.txt`. If either were wrong, a recipient would be stuck at
  exactly the step that fails here.
- **A control.** The unmodified runtime runs first and must *not* show the
  marker. Without that, a marker that always appeared would pass.
- **The runtime is never touched.** Substitution happens in a copy, and the
  script fails if the supplied runtime's library changed.

The first attempt failed, usefully: the bundle did not say that Wine's configure
needs bison 3 while macOS ships 2.3. `BUILD-INPUTS.txt` and `REBUILD.md` now
record it.

## Recipient instructions

They travel with the release, in the bundle's `REBUILD.md`, so they do not
depend on access to this repository. In short: unpack the component's source,
configure it as `BUILD-INPUTS.txt` records, build the library, ad-hoc sign it
(`codesign --force --sign - <library>`), and place it in the runtime at the same
relative path. No developer mode, entitlement or unlock step is required at
present; if a future release adds one, `REBUILD.md` must document it and the
gate below is what forces that.

## Running the proof

```sh
# 1. the bundle, audited against the runtime that ships
ALLOY_WINE_BUILD=spikes/WINE-001/work/build-2 \
ALLOY_DXMT_BUILD=<dxmt meson build dir> \
  tools/release/make-release.sh <version> <release-dir> \
    third_party/src/wine third_party/src/fex third_party/src/dxmt

# 2. the proof, from that bundle
spikes/LEGAL-001/lgpl-substitution/prove-bundle.sh <release-dir> <runtime-root>
```

The cross toolchain and bison 3 must be on `PATH`. By default the program
launched is Wine's own `cmd.exe`, which needs nothing but the runtime; the
script's header lists the variables for launching an x64 guest through FEX
instead.

`prove-substitution.sh` is the July script, kept because it is the quickest
check against a live checkout. It restores both the source file and the shared
build tree before substituting.

## What the bundle now guarantees

`tools/release/make-release.sh` was rewritten around one rule: publish the
source that was built, or say exactly what is missing.

- **A snapshot of the tree as built, not of its last commit.** In the lab,
  DXMT's entire fork is uncommitted, and Wine carries two uncommitted files.
  Archiving `HEAD` would have published source that does not correspond to the
  binaries. The snapshot is taken without writing anything into the checkout.
- **A dirty tree is still a gap.** A release that cannot be rebuilt from a
  commit is not reproducible.
- **What the fork deletes is named, not reproduced.** DXMT's `src/d3d12/` is
  absent from the tree that is built, so it is absent from the archive, and the
  fork patch records the 25 deletions as headers only.
- **Build inputs travel with the source**: configure arguments, DXMT's meson
  options and cross file, toolchain and bison versions.
- **GStreamer is audited per library actually linked.** Today: none, across 31
  binaries. Any linkage becomes a gap naming each library.
- **The SBOM is generated for the build**, not copied from a checked-in file
  that was three Wine commits stale. It records the elected LGPL version and
  ties DXMT's three binaries to the bundled source tree.
- **Notices, licence texts and a rights notice** (`NOTICES.md`,
  `licences/`, `LGPL-RIGHTS.md`) are generated into every bundle.

## Not yet done

Run against the lab trees today, the bundle records five gaps. None is hidden.
Four wait on a decision rather than on engineering:

- **Uncommitted source**, two gaps: Wine (2 files) and DXMT (32 paths). They
  are shared checkouts; committing them is the owner's call.
- **No public location for the bundle.** There is no release channel yet.
- **`LGPL-RIGHTS.md` is a draft.** The carve-out text needs counsel (#13).

The fifth is expected when bundling against the raw build, which still links
FFmpeg. A release bundles against the staged runtime (`stage-runtime.sh`), as
`release.yml` now does.

And three things this work does not cover:

- **No CI run on a clean machine.** `release.yml` targets a self-hosted runner
  that is not registered. Everything above was run on the lab machine.
- **DXMT substitution is not run.** Its source, build inputs and binaries are
  in the bundle, and nothing validates a provider library at load, but no
  modified DXMT library has been built from the bundle and observed running.
  That needs a windowed D3D11 title.
- **An x64 guest through FEX was not exercised from the bundle.** The one
  prepared prefix tried carries a stub emulator; the proof's control caught it
  and refused to conclude.

## Doc 18 §18 gate

The gate wording is "CI builds the published corresponding-source package,
substitutes a deliberately modified LGPL library, signs the resulting runtime as
documented, and verifies it launches", on a clean Mac. Building the published
package, substituting, signing and launching are now all proven, on the lab
machine. "CI" and "clean" are not. The gate stays **unticked**.
