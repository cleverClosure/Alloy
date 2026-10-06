# Alloy development trust

Author: Timur Isaev

Offline Ed25519 envelope and metadata verification for development and lab
work. No production root is bundled and no key authorizes a production
release. See [the envelope specification](Specs/ENVELOPE_V1.md).

```bash
swift test --package-path runtime/trust
node runtime/trust/Tests/vector-tool.mjs
```

The Node command is an independent test-vector check; the Swift package uses
only Apple SDKs and has no third-party dependency. `tools/test-all --tier fast`
registers the Swift corpus.

The complete package gate is `bash runtime/trust/run-checks.sh` (also run by
`tools/test-all`). It includes metadata attack pairs, cross-signed rotation,
persistent revocation, the actual local signing CLI, permissions and key scans.
See [roles and persistence](Specs/ROLES_V1.md),
[local key operations](Specs/ROTATION_AND_OPERATIONS.md), and
[compiler/consumer handoff](Specs/CONSUMER_HANDOFF.md).
