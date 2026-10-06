// Author: Timur Isaev

import CryptoKit
import Foundation
@testable import AlloyTrust

struct TrustFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var keys = Dictionary(uniqueKeysWithValues: TrustRole.allCases.map { role in
        (role, (0..<2).map { _ in Curve25519.Signing.PrivateKey() })
    })
    private let baseline: Data

    init() throws {
        baseline = try TrustCanonicalJSON.encode(SignedEnvelope.sign(
            Data("{\"profileId\":\"gp_test\",\"revision\":1}".utf8),
            type: "application/vnd.alloy.game-profile+json;version=1", keys: keys[.profiles]!
        ))
    }

    var directory = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-trust-\(UUID())")
    let expiry = "2030-01-01T00:00:00Z"
    let type = "application/vnd.alloy.game-profile+json;version=1"

    func root(version: Int = 1) throws -> TrustMetadata {
        var publicKeys: [String: String] = [:]
        var roles: [String: RoleRule] = [:]
        for (role, signers) in keys {
            let identifiers = signers.map { SignedEnvelope.keyID($0.publicKey.rawRepresentation) }
            for key in signers {
                publicKeys[SignedEnvelope.keyID(key.publicKey.rawRepresentation)] =
                    key.publicKey.rawRepresentation.base64EncodedString()
            }
            roles[role.rawValue] = RoleRule(keyIds: identifiers.sorted(), threshold: 2)
        }
        return TrustMetadata(role: .root, version: version, expiresAt: expiry, keys: publicKeys, roles: roles)
    }

    func signed(_ metadata: TrustMetadata, by role: TrustRole? = nil, count: Int = 2) throws -> Data {
        try TrustCanonicalJSON.encode(SignedEnvelope.sign(
            TrustCanonicalJSON.encode(metadata), type: metadata.role.payloadType,
            keys: Array(keys[role ?? metadata.role]!.prefix(count))
        ))
    }

    func profile(revision: Int = 1, count: Int = 2) throws -> Data {
        if revision == 1 && count == 2 { return baseline }
        return try TrustCanonicalJSON.encode(SignedEnvelope.sign(
            Data("{\"profileId\":\"gp_test\",\"revision\":\(revision)}".utf8), type: type,
            keys: Array(keys[.profiles]!.prefix(count))
        ))
    }

    func bundle(version: Int = 1, artifact: Data? = nil,
                edit: (inout TrustMetadata) throws -> Void = { _ in }) throws -> MetadataBundle {
        let artifact = try artifact ?? profile()
        let target = try TargetRecord(envelope: artifact, expiresAt: expiry)
        var targets = TrustMetadata(role: .targets, version: version, expiresAt: expiry,
                                    targets: [target.payloadDigest: target])
        var revocation = TrustMetadata(role: .revocation, version: version, expiresAt: expiry,
                                       revokedKeys: [], revokedProfiles: [], revokedDigests: [])
        try edit(&targets)
        try edit(&revocation)
        let targetBytes = try signed(targets)
        let revokedBytes = try signed(revocation)
        var snapshot = TrustMetadata(role: .snapshot, version: version, expiresAt: expiry, references: [
            "targets": .init(version: targets.version, bytes: targetBytes),
            "revocation": .init(version: revocation.version, bytes: revokedBytes)
        ])
        try edit(&snapshot)
        let snapshotBytes = try signed(snapshot)
        var stamp = TrustMetadata(role: .timestamp, version: version, expiresAt: expiry,
                                  references: ["snapshot": .init(version: snapshot.version, bytes: snapshotBytes)])
        try edit(&stamp)
        return try MetadataBundle(timestamp: signed(stamp), snapshot: snapshotBytes,
                                  targets: targetBytes, revocation: revokedBytes)
    }

    func bootstrap() throws -> TrustStore {
        let bytes = try signed(root())
        return try .bootstrap(directory: directory, root: bytes,
                              pinnedRootDigest: TrustCanonicalJSON.digest(bytes), now: now)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
