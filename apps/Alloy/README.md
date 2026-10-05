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
shows a disconnected library until service integration is configured. Navigation
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

The shell is milestone 1 of #162. Actual service actions, recovery, and integrated
GUI/accessibility proof follow in separate milestones. Diagnostics here is local
status only; the bundled diagnostics flow belongs to #163.

## Verification boundaries

The fast test registry compiles the app and runs deterministic non-GUI tests.
Native GUI and actual VoiceOver observations require a logged-in lab Mac; a unit
test or accessibility tree is not a substitute for that evidence. The existing
Swift CodeQL workflow selects packages under `runtime/` and `spikes/`; its green
check alone does not establish coverage of this new `apps/` package.
