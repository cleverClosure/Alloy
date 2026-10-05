<!-- Author: Timur Isaev -->

# Alloy internal macOS client

Native SwiftUI client for the local runtime service. Internal codename only;
no Developer ID, notarization, distribution, cloud account, or game launch.
Requires macOS 14+ and the repository's Swift 6.2 toolchain. No external packages.

## Local build

```bash
apps/Alloy/build-app.sh
open apps/Alloy/.build/Alloy.app
swift test --package-path apps/Alloy --jobs 2
tools/test-all --only client-swift-test
```

The build helper creates an ad-hoc signed local app in `.build`. Normal startup
shows a disconnected library until you choose a private service endpoint with
Connect, or pass `--endpoint /absolute/path/endpoint.json`. Navigation
uses Command-1 through Command-4. UI preferences restore the selected section,
title, and appearance; they contain no endpoint credential or service payload.
Default preferences live in `~/Library/Application Support/AlloyInternal/Client`.
Use a private `--state-dir` for isolated checks.

## Explicit interface previews

```bash
open -n apps/Alloy/.build/Alloy.app --args \
  --fixture available --state-dir /private/tmp/alloy-client-preview
```

Supported fixtures: `loading`, `empty`, `available`, `unsupported`, `failed`,
`disconnected`. The app visibly labels every fixture as an **interface preview**
and offers no runtime actions. Titles/builds are synthetic. A title with no
applicable evidence is **Untested**, never certified. `--appearance light` or
`--appearance dark` overrides the saved appearance for local inspection.

## Real local service

The app uses the `AlloyRuntimeAPI` XPC client from #161; it embeds no service
engine. All requests run off the main thread. Refresh (Command-R) reads current
catalog/build identities, operation snapshots/cursors, and development sessions.
A one-second pull loop reconciles service snapshots without depending on push
notifications. Activity controls follow service pause/cancel and worker flags;
stop remains available until a session is terminal with no live process nodes.

Normal connections can browse, inspect activity, and request a storage check.
Runtime planning and native session start require both a fixture-enabled service
and `--development-fixture /private/path/client-fixture.json`. The recipe binds
its game, installation, generation, complete normalized build identity and file
fingerprint to fresh service discovery. It accepts only loopback HTTP mirrors.
The UI labels this mode; fixture processes cannot become real game launches.
See `run-service-proof.py` for the synthetic recipe schema and generator.

```bash
python3 apps/Alloy/run-service-proof.py
tools/test-all --only client-swift-test --only client-service-proof
```

The proof creates temporary owner-only service/content/client roots, registers a
private launchd job, and downloads synthetic runtime bytes from a loopback
server. It first rejects an incorrect build, then verifies the clean plan,
install/pause/resume/cancel, client restart and service restart, and whole-tree
native session stop/replay. The native session rows explicitly SKIP on hosts
below the compiler's 8 GiB minimum or non-Apple-Silicon hosts; other rows run.
It never uses Wine/FEX, real game data, or shared runtime roots.

`requests.json` stores service-scoped idempotency keys and operation cursors,
with owner-only permissions. A corrupt request journal disables actions rather
than silently replacing request identity. A repeated install or session action
reuses its original key, including after cancellation or terminal completion;
these actions do not secretly create a new attempt. A new isolated fixture is
used for a new development run. Endpoint credentials are not copied to disk.

Milestones 1–2 provide the shell and actual service flows. Reconnect edge cases,
accessibility and the integrated GUI proof follow separately. Diagnostics here
is local status only; the bundled diagnostics flow belongs to #163.

## Verification boundaries

The fast test registry compiles the app and runs deterministic non-GUI tests.
Native GUI and actual VoiceOver observations require a logged-in lab Mac; a unit
test or accessibility tree is not a substitute for that evidence. The existing
Swift CodeQL workflow selects packages under `runtime/` and `spikes/`; its green
check alone does not establish coverage of this new `apps/` package.
