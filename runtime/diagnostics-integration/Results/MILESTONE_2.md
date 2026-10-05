<!-- Author: Timur Isaev -->

# Milestone 2 — observed local failure capture

5 October 2026, Apple Silicon macOS, isolated temporary service and stores.

The clean capture proof passes 8/8 with no skips: successful inventory, failed
loopback download, clean native exit, exact-owned SIGABRT exit 6, sampled native
hang followed by watchdog exit 43, 100ms capture budget, service restart during
capture and reconnect to the same interrupted session. Terminal sessions have
zero live nodes. The negative oracle passes 7/8 and exits 1 only at the deliberately
incorrect operation-failure expectation. Five adapter tests and 20 focused
reused-model/redaction/owned-sampler tests also pass.

Two failures found during development were corrected before the passing proof:
random RPC UUID digits could trigger the card-number scanner, and a service
restart between the before/after instance reads escaped as an error instead of
an incomplete interruption. Canonical UUID request metadata now has a narrow
regression-tested exception; raw fields retain all scanner rules. Fixture
teardown now waits for owned nodes to stop before deleting their stores.

The native abort evidence is a service-recorded native exit, not a captured
symbolicated crash stack. The hang sample observes the service's actual native
fixture; neither represents Wine/provider behavior. Sampling retains only a
typed site/ownership artifact. Complete capture does not invent missing session
event history. Capture-budget exhaustion leaves service work owned by the
service; the proof explicitly stops it and verifies cleanup.
