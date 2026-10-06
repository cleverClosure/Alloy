<!-- Author: Timur Isaev -->

# Synthetic session artifacts

`../package-session-runtime.py --help` describes the build interface. This helper only cross-compiles fixtures and writes a private development package; it never runs Wine or modifies its base package. Supply an existing verified unsigned development package and the pinned llvm-mingw `bin` directory. Package and payload outputs must not exist.

```sh
python3 runtime/session-service/package-session-runtime.py \
  --base-package /private/tmp/alloy-177-package-b \
  --toolchain /path/to/llvm-mingw/bin \
  --output /private/tmp/session-package-one \
  --payload-output /private/tmp/session-payload-one \
  --variant one
```

The JSON result records every executable digest, the blocked DLL digest, expected save digest, provider directories, component archives and generation ID. A second build with `--variant two` creates a different provider layer and generation for a rollback proof. Guest executable bytes do not depend on that variant.

## Guest contract

The ARM64 `launcher.exe` creates x64 `game.exe`, which creates ARM64 `unknown.exe`. Launcher and game belong in the compiled known-process list; unknown deliberately does not. Each role imports `alloygraphics.dll` from `C:\alloy\providers\<role>`, expects `LANG=<role>` and `G:\cwd-<role>`, and checks FEX is present only in the x64 game. The provider records `IMPORT id=<role> LANG=<role> cwd=G:\cwd-<role> fex=<0|1>` in `DLL_PROCESS_ATTACH` and retains the policy check result. Guest entry separately checks that retained result, the current policy and the loaded provider path before writing `POLICY role=<role> import=1 entry=1 provider=1`. Each provider also prints its `RUNTIME role=<role> variant=<variant>` marker.

All three write `READY role=<role>` and remain alive for at most 120 seconds. `T:\stop` requests cooperative completion. Unknown exits first, and both parents require their child's successful exit before reporting `STOP role=<role> cooperative=1`. The supervisor owns the shorter external deadline and all forced termination. Creating `G:\ignore-stop` before launch makes the guests ignore the cooperative marker for an escalation control.

Game writes `Alloy session service save proof v1\n` (a newline byte, not a literal backslash) to `S:\saves\session-proof.bin`, calls `FlushFileBuffers`, closes the handle and then reports `SAVE role=game durable=1`.

Unknown calls `LoadLibraryA("alloyblocked.dll")`. The payload contains an actual ARM64 DLL, so a disabled policy route must produce `RESTRICTION allowed=0`. For the positive control, create `G:\allow-blocked` and change the policy route to native. The DLL must execute its attach marker `BLOCKED_IMPORT allowed=1`, and unknown must report `RESTRICTION allowed=1`. A policy with neither a disabled route nor another restriction is not accepted by the development compiler's default policy; keep a different module disabled for this control. A mismatched expected restriction causes a nonzero guest exit.

## Package lineage

Wine and CPU provider archives are copied byte for byte; the graphics component contains only these synthetic marker providers. This is not a graphics renderer or a production runtime. The helper does not extract or inspect any third-party source.

The composition recipe binds the helper, guest sources, canonical layer writer, compiler identities, variant and inherited archives. `lineage/` retains exact canonical base manifest, recipe, provenance and SBOM bytes. Inherited layer manifests retain their original build recipe digests. The replacement layer names the new composition recipe. The new canonical SBOM, provenance and runtime manifest bind the resulting composition without claiming release signing or whole-runtime reproducibility.

`python3 runtime/session-service/package-session-runtime.py --audit <package>` checks that lineage and the new digest links, including archive hashes and canonical layer tables. The general runtime-build audit currently assumes a single build recipe for every component; it does not describe composed inherited layers. The session helper's audit explicitly handles that distinction. Import with the existing `alloy-runtime-materialize import-development` interface to check all extracted runtime files independently before any guest execution.
