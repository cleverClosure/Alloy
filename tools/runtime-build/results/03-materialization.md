<!-- Author: Timur Isaev -->

# Milestone 3: verified executable generation

The finalized milestone-2 package C4 imported into
`/private/tmp/alloy-176-store` and activated as game `runtime176` on 2026-10-05.

- Generation: `rtg_43c1e4c9c306e60a45fbf20676509213317e0908f022ac6d172d84dbefd77387`.
- Store manifest: `sha256:704a8eb37d563cf0940d7b1c803bf3842a71ec351423f68cd3e6af67a2364394`.
- Composed tree: `sha256:cc293aff9e071347a64f7945af2807e073fc72515d5d88c3723f5819637245c5`.
- Actual FEX image: `sha256:8a55a52c53a1185d305120e35dd8e19d4f515f55199db762f8af1931fca8eec7`.

The runtime root was the store's `runtime-trees/<store-manifest-hex>` directory.
Wine's success-only `alloy_builtin_image` trace named that exact root's
`dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll`; the normal builtin-load
event also occurred. This is evidence of the mapped image, not a lookup or an
assumption about the prefix. Native cmd printed `alloy-native-ok` with exit 0;
x64min returned 42; ISA smoke returned 0 with both semantic and advertisement
success messages. The unregistered prefix loaded the known refusal stub,
reported that x64 emulation was not implemented, exited 1 and mapped no FEX.

Commands followed the README's import/verify/prove flow. The smoke proof used
output `/private/tmp/alloy-176-proof-c4`, toolchain from clean build C and the
materializer built in this worktree. The unchanged corpus command was:

```sh
python3 spikes/CPU-001/isa-corpus-runner.py \
  --wine-build /private/tmp/alloy-176-store/runtime-trees/704a8eb37d563cf0940d7b1c803bf3842a71ec351423f68cd3e6af67a2364394 \
  --wine-source /Users/cleverclosure/Developer/Alloy/third_party/src/wine \
  --fex-source /Users/cleverclosure/Developer/Alloy/third_party/src/fex \
  --toolchain /private/tmp/alloy-176-build-c/toolchain/llvm-mingw-20260616-ucrt-macos-universal/bin
```

All **27 required FEX outcomes across 13 families** passed: clean and named
mutation cases plus the atomic ticket control. Native references and parser
controls also passed. Both smoke and corpus recorded identical before/after
runtime inventories. The corpus's shared-checkout revision/dirty diagnostics
are context only; the build recipe identifies the Git objects that actually
supplied the runtime. No source checkout or shared runtime was modified.

[03-runtime-proof.json](03-runtime-proof.json) retains the generation identity,
actual mapped paths, outcomes, checksums and raw aggregate digest. The raw
corpus report remains under `spikes/CPU-001/work/isa-corpus-runs/run-sp_vwzfd/`.

The content-store suite passed 91 tests in nine suites. New controls cover
reopening a real archive, verify-before-materialize refusal, modified/missing/
extra/writable/link tampering, wrong outer digest, traversal, unsupported CBOR,
hard-link/set-id archive members, changed payload, unknown required feature,
trailing frames and an expanded-size bomb. Malformed archive controls recompute
their outer SHA-256, so inner parsing must reject them; no CAS object is
published. Repository Swift lint passed.

Scope: this proves CPU execution on this Mac. DXMT is built, packaged and
signature-checked, but this milestone does not claim a rendered game frame,
production signing, codec clearance or performance measurements. The runtime
tree is sealed against accidental writes; its owner can chmod it, which is
why every use must verify its digest. Mutable prefixes remain external.
