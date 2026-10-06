// Author: Timur Isaev

import Foundation

public enum TrustRole: String, Codable, CaseIterable, Sendable {
    case root, targets, snapshot, timestamp, revocation
    case profiles, manifests, releases, evidence

    public var payloadType: String { "application/vnd.alloy.trust-\(rawValue)+json;version=1" }

    public static func artifact(_ type: String) throws -> Self {
        switch type {
        case "application/vnd.alloy.game-profile+json;version=1": .profiles
        case "application/vnd.alloy.runtime-manifest+json;version=1": .manifests
        case "application/vnd.alloy.local-release-metadata+json;version=1": .releases
        case "application/vnd.alloy.local-launch-evidence+json;version=1": .evidence
        default: throw TrustError.wrongRole
        }
    }
}

public enum TrustScope: String, Codable, Sendable { case development, lab }

public struct RoleRule: Codable, Sendable {
    public var keyIds: [String]
    public var threshold: Int

    public init(keyIds: [String], threshold: Int) {
        self.keyIds = keyIds
        self.threshold = threshold
    }
}

public struct MetadataReference: Codable, Sendable {
    public var version: Int
    public var digest: String
    public var length: Int

    public init(version: Int, bytes: Data) {
        self.version = version
        digest = TrustCanonicalJSON.digest(bytes)
        length = bytes.count
    }

    func check(_ bytes: Data, version: Int) throws {
        guard self.version == version, length == bytes.count,
              digest == TrustCanonicalJSON.digest(bytes) else { throw TrustError.mixAndMatch }
    }
}

public struct ProfileRevision: Codable, Hashable, Sendable {
    public let profileId: String
    public let revision: Int

    public init(profileId: String, revision: Int) {
        self.profileId = profileId
        self.revision = revision
    }
}

public struct TargetRecord: Codable, Sendable {
    public var payloadType: String
    public var payloadDigest: String
    public var envelopeDigest: String
    public var length: Int
    public var expiresAt: String
    public var profile: ProfileRevision?

    public init(envelope: Data, expiresAt: String) throws {
        let decoded = try SignedEnvelope.decode(envelope)
        let payload = try decoded.decodedPayload()
        payloadType = decoded.payloadType
        payloadDigest = TrustCanonicalJSON.digest(payload)
        envelopeDigest = TrustCanonicalJSON.digest(envelope)
        length = envelope.count
        self.expiresAt = expiresAt
        if try TrustRole.artifact(payloadType) == .profiles {
            struct Identity: Decodable { let profileId: String; let revision: Int }
            let identity = try JSONDecoder().decode(Identity.self, from: payload)
            profile = ProfileRevision(profileId: identity.profileId, revision: identity.revision)
        }
    }
}

/// A small closed metadata schema; each role permits only its own fields.
public struct TrustMetadata: Codable, Sendable {
    public var role: TrustRole
    public var version: Int
    public var expiresAt: String
    public var scope: TrustScope
    public var keys: [String: String]?
    public var roles: [String: RoleRule]?
    public var references: [String: MetadataReference]?
    public var targets: [String: TargetRecord]?
    public var revokedKeys: [String]?
    public var revokedProfiles: [ProfileRevision]?
    public var revokedDigests: [String]?

    public init(role: TrustRole, version: Int, expiresAt: String, scope: TrustScope = .development,
                keys: [String: String]? = nil, roles: [String: RoleRule]? = nil,
                references: [String: MetadataReference]? = nil, targets: [String: TargetRecord]? = nil,
                revokedKeys: [String]? = nil, revokedProfiles: [ProfileRevision]? = nil,
                revokedDigests: [String]? = nil) {
        self.role = role
        self.version = version
        self.expiresAt = expiresAt
        self.scope = scope
        self.keys = keys
        self.roles = roles
        self.references = references
        self.targets = targets
        self.revokedKeys = revokedKeys
        self.revokedProfiles = revokedProfiles
        self.revokedDigests = revokedDigests
    }

    static func decode(_ bytes: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard try TrustCanonicalJSON.encode(value) == bytes,
              (1...9_007_199_254_740_991).contains(value.version) else {
            throw TrustError.malformed("metadata schema or version")
        }
        let flags = [value.keys != nil, value.roles != nil, value.references != nil, value.targets != nil,
                     value.revokedKeys != nil, value.revokedProfiles != nil, value.revokedDigests != nil]
        let expected: [Bool]
        switch value.role {
        case .root: expected = [true, true, false, false, false, false, false]
        case .targets: expected = [false, false, false, true, false, false, false]
        case .snapshot, .timestamp: expected = [false, false, true, false, false, false, false]
        case .revocation: expected = [false, false, false, false, true, true, true]
        default: throw TrustError.wrongRole
        }
        guard flags == expected else { throw TrustError.malformed("fields do not match metadata role") }
        return value
    }

    func authorized(_ role: TrustRole, excluding revoked: Set<String> = []) throws -> ([String: Data], Int) {
        guard let keys, let rule = roles?[role.rawValue] else { throw TrustError.invalidRoot }
        var result: [String: Data] = [:]
        for identifier in rule.keyIds where !revoked.contains(identifier) {
            guard let encoded = keys[identifier], let bytes = Data(base64Encoded: encoded) else {
                throw TrustError.invalidRoot
            }
            result[identifier] = bytes
        }
        guard result.count >= rule.threshold else { throw TrustError.revokedKey }
        return (result, rule.threshold)
    }

    func validateRoot() throws {
        guard role == .root, let keys, let roles, keys.count <= 128,
              Set(roles.keys) == Set(TrustRole.allCases.map(\.rawValue)) else { throw TrustError.invalidRoot }
        var assigned = Set<String>()
        for rule in roles.values {
            guard (1...32).contains(rule.threshold), rule.threshold <= rule.keyIds.count,
                  rule.keyIds.count <= 32, Set(rule.keyIds).count == rule.keyIds.count else {
                throw TrustError.invalidRoot
            }
            for identifier in rule.keyIds {
                guard assigned.insert(identifier).inserted, let encoded = keys[identifier],
                      let bytes = Data(base64Encoded: encoded), bytes.count == 32,
                      bytes.base64EncodedString() == encoded, SignedEnvelope.keyID(bytes) == identifier else {
                    throw TrustError.invalidRoot
                }
            }
        }
        guard assigned == Set(keys.keys) else { throw TrustError.invalidRoot }
    }
}

func trustDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
        throw TrustError.malformed("UTC timestamp")
    }
    return date
}

func requireFresh(_ value: String, now: Date, role: String) throws {
    guard try trustDate(value) > now else { throw TrustError.expired(role) }
}
