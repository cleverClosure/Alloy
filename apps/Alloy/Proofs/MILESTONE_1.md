<!-- Author: Timur Isaev -->

# Shell verification — 5 October 2026

Local Apple Silicon lab Mac, native SwiftUI app, synthetic `available` preview.

- `apps/Alloy/build-app.sh`: PASS; local ad-hoc signed bundle launched.
- `tools/test-all --only client-swift-test`: PASS, four state/storage tests.
- `tools/test-all --selftest`: PASS with normal process visibility.
- `tools/lint.sh`: PASS.
- Native app screenshot inspected: sidebar, two synthetic titles, build 21,
  explicit preview banner, Untested status, disabled game launch, readable
  technical disclosure; no clipping at the initial 1120 × 760 window.
- Native accessibility observation: Library/Activity/Diagnostics/Settings rows,
  searchable list, title/build text and disabled launch control exposed.
- Command-4 changed the selected sidebar row and window to Settings; the native
  appearance picker and Reduce Motion switch were exposed.

This is shell evidence only. No real service operation or actual VoiceOver
session is claimed by this milestone. Full GUI screenshots, reconnect/error
controls and VoiceOver observations belong to the integrated client proof.
