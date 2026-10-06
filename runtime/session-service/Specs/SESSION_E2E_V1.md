<!-- Author: Timur Isaev -->

# Complete synthetic Windows session handoff

Milestone 4 of #181 connects the [Wine launch protocol](WINE_LAUNCH_V1.md),
[session environment](SESSION_ENVIRONMENT_V1.md) and
[process supervision](WINE_SUPERVISION_V1.md) through a separate authenticated
XPC client. `run-session-e2e-proof.py` contains the executable acceptance checks;
the [dated execution record](../Results/2026-10-06-session-e2e.md) states which
checks have actually run. This document describes the contract and does not
substitute for runtime evidence.

## Development scope

The endpoint opts in with a private `syntheticPayloadRoot` and `fixtureMode`.
The complete development source is `alloy-synthetic-session-v1`, uses
`syntheticOnly: true` and selects `title-volumes-namespace-v1`. Service-supplied
actual host capabilities, timestamp and volume identities cannot be replaced by
client source. Supported specifications are runtime-ready but never production
eligible. Ordinary profiles retain their unresolved controls and refusal.

C is a disposable per-session Windows prefix, G is the synthetic payload, S
exposes title saves/settings and T is session scratch. The runtime generation
remains immutable. This namespace removes implicit host-root mapping but is not
an adversarial host filesystem authorization boundary. The fixture's allow/off/
conservative modes make no unsupported network, debugger or synchronization
enforcement claim. No root helper, storefront account, licensed game, production
certificate or shared-runtime modification is part of this proof.

## Asynchronous admission

`launch.game` promptly returns a STARTING snapshot after durably recording
admission and the exact native birth identity of a helper blocked on its startup
gate. Full content validation and generation-lease acquisition run outside the
XPC request path. The gate remains closed until the verified lease matches that
identity and the complete request is durable. The released agent still performs
its runtime, payload and policy checks before guest execution. A prompt reply
therefore does not mean validation succeeded or that a guest has started.

Pending STARTING and STOPPING snapshots intentionally contain no events. They
consume no event sequence numbers; clients must accept an empty pending history.
An admission failure or cancellation produces its terminal correlated result,
while an admitted agent owns the subsequent bounded event stream. Poll the
durable session ID for completion and preserve the distinction between pending
admission, running guests and completed cleanup.

## Independent policy observations

The payload is a nested tree, not three separately launched executables:

| Guest | Architecture and CPU policy | Policy selection | Provider and working directory |
| --- | --- | --- | --- |
| `G:\launcher.exe` | ARM64, `native-arm64ec` | Known image SHA, `launcher` | `C:\alloy\providers\launcher`, `G:\cwd-launcher` |
| `G:\game.exe` | x64, `fex-arm64ec` | Known image SHA, `game` | `C:\alloy\providers\game`, `G:\cwd-game` |
| `G:\unknown.exe` | ARM64, `native-arm64ec` | Unlisted image, restricted `unknown` default | `C:\alloy\providers\unknown`, `G:\cwd-unknown` |

Launcher creates game; game creates unknown. Each policy sets `LANG` to its role
and routes `alloygraphics` to its own native DLL. In `DLL_PROCESS_ATTACH`, that
DLL records the language, current directory and FEX presence and retains whether
they match its expected policy. Guest entry separately checks the retained
import-time result, current values and loaded DLL path. The harness requires one
`IMPORT` marker before one `GUEST` marker for each role, followed by that role's
successful `POLICY` and `READY` markers. The x64 game's FEX mapping must name the
selected verified runtime's exact builtin image.

These providers are synthetic marker DLLs, not renderer implementations. A
process record's `policyID` alone is not an enforcement oracle. The proof compares
the service inventory and native birth identities with observations from inside
the actual guest and its importing DLL.

Unknown tries to load a real ARM64 `alloyblocked.dll` in G:. The restricted run
must report `RESTRICTION allowed=0` without its DLL-attach marker. A positive
control changes that route to native, keeps another module disabled, and creates
the fixture's `allow-blocked` expectation marker. It must report both
`BLOCKED_IMPORT allowed=1` and `RESTRICTION allowed=1`. An absent DLL cannot supply
the denial proof. [Guest source and controls](../guest-session/README.md) define
the full marker contract and the separate `ignore-stop` escalation control.

## Stop, saves, faults and rollback

Every positive case waits for all three guests, their exact parent chain, known/
unknown classifications and a completed health check. The game writes
`Alloy session service save proof v1` plus one newline to
`S:\saves\session-proof.bin`, flushes the file and closes it before reporting a
durable save. Expected SHA-256 is
`dbd50f6c90a4ed5ee71cec12a12f454393f6896e1c4c6a674c0beec58c1fa1d7`.

Normal `session.stop` must reach each guest's cooperative T: marker and finish
STOPPED/OK. Parent guests wait for successful child exits. The proof allows at
most 25 seconds for terminal state and independent native-death checks. A service
crash must replace the service instance and end either STOPPED/OK through the
surviving agent or INTERRUPTED/SESSION_INTERRUPTED through reconciliation; it
must not leave the tree running. Process rows remain as exited history. A missing
cleanup acknowledgement fails and preserves the disposable fixture for recovery.

The registered harness contains nine cases:

| Case | Required result |
| --- | --- |
| `valid-restricted` | Three distinct import-time policies, unknown DLL denied, save persisted, clean stop |
| `restriction-positive` | The otherwise blocked DLL actually loads under the explicit control policy |
| `service-crash` | New service instance, terminal reconciliation and no surviving session processes |
| `corrupt-policy` | FAILED/POLICY_INTEGRITY before guest import or entry |
| `missing-lease` | FAILED/GENERATION_LEASE_MISSING before guest import or entry |
| `tampered-runtime` | FAILED/RUNTIME_INTEGRITY before guest import or entry |
| `valid-after-faults` | Fresh successful session after all refusals |
| `alternate-runtime` | Distinct generation B and provider variant, with unchanged S: bytes |
| `restored-runtime` | Exact original generation A restored, its original provider variant and unchanged S: bytes |

Snapshot/lease faults are private endpoint fixture configuration, not client
request features. The tamper control flips one byte in this proof's independently
materialized provider DLL; it never alters source packages or CAS objects. It
restores the exact bytes and mode, then requires normal runtime verification.

The package pair reuses immutable Wine/CPU archives byte for byte and replaces
only the graphics component with role-specific marker providers. Variant A and B
must have different generation and tree digests. Their guest payloads are the
same. The proof activates A, then B after all prior guests stop, then A again;
the final materializer result must equal the original result. Save bytes are
checked after each stop/crash/refusal and immediately after both activations,
before another game can rewrite them. This is runtime activation rollback, not a
save restore or save migration.

## Reproduction and registration

Build two private packages without executing guests. Both output directories for
each build must be absent. `--variant one` and `--variant two` produce the two
provider markers. The helper prints guest/component hashes and generation IDs:

```sh
python3 runtime/session-service/package-session-runtime.py \
  --base-package /path/to/verified-development-package \
  --toolchain /path/to/llvm-mingw/bin \
  --output /private/tmp/session-runtime-a \
  --payload-output /private/tmp/session-payload-a --variant one
python3 runtime/session-service/package-session-runtime.py \
  --base-package /path/to/verified-development-package \
  --toolchain /path/to/llvm-mingw/bin \
  --output /private/tmp/session-runtime-b \
  --payload-output /private/tmp/session-payload-b --variant two
```

The helper's `--audit <package>` checks canonical metadata, archive/table hashes,
SBOM links and explicit inherited recipe lineage. `lineage/` retains the original
package metadata. New provenance is unsigned development evidence and makes no
release-signing or whole-runtime reproducibility claim.

`runtime-service-session-e2e` is registered in the full tier. It requires an actual
Apple Silicon host accepted by the compiler, Swift, Python, launchctl, both
packages, the payload and the existing materializer executable. The materializer
environment variable is its containing directory:

```sh
ALLOY_SESSION_PROOF_PACKAGE_A=/private/tmp/session-runtime-a \
ALLOY_SESSION_PROOF_PACKAGE_B=/private/tmp/session-runtime-b \
ALLOY_SESSION_PROOF_PAYLOAD=/private/tmp/session-payload-a \
ALLOY_SESSION_MATERIALIZER=/path/to/materializer-bin \
  python3 tools/test-all --only runtime-service-session-e2e \
    --json /private/tmp/session-e2e-suite.json
```

The registration holds the exclusive lab lock and bounds the command at 1,100
seconds, within the suite's 1,200-second timeout. It reports missing prerequisites
as SKIP; a skip is not runtime coverage. The proof refuses an already-busy Wine
host, uses an ephemeral current-user launchd job, copies the guest payload and
imports both packages into its own private store. It does not select shared
`build-2`, install a persistent agent or grant elevated privileges.

For a private diagnostic capture, run the same harness under the exclusive lock
with `--diagnostics` naming an absent or empty directory:

```sh
python3 tools/lab/lab.py lock-run --mode exclusive --timeout 1100 -- \
  python3 runtime/session-service/run-session-e2e-proof.py \
    --package /private/tmp/session-runtime-a \
    --alternate-package /private/tmp/session-runtime-b \
    --payload /private/tmp/session-payload-a \
    --materializer /path/to/materializer-bin/alloy-runtime-materialize \
    --diagnostics /private/tmp/session-e2e-private-diagnostics
```

## Correlation and evidence handling

Each session event must carry the same session ID, launch specification ID,
generation ID and original launch request correlation UUID. Retained sequence
numbers must remain consecutive within the bounded recent-event window. The
harness checks this tuple against the durable private request and public
snapshot, including refusals and restart outcomes.

The optional private local capture includes service-produced `pending.json`,
`request.json`, `bootstrap.json`, `state.json`, `ownership.json`, `wine.log` and
`server.log`, when present, with private directory and file permissions. It
rejects the endpoint credential in those bytes and never copies the endpoint
file. Admission and request records retain full private launch inputs so local
recovery can be investigated; host paths and other private session data also
remain in these raw artifacts. Credential scanning is not general redaction.

Keep that capture private. It is distinct from a publishable diagnostics bundle,
which must pass #163's review, redaction and export contract. Do not attach the
raw capture, admission records or launch requests to public reports merely
because their credential scan passed.

The result JSON includes each observed session, provider/FEX observations,
cleanup duration, dead-process count, runtime identities and save digest.
Publication requires the actual successful run and appropriate local/hosted
regression evidence. Do not infer success from package construction, a printed
plan, a compilation check, or another milestone's proof.
