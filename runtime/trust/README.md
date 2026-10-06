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
