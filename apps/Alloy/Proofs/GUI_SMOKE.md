<!-- Author: Timur Isaev -->

# Repeatable local GUI smoke

Run on a logged-in Apple Silicon Mac with at least 8 GiB RAM, macOS 14+ and
Swift 6.2. This guide tests the internal client against the real local XPC
service and synthetic bytes/native processes. It does not launch Windows games.
Keep actual observations separate from expected results below.

## Start and control the isolated fixture

From the repository root, choose an **unused, canonical absolute** control path:

```bash
python3 apps/Alloy/gui-demo.py \
  --control-dir /private/tmp/alloy-client-demo-001 --seconds 1800
```

This builds the service, controller probe and ad-hoc signed app, then opens the
app with private temporary state, an explicit development recipe and a loopback
content mirror. It refuses an existing control directory. It never adopts a
shared endpoint or changes the committed synthetic storefront files.

In another terminal, send one command at a time and wait for its acknowledgement:

```bash
python3 apps/Alloy/gui-demo.py \
  --control-dir /private/tmp/alloy-client-demo-001 --command wrong-build
```

Available commands:

| Command | Effect |
| --- | --- |
| `wrong-build` | Relaunch with a deliberately incorrect expected file fingerprint. |
| `live` | Relaunch with the correct recipe and the existing client/service state. |
| `restart-client` | Restart the client, retaining preferences and request identity. |
| `offline` / `online` | Remove / restore only this fixture's private launchd job. |
| `restart-service` | Restart this service process with its existing durable state. |
| `fresh-service` | Dispose of this run and start a new isolated development run. |
| `preview-STATE` | Show a labelled interface preview with no service actions. |
| `stop` | End the demo and clean up owned processes and service state. |

`STATE` is `loading`, `empty`, `available`, `unsupported`, `failed`, or
`disconnected`. Previews are synthetic UI checks, not evidence of live service
behavior. `status.json` contains fixture paths and the owned client PID, never an
endpoint credential. Do not publish the endpoint file or private client logs.

The deadline applies after startup. On normal stop/deadline the helper terminates
its client, deregisters the private service with a bounded wait, removes temporary
service data, closes the loopback mirror, and writes `cleanup.json`. Verify
`clientStopped`, `serviceRemoved`, and `storefrontFilesUnchanged` are all true.
The control directory remains as local evidence. A command acknowledgement alone
is not proof that an action rendered correctly or that cleanup has finished.

## Error control, discovery and install

1. Start with `wrong-build`. Select Atlas, then **Plan test runtime**. Expect an
   actionable changed-build message with `CLIENT-BUILD-CHANGED`, no plan and no
   operation. The library, banner and navigation must remain visible and usable.
   Capture this screenshot before switching to the clean flow.
2. Use `live`. Select Atlas and Boreal: expect builds 21 and 42 respectively,
   **Untested** status, and unavailable ordinary game launch. Development actions
   apply only to Atlas, whose identity matches the supplied recipe.
3. Select Atlas and plan again. Expect 1,160,000 required runtime bytes. Install
   changes to Activity with a real operation ID, progress, Pause and Cancel.
   The fixture download takes about 17 seconds, so use Pause promptly.
4. Pause, observe Paused, then Resume and observe the same ID reach Succeeded.
   Expand Operation details; verify the final byte count is 1,160,000. Capture
   progress and completion. The download is synthetic Alloy content; storefront
   installation and repair are never performed by this client.
5. Use `restart-client` and `restart-service`. The completed operation ID must
   remain the same. Repeating the same install request must not create work.
6. Use `fresh-service` for a new cancellation trial. Plan/install and promptly
   Cancel; expect terminal Cancelled. Repeating the same request must retain its
   original terminal identity. A cancelled intent does not silently become retry.

## Disconnection and native development session

1. In a clean `fresh-service` run, complete the runtime installation. Use
   **Start development session** on Atlas. Activity should show Running and three live
   native process nodes. Capture it and use Stop promptly: the unchanged native
   fixture has a 20-second watchdog. Wait for Stopped, zero nodes. If the watchdog
   expires first, Failed with zero nodes is expected, and a fresh fixture is
   needed to test an explicit stop.
   A terminal session with live nodes remains in cleanup and must still offer Stop.
2. After observing the service state, use `offline`. Expect Disconnected, a
   last-known-state notice and an actionable service support code. Runtime
   mutation controls must be unavailable. Capture the visible banner and library.
3. While offline, use `restart-client`. The private cache should restore the
   last-known library/activity with no claim that it is current.
4. Use `online`, then Refresh if necessary. The same durable operation/session
   should return, with no duplicate request and no stale connection error.
5. Exercise all six `preview-STATE` values. Check that loading, no games,
   unsupported, failure and disconnected views have understandable next steps;
   every preview must retain its explicit synthetic-data banner.

## Keyboard, appearance and actual VoiceOver

Use the live fixture and repeat key checks at the default window size and the
minimum supported 920 × 620 content size. Verify readable labels, wrapping,
visible focus and reachable actions in light and dark appearance, with Reduce
Motion enabled. The app also respects the macOS reduced-motion setting.

- Command-1 through Command-4 select Library, Activity, Diagnostics and Settings.
  Command-F focuses library search; text filtering, Tab and arrow selection must
  select the expected title and update its details. Command-R refreshes live data.
- Follow the visible Tab order through title selection, available development
  actions, Pause/Resume/Cancel, session Stop, diagnostics Copy Status and settings.
  Disabled ordinary game launch must remain clearly unavailable.
- Enable VoiceOver using its normal macOS control. With actual speech or the
  VoiceOver caption panel observable, navigate using the configured VO modifier
  and arrow keys. Interact with containers as needed. Record the announced label,
  role, value/state and ability to activate each primary action above, including
  the operation disclosure and session Stop. Check title/build/status information
  and error support codes are reachable. Restore the original VoiceOver setting.

An accessibility tree, screenshot, keyboard-only pass or non-GUI controller test
**does not establish actual VoiceOver reachability**. If speech/captions cannot be
observed, record NOT VERIFIED. The owner waived this verification as a
completion gate for #162 on 5 October 2026; the procedure remains available for
a future accessibility pass. Apple's
[VoiceOver command reference](https://support.apple.com/en-kw/guide/voiceover/cpvokys04/mac)
and [last spoken phrase command](https://support.apple.com/en-euro/guide/voiceover/vo2725/mac)
are useful for recording what VoiceOver actually announced.

Save unedited screenshots from the running app under `Proofs/screenshots/` and
record their fixture state and outcome in the milestone report. Do not turn
expected results in this guide into claimed passes without observing them.

## Non-GUI control and CI entry points

```bash
tools/test-all --only client-swift-test --only client-service-proof \
  --only client-bundle-build
python3 apps/Alloy/run-service-proof.py --negative-control
```

The first command must report three passing suites. The negative control must
exit 1 and report `FAIL actual-catalog-builds`; the other proof rows must pass
(or explicitly skip the three native-session rows on an ineligible host).
Run the clean proof after the negative control. Both runs pin all 17 row names
and check unchanged storefront fixture hashes. CI runs these bounded non-GUI
suites; native appearance, keyboard and VoiceOver observations stay local.
