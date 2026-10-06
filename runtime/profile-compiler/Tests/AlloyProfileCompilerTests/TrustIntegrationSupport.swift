// Author: Timur Isaev

import AlloyTrust
import CryptoKit
import Foundation
import Testing
@testable import AlloyProfileCompiler

struct IntegrationTrust {
    let scope: TrustScope

    init(scope: TrustScope = .lab) { self.scope = scope }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-compiler-trust-\(UUID())")
    let keys = Dictionary(uniqueKeysWithValues: TrustRole.allCases.map { ($0, [Curve25519.Signing.PrivateKey()]) })
    let expiry = "2030-01-01T00:00:00Z"

    func sign(_ payload: Data, type: String, role: TrustRole) throws -> Data {
        try TrustCanonicalJSON.encode(SignedEnvelope.sign(payload, type: type, keys: keys[role]!))
    }

    func signed(_ metadata: TrustMetadata) throws -> Data {
        try sign(TrustCanonicalJSON.encode(metadata), type: metadata.role.payloadType, role: metadata.role)
    }

    func bootstrap(now: Date) throws -> TrustStore {
        var publicKeys: [String: String] = [:]
        var roles: [String: RoleRule] = [:]
        for (role, signers) in keys {
            let identifier = SignedEnvelope.keyID(signers[0].publicKey.rawRepresentation)
            publicKeys[identifier] = signers[0].publicKey.rawRepresentation.base64EncodedString()
            roles[role.rawValue] = RoleRule(keyIds: [identifier], threshold: 1)
        }
        let root = try signed(TrustMetadata(role: .root, version: 1, expiresAt: expiry,
                                             scope: scope, keys: publicKeys, roles: roles))
        return try TrustStore.bootstrap(directory: directory, root: root,
                                        pinnedRootDigest: TrustCanonicalJSON.digest(root), now: now)
    }

    func bundle(_ input: LaunchCompilationInput, version: Int = 1,
                edit: (inout TrustMetadata) -> Void = { _ in }) throws -> MetadataBundle {
        let envelopes = input.candidates.flatMap { [$0.profile, $0.manifest, $0.metadata] } + [input.evidenceEnvelope]
        let records = try envelopes.map { try TargetRecord(envelope: $0, expiresAt: expiry) }
        var targets = TrustMetadata(role: .targets, version: version, expiresAt: expiry, scope: scope,
                                    targets: Dictionary(uniqueKeysWithValues: records.map { ($0.payloadDigest, $0) }))
        var revocation = TrustMetadata(role: .revocation, version: version, expiresAt: expiry, scope: scope,
                                       revokedKeys: [], revokedProfiles: [], revokedDigests: [])
        edit(&targets)
        edit(&revocation)
        let targetBytes = try signed(targets)
        let revokedBytes = try signed(revocation)
        let snapshot = try signed(TrustMetadata(role: .snapshot, version: version, expiresAt: expiry, scope: scope,
                                                references: ["targets": .init(version: version, bytes: targetBytes),
                                                             "revocation": .init(version: version,
                                                                                 bytes: revokedBytes)]))
        var timestamp = TrustMetadata(role: .timestamp, version: version, expiresAt: expiry, scope: scope,
                                      references: ["snapshot": .init(version: version, bytes: snapshot)])
        edit(&timestamp)
        return try MetadataBundle(timestamp: signed(timestamp), snapshot: snapshot,
                                  targets: targetBytes, revocation: revokedBytes)
    }

    func convert(_ input: LaunchCompilationInput, store: TrustStore) throws -> LaunchCompilationInput {
        func envelope(_ bytes: Data, type: PayloadType) throws -> Data {
            try sign(envelopePayload(bytes), type: type.rawValue, role: TrustRole.artifact(type.rawValue))
        }
        var converted = input
        converted.candidates = try input.candidates.map {
            try CandidateEnvelopes(profile: envelope($0.profile, type: .gameProfile),
                                   manifest: envelope($0.manifest, type: .runtimeManifest),
                                   metadata: envelope($0.metadata, type: .releaseMetadata))
        }
        converted.evidenceEnvelope = try envelope(input.evidenceEnvelope, type: .launchEvidence)
        converted.verificationMode = .trustChain(store: store)
        return converted
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

func labLaunchFixture(scope: TrustScope = .lab) throws -> LaunchCompilationInput {
    var input = try launchFixture()
    var manifest = try #require(JSONSerialization.jsonObject(with: envelopePayload(input.candidates[0].manifest))
        as? [String: Any])
    manifest = try replacing(manifest, path: ["activation", "releaseRing"], value: scope.rawValue)
    input.candidates[0].manifest = try signedFixture(JSONSerialization.data(withJSONObject: manifest),
                                                   type: .runtimeManifest)
    var metadata = try JSONDecoder().decode(CandidateMetadata.self, from: envelopePayload(input.candidates[0].metadata))
    metadata.releaseRing = scope == .lab ? .lab : .development
    input.candidates[0].metadata = try signedFixture(CanonicalJSON.encode(metadata), type: .releaseMetadata)
    let metadataDigest = try CanonicalJSON.digest(envelopePayload(input.candidates[0].metadata))
    let manifestDigest = try CanonicalJSON.digest(envelopePayload(input.candidates[0].manifest))
    try editEvidence(&input) {
        $0.lifecycle = scope == .lab ? "lab" : "review"
        $0.metadataDigest = metadataDigest
        $0.manifestDigest = manifestDigest
    }
    input.selection.client.allowedRings.insert(scope == .lab ? .lab : .development)
    return input
}
