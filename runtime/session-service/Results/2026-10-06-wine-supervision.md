<!-- Author: Timur Isaev -->

# Complete synthetic Wine tree supervision

Milestone 3 of #181, 6 October 2026. The eight-case separate-client proof passes
under the exclusive lab lock against the pinned #177 development package.
The [recorded result](2026-10-06-wine-supervision.json) retains exact runtime
identities, process creations, correlated events and measured durations.

| Control | Terminal outcome | Cleanup seconds | Launch request seconds |
| --- | --- | ---: | ---: |
| pending-stop | STOPPED / OK | 3.121 | 0.033 |
| pending-service-crash | INTERRUPTED / SESSION_INTERRUPTED | 0.138 | 0.029 |
| stop | STOPPED / OK | 6.117 | 0.030 |
| force-kill | STOPPED / OK | 10.737 | 0.032 |
| watchdog | FAILED / SESSION_WATCHDOG | 22.933 | 0.034 |
| lease-revoked | FAILED / GENERATION_LEASE_MISSING | 7.959 | 0.031 |
| agent-crash | INTERRUPTED / SESSION_INTERRUPTED | 9.208 | 0.030 |
| service-crash | STOPPED / OK | 6.021 | 0.029 |

The watchdog duration includes the remaining guest watchdog interval. Each live
tree retains the x64 launcher and game plus two unknown ARM64 children, including
one that exits immediately. Launcher exit does not complete its surviving tree.
Long-lived guest observations require runtime/prefix-bound kernel birth identities;
short-lived children remain in the complete server trace even if they exit before
a native observation. The forced-server control blocks its normal stop signal and
requires the actual `kill-escalated` event. Every case independently inspects the
recorded agent, server, root and all guest Unix/native PIDs after termination.
No recorded process survived. Pending controls permit no Wine or server output.

Launch admission is now asynchronous: the helper remains on its stdin gate until
its lease and complete request are durable. This fixes a real ten-second client
timeout caused by synchronous content-store verification on the sixth launch.
All eight measured launch calls complete below the five-second proof limit.
A failed cleanup retains the fixture and payload instead of deleting ownership
evidence. Raw diagnostics are private and credential-scanned before copying.

The trace parser has positive full-inventory replay and missing/truncated evidence
controls. Native membership tests distinguish the exact helper from unrelated
executables/prefixes and handle Wine's argument padding without accepting argv
text as environment evidence. A live run exposed the need to settle a short-lived
child's exit trace before asserting native membership; the proof now checks the
retained exited creation separately from deliberately long-lived children. Newly
observed native identities are persisted even when no new trace bytes arrive.

Fourteen unit tests, five focused service regression suites, repository lint and
registry self-tests pass. The implementation and protocol are documented in
[WINE_SUPERVISION_V1.md](../Specs/WINE_SUPERVISION_V1.md). Aggregate agent/server
leases pin the runtime through cleanup; health checks compare their exact durable
records without rebuilding the large content catalog on every monitor tick.

This proves synthetic process supervision and cleanup, not production game or
storefront support. The title drive plan is a namespace, not host authorization.
Provider enforcement, save persistence and runtime rollback are the final milestone.
