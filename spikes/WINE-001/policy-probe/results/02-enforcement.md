<!-- Author: Timur Isaev -->

# Issue 177 milestone 2: Wine enforcement before imports

The combined repository run exposed host compiler shadowing when llvm-mingw was
first on `PATH`. The native parser corpus now selects `xcrun --sdk macosx clang`
explicitly. With the same cross-toolchain PATH, its 9 Swift tests and 392
ASan/UBSan-backed negative parser executions pass. The other 42 fast suites
passed in the combined run; no runtime source or recipe changed for this fix.

The isolated Wine policy delta is embedded in the pinned runtime recipe. A fresh
`build-generation.py` run completed in 534.014 seconds with recipe SHA-256
`5865d2c35cacafc63ea25d1cd30623bd2db99d852d782e161f09538536481f39`.
It was packaged and imported by the unchanged content-store materializer:

- Generation: `rtg_76def2c40743993cff2ce99c7a1f5fd93a2b9bc246977e050a2184b340943c00`
- Manifest: `sha256:b68338d104298338bc6bb1d379fb1f004233c0d049bad86d8fdbe5fa0001d54d`
- Tree: `sha256:6fbeb915a7bb987b060d14ef6060a510ce9632a817c123799547d4bae9fd6610`
- Policy patch: `1402e2ceee7a4565ad449281d3a4102f9af202d1807fad034329b833dcb01b18`

The [machine-readable proof](02-runtime-proof.json) records ten executions:

| Control | Required observation |
| --- | --- |
| Stock native | Stock DLL, inherited LANG and working directory, no FEX |
| All lowered fields | Configured DLL path, LANG and working directory in DLL initialization and guest entry, no FEX |
| Fields absent | Stock DLL, inherited LANG and directory preserved |
| Disabled import | Normal import resolution fails; guest DLL body and entry never run |
| CPU absent | Registry-default xtajit64 maps and refuses x64 execution |
| CPU FEX | x64 DLL initialization and guest entry run; FEX is present and the exact verified generation DLL maps |
| Native-only CPU on x64 | `policy-cpu-incompatible`, before guest imports |
| Corrupted file | Expected complete-file digest mismatch, before guest imports |
| Wrong expected digest | `policy-expected-digest`, before guest imports |
| Lost descriptor | `policy-descriptor-missing`, before guest imports |

The readonly materialized generation reverified unchanged afterward. The proof
uses a private prefix, inherited readonly/unlinked snapshot descriptor, finite
process/log limits, and cleanup confined to its own process group and prefix.
It neither registers FEX in a shared prefix nor assumes a system32 copy was used.
The exact successfully mapped builtin path is mandatory for the positive case.

The native header in the Wine patch is byte-compared against the ASan/UBSan-tested
host parser. Its existing 196 malformed cases still produce 392 named process
failures. All 12 Wine inventory tests, 32 combined-fork tests and seven pinned-input
tests passed. The combined real fork gate passed with preserved shared source
identities, index and dirty bytes. Refreshed upstream replay receipts retain the
existing first-stop conflicts in Wine/FEX and a clean DXMT patch apply result;
these are compatibility findings, not a claim that the upstream stacks build.

The explicit Wine maintenance ceiling is 28 retained shared commits plus two
supplements, total 30. The additional policy delta avoids rewriting the live
fork and its unrelated uncommitted work; see the rationale in the wire contract.

An initial private prototype exposed an include-order compile error, corrected
before the fresh build above. The first guest harness run exposed interleaved
Wine diagnostic text inside a path observation; queries now finish before
printing and matching requires complete observation lines. A second run had the
stock translator diagnostic channel disabled; enabling that channel made the
known refusal observable. The final unchanged runtime passed all ten cases.
These harness corrections did not relax a runtime assertion or change Wine.
