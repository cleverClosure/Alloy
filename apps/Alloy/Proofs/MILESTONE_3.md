<!-- Author: Timur Isaev -->

# Recovery and native accessibility — 5 October 2026

## Automated results

Repository lint and test-registry self-tests PASS. The registered client suites
PASS with ten deterministic tests and 17 real XPC controller checks, zero skips
on the Apple Silicon lab Mac. Recovery checks include a deliberately incorrect
build, a future operation cursor, actual service disconnection, last-known state
restoration by a new client process, and clean reconnection to the same request.
Duplicate, delayed, missing and inconsistent updates have separate reducer tests.

## Native observations

The locally built ad-hoc app ran against a temporary real XPC service. Native
computer-use actions and window screenshots established:

- Command-1 through Command-4 navigate; Command-F focuses library search with a
  visible focus ring. Text input and filtering work with the Mac's current input
  layout. Tab then an arrow key selects the filtered title and changes details.
- Boreal shows build 42, Untested, and disabled development actions because the
  supplied fixture is for Atlas. Atlas shows build 21 and enabled fixture actions.
- Light and dark layouts have readable labels and no clipped actions at the
  initial 1120 × 760 window. Settings exposes a native appearance picker and a
  Reduce Motion switch; the app applies a transaction that disables animations
  for either its preference or the macOS accessibility setting.
- A real runtime plan shows 1,160,000 required bytes. Install changes to Activity
  and shows Running, progress, Pause and Cancel; completion shows Succeeded.
- Activity originally combined multiple controls into one accessibility row.
  It now uses independently contained native controls. Operation details is an
  accessible disclosure exposing the service operation ID, revision and byte count.
- Starting a native development session showed three live process nodes. Its
  independently accessible Stop button produced Stopped with zero live nodes.
- The client was restarted repeatedly while the service retained its operation;
  Activity and the original completed operation returned with the saved selection.
- Background polling originally rebuilt toolbar controls and briefly disabled
  actions. It now keeps the visible toolbar stable and waits for an in-flight
  observation before handling a requested action.

Screenshots captured from the actual app, without compositing:

- [Keyboard selection, dark](screenshots/keyboard-library-dark.png)
- [Settings, light and reduced motion](screenshots/settings-light-reduced-motion.png)
- [Accessible operation details](screenshots/operation-details-light.png)
- [Actual three-process native session](screenshots/session-running-light.png)

## VoiceOver: NOT VERIFIED

This is **not an actual VoiceOver reachability pass**. The test enabled VoiceOver
through System Settings (its switch was observed on), completed the welcome
screen, checked that Control-Option was a configured modifier, and confirmed the
caption-panel setting. App-targeted VoiceOver commands did not move its cursor
or copy spoken output: the last-phrase copy control left the app's known support
summary on the clipboard, and a control character reached the search field.
Opening the VoiceOver engine's UI through the computer-use tool also timed out.

The evidence establishes a limitation of this verification attempt, not a pass
or a demonstrated defect in Alloy's VoiceOver behavior. The verified keyboard
and accessibility-tree observations above cannot substitute for spoken-output
verification. VoiceOver was restored to **off**, as confirmed in System Settings;
the utility and settings windows and temporary test service were closed.

Before #162 is marked Done, run the manual VoiceOver pass in the integrated
verification guide: navigate titles, build/status details, operation controls,
session stop, diagnostics and settings, and observe actual spoken/caption output.
The commands used were checked against Apple's [VoiceOver navigation commands](https://support.apple.com/en-kw/guide/voiceover/cpvokys04/mac)
and [last spoken phrase guide](https://support.apple.com/en-euro/guide/voiceover/vo2725/mac).
This milestone remains a draft while that required evidence is outstanding.
