# Canonical JSON and test envelopes, version 1

Author: Timur Isaev

`alloy-jcs-v1` is this package's revisable engineering default, based on
[RFC 8785](https://www.rfc-editor.org/rfc/rfc8785.html). It does not establish
a production signing standard for the control plane.

## Encoding

The input is UTF-8 JSON, at most 4 MiB and 64 nested containers. Objects sort
unescaped keys by unsigned UTF-16 code units. Arrays retain their order.
There is no whitespace, BOM, trailing newline, slash escaping, or Unicode
normalization. Strings preserve scalar values and use the RFC's JSON escapes.
Duplicate keys (including escaped spellings) are rejected before decoding.
As an additional restriction, Unicode-equivalent keys in the same object are
also rejected: Swift's keyed decoder cannot safely distinguish them.

Numbers are finite IEEE binary64 values. Swift's shortest round-trip digits
are rendered with ECMAScript's decimal thresholds, positive exponent sign,
and zero normalization. Overflow, invalid UTF-8, lone surrogates, trailing
tokens, and malformed JSON are rejected. Integers requiring more than binary64
precision must be represented as strings in contracts that permit them;
canonicalization is not an arbitrary-precision numeric codec.

Tests pin all finite RFC Appendix B vectors and compare 10,000 seeded bit
patterns with Apple's independent JavaScriptCore `JSON.stringify` engine.
A committed golden includes recursive objects, arrays, controls, supplementary
Unicode keys, and exponent boundaries. It is compared byte-for-byte ten times.
These controls are gates for future Swift toolchain changes.

## Local envelope

`TestEnvelope` is deliberately a local test format, not the conceptual
production envelope in doc 05. Its `claims` object contains `canonicalization`,
`payloadType`, base64 **canonical** `payload`, and `expiresAt`. The signature
is CryptoKit Ed25519 over the canonical claims bytes. Thus type, algorithm
version, payload, and expiry are all authenticated. The outer `keyId` selects
an explicitly supplied public key; it does not create trust. Unknown keys,
wrong types, noncanonical payloads, invalid signatures, and expiry at or before
the caller-supplied clock are rejected. Signature rotation and the update
metadata trust chain are out of scope.

`Tests/Fixtures/TEST-ONLY-key.json` contains a generated, intentionally public
keypair. Its private key is test data, never a production signing identity.
The library bundles no key and exposes no production verification mode.
Verified bytes carry `test-only` or `unsigned-development` provenance.
Unsigned envelopes require explicit `.development`; signed data cannot use
that path to avoid signature verification. Neither provenance authorizes
stable distribution or represents production certification.

## Host selection and identity

`HostCapabilities.current()` reads macOS semantic version and physical memory
through `ProcessInfo`, the exact OS build through `sysctl`, and supported
Apple GPU families through Metal. No model-name inference or subprocess is
used. A headless host with no Metal device has no GPU families, so a GPU-bound
selector fails. Entitlements and services are not inferred: those requirements
fail unless explicitly supplied by the future trusted host-capability source.

Host selectors check architecture, inclusive minimum / exclusive maximum OS
version, exact allowed build, any allowed GPU family, and exact physical GiB
class. Manifest feature and entitlement requirements are all-of conditions.
The schemas have no denied-build field; unknown fields remain rejected.

`local-unregistered:<sha256>` hashes canonical normalized host fields, including
the exact OS build. Set-like arrays are deduplicated and sorted, and numeric
versions expand to three components. It includes no free-memory or display
session state. This placeholder is **not** an `hc_` registry identifier and
must be replaced through control-plane registration before production use.

The real-host test on 4 October 2026 matched macOS 27.0.0 build 26A428,
Apple families 1–8, and 16 GiB, then rejected the paired macOS 99.0 selector.
CI also probes its actual host; absence of a Metal device is reported honestly.
