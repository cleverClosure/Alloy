<!-- Author: Timur Isaev -->

# ContentStore main-21136e4 compatibility fixture

This directory was generated with the unmodified `AlloyContentStore` sources at
commit `21136e49b9909349800e2b355076a3c8023a617e`. The committed sibling driver
records the complete input procedure. From the repository root, it can be run
against that exact base with:

```sh
fixture_tmp="$(mktemp -d "${TMPDIR:-/tmp}/alloy-main-fixture.XXXXXX")"
fixture_base_checkout="$fixture_tmp/base"
fixture_driver="$PWD/runtime/content-store/Tests/Fixtures/main-21136e4-fixture.swift"
git worktree add "$fixture_base_checkout" 21136e49b9909349800e2b355076a3c8023a617e
swiftc -parse-as-library -module-cache-path "$fixture_tmp/module-cache" \
  "$fixture_base_checkout"/runtime/content-store/Sources/AlloyContentStore/*.swift \
  "$fixture_driver" -o "$fixture_tmp/generator"
"$fixture_tmp/generator" "$fixture_tmp/store"
```

Activation journal UUIDs are intentionally generated at runtime, so a rerun
reproduces the persisted schema, payloads, references, and modes rather than
the two historical journal filenames.

The temporary driver activated these UTF-8 inputs, in order, for game
`fixture-game`:

| Generation | Layer | Version | Role | Payload |
| --- | --- | --- | --- | --- |
| `generation-a` | `runtime` | `1` | `host-runtime` | `shared-runtime-payload-v1` |
| `generation-a` | `profile` | `a` | `profile` | `generation-a-profile` |
| `generation-b` | `runtime` | `1` | `host-runtime` | `shared-runtime-payload-v1` |
| `generation-b` | `profile` | `b` | `profile` | `generation-b-profile` |

Every layer used media type `application/vnd.alloy.compatibility-fixture`,
source revision `main-21136e4`, and license `LicenseRef-Fixture`. Between the
activations, the driver wrote `save-sentinel-main-21136e4` to
`compatibility.sav`. The resulting active reference is `generation-b`, the
rollback reference is `generation-a`, and the shared object digest is
`sha256:301ce5b1642d441cae33b6161b6e7ee1b1debd70a4b2ee9ff541ebb375bdefbd`.

The generated store used hard links between CAS and generation-layer paths.
Git does not preserve read-only modes such as `0444`/`0555` or promise inode
identity after checkout. The sibling `main-21136e4-modes.json` records every
non-default generated mode; the compatibility test restores and checks those
modes before opening the store. Link count is not part of the persisted
compatibility contract.
