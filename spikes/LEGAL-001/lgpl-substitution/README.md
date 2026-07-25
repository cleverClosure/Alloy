# LGPL-2.1 §6 modified-runtime path — proof and recipient instructions

**Author:** Tim Isaev
**As of:** 25 July 2026
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

## Recipient instructions (the documented path)

1. Obtain the corresponding-source bundle published with the release. It
   contains the fork source, patches, configuration, build scripts, interface
   material, dependency versions and these instructions — not links to upstream.
2. Build the component you wish to replace. For Wine:
   `make -C <build> dlls/ntdll/ntdll.so`
3. Ad-hoc sign it: `codesign --force --sign - <library>`
4. Place it in the runtime tree at the same relative path.
5. Launch normally. No developer mode, entitlement or unlock step is required
   at present; if a future release adds one, it is documented here and the CI
   gate below is what forces that documentation to exist.

## Running the proof

```sh
spikes/LEGAL-001/lgpl-substitution/prove-substitution.sh \
    third_party/src/wine \
    spikes/WINE-001/work/build-2 \
    <runtime-root> \
    <guest-exe>
```

It restores both the source file and the shared build tree before substituting,
so it does not leave a modified library behind for another agent to build
against.

## Not yet done

This is the mechanism proof. The rest of item 4 is not complete, and none of it
is blocked by the mechanism:

- **No release pipeline exists** — `.github/workflows/` has only `ci.yml` and
  `auto-merge.yml`, so "publish the corresponding-source bundle per release" has
  no release to attach to. The bundle generator is the next deliverable.
- **CI cannot run this on a GitHub-hosted runner.** It needs macOS on Apple
  silicon, the llvm-mingw toolchain, and a configured ~10 GB Wine build tree.
  A self-hosted runner is required, or the gate runs pre-release on a lab
  machine. Claiming a hosted-CI gate that cannot execute would be worse than
  stating this.
- **Only Wine is proven.** DXMT (LGPL-2.1-or-later since v0.80) and applicable
  GStreamer plug-ins need the same treatment, GStreamer audited **per plug-in**.
- **The elected LGPL version per "2.1-or-later" component is not recorded**, and
  FEX and MoltenVK obligations belong in the same SBOM (item 5, issue #24).
- **EULA carve-outs and notices** are not written.

## Doc 18 §18 gate

The gate wording is "CI builds the published corresponding-source package,
substitutes a deliberately modified LGPL library, signs the resulting runtime as
documented, and verifies it launches". Substituting, signing and verifying are
proven here. "Builds the published corresponding-source package" is not, because
that package does not exist yet. The gate stays **unticked**.
