<!-- Author: Timur Isaev -->

# Integrated internal demonstration — 5 October 2026

## Reproducible entry points

[GUI_SMOKE.md](GUI_SMOKE.md) describes the bounded `gui-demo.py` entry point,
its private lifecycle commands, expected observations and cleanup. The GUI mirror
paces its synthetic download for manual interaction; the non-GUI proof retains
its shorter bounded transfer. Both use the real service and the app's actual
controller. No Wine/FEX guest, game payload, shared service or credential upload
is involved.

Three fast registry suites cover deterministic client state, the actual XPC
controller, and bundle build/signature/property-list validation. The service
proof pins all 17 row names. Its deliberate inverted catalog oracle reported
16 PASS / 1 FAIL / 0 SKIP and exited 1. The following clean run reported
17 PASS / 0 FAIL / 0 SKIP. Ten Swift tests and the bundle check also passed.
Repository lint and the test-registry self-test passed.

Hosted jobs with less than 8 GiB RAM or a non-Apple-Silicon host explicitly skip
only the three native-session proof rows. A green existing Swift CodeQL check
is not evidence that the new app package was included in its package selection.

## Observed integrated GUI results

Native actions against disposable real XPC fixtures established:

- The incorrect fingerprint was refused before the clean plan. An initial
  error-banner sizing modifier made the window render blank; removing it restored
  the visible, actionable message and library. The same control was rerun after
  the Mac became available and the corrected rendering was captured.
- Atlas build 21 planned and installed exactly 1,160,000 bytes. The resulting
  operation `op-03041cd04b3bcae2fea39cd155c5474ed8d159855e4cd34d98fc506ce7c89cb7`
  reached Succeeded at revision 6. Client restart followed by service restart
  restored that exact operation ID and byte count.
- Removing the private launchd service and restarting the client offline restored
  the saved catalog and completed activity. The app displayed
  `RT-SERVICE_UNAVAILABLE`, last-known-state notices and disabled mutation controls.
  Restoring the service cleared the connection error and returned live activity.
- The offline title detail initially said no activity was recorded even though
  cached activity existed. It now says **Reconnect to verify activity**, verified
  in the restarted offline app. The Activity page displays the cached operation.
- A fresh GUI run accepted Pause and exposed independently reachable Resume and
  Cancel controls once its worker stopped. In the final 17-second transfer
  fixture, Resume completed the operation. A separate fresh run reached terminal
  Cancelled through the native Cancel control.
- The first paced GUI transfer exceeded the service's unchanged 30-second download
  deadline and visibly failed with `RT-OPERATION_FAILED`; this was a fixture
  pacing error. The final helper uses about 17 seconds. The failure screenshot
  records a real failed operation, not a synthetic UI preview.

- The final session run showed three native process nodes, then Stopping with
  two nodes, and finally Stopped with zero after the native Stop action. A prior
  run was left past the service's unchanged 20-second watchdog and correctly
  ended Failed with zero nodes; the guide now makes that deadline explicit.
- All six labelled preview states rendered correctly at the initial window size:
  loading, empty, available, unsupported, failed and disconnected. The unsupported
  preview retained disabled ordinary game launch and all previews omitted runtime
  actions. Attempts to resize with the native control tool did not change the
  window, so minimum-size rendering is not claimed by this run.

Actual screenshots, captured without editing or compositing:

- [Incorrect build refused](screenshots/incorrect-build-refused.jpg)
- [Completed install and exact operation identity](screenshots/integrated-install-completed.jpg)
- [Paused operation controls](screenshots/integrated-install-paused.jpg)
- [Cancelled operation](screenshots/integrated-install-cancelled.jpg)
- [Real failed operation](screenshots/integrated-failed-operation.jpg)
- [Three live native processes](screenshots/integrated-session-running.jpg)
- [Stopped with zero native processes](screenshots/integrated-session-stopped.jpg)
- [Empty preview](screenshots/preview-empty.jpg)
- [Unsupported preview](screenshots/preview-unsupported.jpg)
- [Failure preview](screenshots/preview-failed.jpg)
- [Offline restored library](screenshots/offline-restored-library.jpg)
- [Offline restored activity](screenshots/offline-restored-activity.jpg)

Earlier native appearance, keyboard, operation-detail and three-process session
observations and screenshots remain in [milestone 3](MILESTONE_3.md).

## Changes driven by the demonstration

Idle observations now fetch operation/session state without repeatedly scanning
and fingerprinting all game installations. Connection, reconnection and explicit
Refresh still discover current catalog/build identity; every development mutation
revalidates its exact recipe through the service. An observation has a 20-second
overall request budget. The private journal is rewritten only when cached state
or a cursor changes, and writes obey its existing 4 MiB read bound.

The local fixture adapter waits for actual launchd deregistration before removing
its private root. An immediate post-bootout check had raced asynchronous removal;
the runtime package remains unchanged. A five-minute helper deadline and an
explicit stop were both observed to produce `clientStopped: true`,
`serviceRemoved: true`, and `storefrontFilesUnchanged: true` in `cleanup.json`.

## VoiceOver verification waived

Actual VoiceOver reachability is **NOT VERIFIED**. After the Mac became available,
System Settings again reported VoiceOver on, but the native app inventory reported
its application not running and app-targeted VO navigation produced no observable
cursor/caption output. This is an inconclusive test, not a demonstrated Alloy
accessibility defect. VoiceOver was restored to off and System Settings closed.
On 5 October 2026 the owner waived the manual spoken/caption-output pass as a
completion gate for #162 and instructed us to move on. The native controls and
accessibility labels remain implemented; actual VoiceOver behavior remains
unverified. This limitation no longer holds milestones 3–4 in draft.
