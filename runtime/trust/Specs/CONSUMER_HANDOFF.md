# Consumer handoff and integration decisions

Author: Timur Isaev

The package is development/lab only and has no production trust mode. Both
consumers must pin the exact initial root envelope through a trusted separate
channel. The new root is not trusted because it accompanies a download.

## Session-service integration contract

1. Explicitly bootstrap a new, private state directory from pinned `1.root.json`.
   Subsequently construct `TrustStore(directory:pinnedRootDigest:)`; never reset
   missing/corrupt state automatically. `currentRootVersion(now:)` identifies the
   next consecutive numbered root to request, even during expired-root recovery.
2. Apply each available successor with `rotate(_:now:)`, then load a coherent
   `MetadataBundle` and call `refresh(_:now:)`. A successful rotation invalidates
   cached metadata until a bundle under the new key policy is accepted.
3. Set `LaunchCompilationInput.verificationMode = .trustChain(store: store)`.
   The compiler takes one store lock across all candidate and evidence checking,
   selection, semantic validation and launch-spec construction. There is no
   refresh between a profile check and its dependent manifest/evidence check.
4. Before reusing an exported LaunchSpecification, call
   `LaunchCompiler.verifyExport(_:input:)` against current input envelopes/time.
   Before reusing a `ProfileCandidate`, `ProfileResolver.resolve` rechecks its
   trust binding. Saved canonical bytes alone are never launch authority.
5. Retain `CompiledLaunch.verificationProvenance` in local diagnostics. It is
   `trust-chain-development`, `trust-chain-lab`, `test-only` or
   `unsigned-development`; it must never become production certification.

A future service must authenticate the caller and observation clock, coordinate
refreshes, and enforce the runtime's remaining filesystem/service controls.
Starting/stopping existing sessions in response to revocation is not implemented
here. No session-service or client source was modified.

## Content-store integration contract

A store can use `TrustStore.withVerifier(now:)` to verify typed envelopes within
one locked transaction. `TrustVerifier.verify(_:type:)` returns the exact signed
payload bytes, the effective expiry and development/lab scope. Use those bytes
for schema parsing and the existing CAS digest/size checks; signature validation
does not substitute for object-content integrity. Metadata binds the complete
signed envelope as well as its canonical payload identity. A public verifier
cannot outlive its closure. Returned payload bytes describe a completed check;
reverify before a later install, activation or selection.

The caller is responsible for downloading a coherent bounded bundle, scheduling
refresh before expiry and presenting named failures. No HTTP client, stable
release role, artifact installer or production authorization was added. Existing
content-store TUF/DSSE gaps therefore remain until this interface is wired there.

## Canonical launch output and provenance

Compiler 0.8.0 normalizes a signature-verified local launch's `verification`
field to `verified-local`; the precise trust mode is returned separately as
`CompiledLaunch.verificationProvenance`. Unsigned developer mode retains
`unsigned-development`. This prevents a signature transport change from
changing runtime policy while preserving honest provenance. It also means the
old 0.7.0 complete-launch goldens change intentionally (compiler version and
verification marker participate in the launch ID). Snapshot bytes do not change.

The positive development and lab controls compile identical payload tuples via
test-only and trust-chain envelopes and require byte-for-byte equality of both
canonical LaunchSpecification and snapshot. `productionEligible` remains false;
all existing runtime coverage gaps remain. Development roots allow only the
development ring; lab roots allow development/lab. Neither can authorize canary,
stable or quarantined selection. Vendor approval continues to require its
separate explicitly supplied vendor key and scope, as before; Alloy's metadata
role never impersonates publisher approval.

## Lifecycle decisions and schema findings

Doc 05 §21 is implemented conservatively: expired metadata/evidence cannot be
selected; revoked revisions cannot be selected even from a cache; superseded
profiles removed from targets are unauthorized. A changed observed game build
still produces the compiler's existing `profile-stale` result. Lifecycle evidence
already rejects superseded, expired, revoked, rejected and quarantined states.
No automatic fallback weakens signature, expiry or revocation requirements.

The envelope format resolves doc 06 §26 for this development package: DSSE PAE
with Alloy doc 05 field names and alloy-jcs-v1 payloads. The extra revocation
role and artifact-class key sets are Alloy-specific. Full TUF compatibility,
production custody, independently trusted wall time, protection against complete
local-admin state rollback, production safe-offline policy and operational
response to running revoked sessions are named residuals. Documentation under
`docs/` remains read-only; no schema there was silently rewritten.

The initial pre-rotation state schema is accepted with an empty rotation chain;
all counters and revocations are preserved during this additive migration.
