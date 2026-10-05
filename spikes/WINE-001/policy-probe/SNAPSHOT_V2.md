<!-- Author: Timur Isaev -->

# Process-policy snapshot v2

`ALLOYP02` is a bounded little-endian development contract. Runtime consumers
reject `ALLOYP01` with `policy-legacy-version`; the explicit v1 Swift API and
CLI remain available only for historical oracles. There is no downgrade or
implicit fallback when policy transport is requested.

## Layout and canonical identity

All integers are unsigned 32-bit little-endian. All fixed strings are printable
ASCII with one NUL terminator and zero padding. All unused slots are zero.

| Header offset | Field |
| --- | --- |
| 0 | Eight-byte `ALLOYP02` magic |
| 8 | Version 2 |
| 12 | Byte order `0x01020304` |
| 16 | Header size 96 |
| 20 | Entry size 7472 |
| 24 | Entry count, 1 through 1024 |
| 28 | Default index, always zero |
| 32 | SHA-256 of the complete entry bytes (`sourceDigest` in inspection) |
| 64 | SHA-256 of the complete file with bytes 64–95 zero (`contentDigest`) |

The maximum file size is 7,651,424 bytes. Exact executable digests are nonzero,
unique and sorted in byte order. Entry zero has a zero executable digest and
applies to every unknown image. Process context is still resolved before
encoding; distinct policies for the same executable hash remain unrepresentable.

| Entry offset | Field |
| --- | --- |
| 0 | Executable SHA-256, 32 bytes |
| 32 | Policy ID, 64 bytes |
| 96 | Graphics label, 64 bytes |
| 160 | Provider directory, 512 bytes |
| 672 | Presence flags |
| 676 | CPU provider: zero absent, 1 native-arm64ec, 2 fex-arm64ec |
| 680 | DLL route count, 0 through 32 |
| 684 | Environment count, 0 through 16 |
| 688 | Working directory, 512 bytes |
| 1200 | 32 DLL slots: 32-byte basename + 4-byte load order |
| 2352 | 16 environment slots: 64-byte key + 256-byte value |

Presence bits are graphics binding 1, CPU 2, environment 4, working directory 8,
DLL routes 16. Unknown bits reject. Absent fields contain only zero bytes.
Present empty environment and DLL tables differ from absent fields, while both
apply no changes. The policy ID is mandatory. Graphics label and directory are
present together. Directories must be absolute drive-qualified Windows paths,
without traversal, ambiguous trailing dots/spaces, search-path injection or
wildcards. Labels describe the provider binding; they do not install a provider.

DLL routes use the v1 enumeration: disabled 1, native 2, builtin 3,
native/builtin 4, builtin/native 5. Names are lowercase basenames without `.dll`,
sorted and unique; the encoder normalizes case and one extension. Core loader
modules (`ntdll`, `kernel32`, `kernelbase`, `libarm64ecfex`) cannot be overridden.

Environment keys normalize to uppercase and are sorted and unique under
case-insensitive comparison. Values may be empty. Transport and loader controls
(`ALLOY_*`, `WINE*`, `DYLD_*`, `LD_*`, `FEX*`, PATH, HOME, TMPDIR, SYSTEMROOT,
SYSTEMDRIVE, COMSPEC) are rejected. V2 sets only explicitly listed variables;
absence does not clear inherited variables. This is not an environment sandbox.
The profile compiler can apply a stricter allowlist. Unicode, deletion, more
than 16 variables, and values longer than 255 bytes are outside this contract.

## Verification and transport contract

The launcher supplies an inherited read-only regular-file descriptor in
`ALLOY_POLICY_SNAPSHOT_FD` and the complete file's lowercase 64-character SHA-256
in `ALLOY_POLICY_SNAPSHOT_SHA256`. It also supplies `ALLOY_POLICY_REQUIRED=1` so
loss of both transport fields cannot silently become stock mode. Each child
must inherit the descriptor and all three fields. Stock Wine behavior is
available only when all three are absent. A descriptor without its expected
digest, a digest without its descriptor, or a required flag without both fails.

The Wine integration must copy bounded bytes from the descriptor into private
memory, verify the independently supplied expected digest and internal digests,
validate every entry, and only then select a policy and modify process state.
The file should be unlinked and immutable to other holders; verification of the
private copy prevents a later file mutation from changing the applied policy.
The expected digest is an integrity binding to the caller's launch plan, not a
signature, authorization boundary or production trust root.

CPU `native-arm64ec` rejects x64 images before loading a translator; CPU
`fex-arm64ec` selects the fixed builtin FEX image for x64 images independently
of mutable prefix registry state. Native ARM64 images do not require a
translator. Other providers remain unlowered. Environment, working directory,
provider search path and load-order routes apply before guest imports. Any
failure terminates that process with a stable reason; no partially applied
policy proceeds to imports. This contract does not promise a game-wide sandbox.

## Milestone 1 controls

```sh
bash spikes/WINE-001/policy-probe/run-v2-controls.sh
```

The Swift tests cover canonical ordering, explicit absence/empty tables,
reserved controls, each-byte corruption and checksum-preserving malformed
fields. The native C validator runs under AddressSanitizer and UndefinedBehaviorSanitizer.
The shared corpus runs every malformed snapshot in a separate native process
and a separate Swift CLI process with finite deadlines. A negative process must
exit with a named `policy-*` failure and cannot emit the native caller's import
marker. This is a parser boundary control; actual Wine loader and guest import
proofs belong to the following integration milestones.

The native header is the source to embed verbatim in the Wine policy patch.
Its caller performs the SHA-256 checks first; it validates layout and semantic
canonicality without allocation. Swift additionally re-encodes decoded data and
compares every byte. The legacy v1 oracle remains unchanged.
