<!-- Author: Timur Isaev -->

# Actual client/service flows — 5 October 2026

`tools/test-all --only client-swift-test --only client-service-proof`:
**2 suites PASS, 0 FAIL, 0 SKIP** on the Apple Silicon lab Mac.
Six unit tests and 13 actual XPC controller checks passed. Repository lint passed.

The proof exercises the same `RuntimeController` as the native app from separate
processes, using a temporary launchd service and loopback runtime mirror:

1. Incorrect build mapping refused before the clean control, without an operation.
2. Real synthetic catalog: Atlas build 21 and Boreal build 42.
3. Service revalidates and returns the runtime plan.
4. App-controller restart reuses the existing durable install request.
5. Pause reaches the actual service.
6. Resume completes the exact operation and byte count.
7. Service restart changes instance identity while retaining the operation.
8. A native fixture session exposes its three live processes.
9. Stop reaches terminal state with the entire tree gone.
10. A repeated session action does not relaunch the stopped session.
11. Runtime cancellation reaches terminal Cancelled.
12. Repeating the cancelled install does not create another operation.
13. Synthetic storefront payload hashes remain unchanged.

The first run caught an incorrect expected Boreal build in the proof (13);
inspection of the committed manifest established 42. The client was already
presenting 42 correctly. The corrected proof passed before this milestone.

This is real service/controller evidence, not GUI or VoiceOver evidence. The
remaining milestones cover native recovery presentation/accessibility and the
integrated on-screen demo. No Wine/FEX or real game execution occurred.
