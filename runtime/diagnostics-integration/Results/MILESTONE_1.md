<!-- Author: Timur Isaev -->

# Milestone 1 — identity and event adapter

5 October 2026, isolated worktree on Apple Silicon macOS, Xcode Swift 6.

- Four Swift tests pass: exact identity/absence, duplicate/delayed delivery,
  omitted/reordered audit records, and unknown wire-field rejection.
- The real-service wrong-ID oracle exits 1: 5 PASS, 1 FAIL, precisely
  `actual-service-operation-identity`. It ran before the clean proof.
- Clean adapter proof: 6 PASS, 0 FAIL. It starts a private launchd service,
  executes a real inventory operation, verifies its exact audit history,
  restarts the service, preserves the operation identity, and refuses to call
  a disconnected observation clean. Temporary registration and stores removed.

This milestone does not claim native crash/hang capture or bundle lifecycle.
Its session mapper validates available preview/lease identities; real session
capture and independent expected identities are the next milestone's proof.
