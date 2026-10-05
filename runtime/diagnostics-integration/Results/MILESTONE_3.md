<!-- Author: Timur Isaev -->

# Milestone 3 — private local bundle lifecycle

5 October 2026, isolated local development service.

Eight Swift tests pass, including create/inspect/export/delete, unchanged
unrelated files, symlink and traversal refusal, permissive-file refusal, a
1µs work budget and missing/oversized capture controls. The live-service
lifecycle proof passes 7/7. Its negative export oracle fails only
`export-matches-preview` (6 PASS, 1 FAIL, exit 1), before the clean run.

A successful inventory operation is captured through XPC and sealed, then the
service is stopped. Summary, preview, export and deletion succeed offline.
Actual exported file digests exactly match preview, all retained directories
and files exclude group/other permissions, existing files/links are refused,
and deletion leaves the separately exported bundle, unrelated file and every
service JSON record unchanged.

This is local plaintext storage with private filesystem permissions. There is
no network export, production retention policy or protection against malicious
concurrent same-user filesystem changes. The final milestone supplies the
independent failure-bundle oracle and test-all registration.
