# Alloy development trust envelope v1

Author: Timur Isaev

Decision for #178 milestone 1: use Ed25519 through Apple CryptoKit, the
[DSSE v1.0.2 signing protocol](https://github.com/secure-systems-lab/dsse/blob/master/protocol.md),
and Alloy doc 05 §5's `payloadType`, `payload`, `signatures[{keyId,signature}]`.
This is an Alloy encoding of DSSE's pre-authentication bytes, not the standard
DSSE JSON envelope (`keyid`/`sig`). It deliberately rejects unknown fields and
accepts only canonical padded standard base64. No interoperability claim is
made for generic DSSE decoders or complete TUF clients.

Payload types identify the schema version; the exact UTF-8 type and payload
bytes are length-framed by DSSE PAE and signed. Ed25519 keys are 32-byte public
keys; IDs are `sha256:` plus lowercase SHA-256 of those raw bytes. IDs only
index caller-authorized keys; a signature never introduces trust. Thresholds
count distinct validated public keys, so duplicate signatures cannot amplify
one key. There are at most 32 keys/signatures and 1 MiB decoded payload.

Canonicalization is the existing `alloy-jcs-v1` profile: UTF-16 key ordering,
finite binary64 numbers with ECMAScript rendering, unchanged Unicode values,
no whitespace, and rejection of duplicate or Unicode-equivalent keys. Input
is limited to 4 MiB and 64 nesting levels. This matches the profile compiler's
published format; it is based on [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785).
The parser is initially independent of the compiler to avoid a dependency
cycle. Integer metadata counters will be bounded to the exact binary64 range.

Outer envelope JSON is normalized before strict decoding; payload JSON must
already be canonical. Verification returns the same decoded bytes it checked.
Expiry and target authorization are role-metadata responsibilities (milestone
2), not unauthenticated outer fields. An envelope alone is not permission to
launch, install, select a profile, or advertise a stable release.

`Tests/Vectors/envelope.json` contains only a public key and known answers for
canonicalization, PAE and signature. Node's independent serializer and
OpenSSL-backed Ed25519 generated it; CryptoKit verifies it. Regeneration uses
a fresh ephemeral key in memory and saves no private bytes. Swift controls
cover payload/type tampering, insufficient thresholds, duplicate signatures,
key aliases, malformed JSON, unknown fields and noncanonical payloads.
