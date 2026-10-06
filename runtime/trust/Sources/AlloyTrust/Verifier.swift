// Author: Timur Isaev

import Foundation

public struct MetadataBundle: Codable, Sendable {
    public var timestamp: Data
    public var snapshot: Data
    public var targets: Data
    public var revocation: Data

    public init(timestamp: Data, snapshot: Data, targets: Data, revocation: Data) {
        self.timestamp = timestamp
        self.snapshot = snapshot
        self.targets = targets
        self.revocation = revocation
    }
}

struct AcceptedVersion: Codable, Sendable {
    let version: Int
    let digest: String
}

public struct TrustedPayload: Sendable {
    public let bytes: Data
    public let expiresAt: String
    public let scope: TrustScope
}

/// Constructed only inside a locked store transaction; never cache this value.
final class VerificationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        guard active else { throw TrustError.state("verification transaction ended") }
    }

    func end() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

public struct TrustVerifier: Sendable {
    let lease = VerificationLease()
    let root: TrustMetadata
    let metadata: [TrustRole: TrustMetadata]
    let revokedKeys: Set<String>
    let revokedProfiles: Set<ProfileRevision>
    let revokedDigests: Set<String>
    let now: Date

    public var scope: TrustScope { root.scope }

    public func verify(_ bytes: Data, type: String) throws -> TrustedPayload {
        try lease.check()
        let envelope = try SignedEnvelope.decode(bytes)
        let role = try TrustRole.artifact(type)
        let payload = try envelope.decodedPayload()
        let digest = TrustCanonicalJSON.digest(payload)
        guard let record = metadata[.targets]?.targets?[digest], record.payloadType == type,
              record.payloadDigest == digest else { throw TrustError.unauthorizedTarget }
        guard record.length == bytes.count, record.envelopeDigest == TrustCanonicalJSON.digest(bytes) else {
            throw TrustError.mixAndMatch
        }
        if revokedDigests.contains(digest) || record.profile.map({ revokedProfiles.contains($0) }) == true {
            throw TrustError.revokedTarget
        }
        let (keys, threshold) = try root.authorized(role, excluding: revokedKeys)
        let verified = try envelope.verify(type: type, keys: keys, threshold: threshold)
        if role == .profiles {
            let actual = try TargetRecord(envelope: bytes, expiresAt: record.expiresAt)
            guard actual.profile == record.profile else { throw TrustError.mixAndMatch }
        } else if record.profile != nil { throw TrustError.malformed("profile identity on non-profile target") }
        let expiries = [root.expiresAt, record.expiresAt] + metadata.values.map(\.expiresAt)
        for expiry in expiries { try requireFresh(expiry, now: now, role: "target") }
        return TrustedPayload(bytes: verified, expiresAt: expiries.min()!, scope: root.scope)
    }
}

enum ChainValidation {
    static func root(_ bytes: Data, now: Date, allowExpired: Bool = false) throws -> TrustMetadata {
        let envelope = try SignedEnvelope.decode(bytes)
        let root = try TrustMetadata.decode(envelope.decodedPayload())
        try root.validateRoot()
        let (keys, threshold) = try root.authorized(.root)
        _ = try envelope.verify(type: TrustRole.root.payloadType, keys: keys, threshold: threshold)
        if !allowExpired { try requireFresh(root.expiresAt, now: now, role: "root") }
        return root
    }

    static func verify(
        _ bundle: MetadataBundle, root: TrustMetadata, state: TrustState, now: Date
    ) throws -> (TrustVerifier, [String: AcceptedVersion]) {
        try requireFresh(root.expiresAt, now: now, role: "root")
        let blobs: [TrustRole: Data] = [.timestamp: bundle.timestamp, .snapshot: bundle.snapshot,
                                       .targets: bundle.targets, .revocation: bundle.revocation]
        var metadata: [TrustRole: TrustMetadata] = [:]
        var accepted = state.versions
        for role in [TrustRole.timestamp, .snapshot, .revocation, .targets] {
            let bytes = blobs[role]!
            let envelope = try SignedEnvelope.decode(bytes)
            let (keys, threshold) = try root.authorized(role, excluding: state.revokedKeys)
            let verified = try envelope.verify(type: role.payloadType, keys: keys, threshold: threshold)
            let item = try TrustMetadata.decode(verified)
            guard item.role == role, item.scope == root.scope else { throw TrustError.wrongRole }
            try requireFresh(item.expiresAt, now: now, role: role.rawValue)
            let digest = TrustCanonicalJSON.digest(bytes)
            if let previous = state.versions[role.rawValue] {
                guard item.version >= previous.version else { throw TrustError.rollback(role.rawValue) }
                guard item.version != previous.version || digest == previous.digest else {
                    throw TrustError.mixAndMatch
                }
            }
            accepted[role.rawValue] = AcceptedVersion(version: item.version, digest: digest)
            metadata[role] = item
        }
        guard let stamp = metadata[.timestamp]?.references, Set(stamp.keys) == ["snapshot"],
              let snapshot = metadata[.snapshot]?.references, Set(snapshot.keys) == ["targets", "revocation"] else {
            throw TrustError.mixAndMatch
        }
        try stamp["snapshot"]!.check(bundle.snapshot, version: metadata[.snapshot]!.version)
        try snapshot["targets"]!.check(bundle.targets, version: metadata[.targets]!.version)
        try snapshot["revocation"]!.check(bundle.revocation, version: metadata[.revocation]!.version)
        let revocation = metadata[.revocation]!
        let revokedKeys = state.revokedKeys.union(revocation.revokedKeys!)
        // Metadata-signing keys must be replaced via the root role. A revocation
        // signer may withdraw artifact keys, never disable the update authority.
        let metadataKeys = Set([TrustRole.root, .targets, .snapshot, .timestamp, .revocation].flatMap {
            root.roles?[$0.rawValue]?.keyIds ?? []
        })
        let newlyRevoked = Set(revocation.revokedKeys!).subtracting(state.revokedKeys)
        guard newlyRevoked.isDisjoint(with: metadataKeys) else { throw TrustError.wrongRole }
        let verifier = TrustVerifier(
            root: root, metadata: metadata, revokedKeys: revokedKeys,
            revokedProfiles: state.revokedProfiles.union(revocation.revokedProfiles!),
            revokedDigests: state.revokedDigests.union(revocation.revokedDigests!), now: now
        )
        return (verifier, accepted)
    }
}
