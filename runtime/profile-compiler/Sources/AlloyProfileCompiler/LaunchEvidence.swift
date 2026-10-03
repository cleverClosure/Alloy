// Author: Timur Isaev

import Foundation

public struct FeatureCeiling: Codable, Equatable, Sendable {
    public var provider: String
    public var features: [String]
    public var limits: [String: Int]
}

public struct FeatureMask: Codable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var features: [String]
    public var limits: [String: Int]
    public var workaroundIds: [String]
}

public struct WorkaroundRecord: Codable, Equatable, Sendable {
    public var id: String
    public var owner: String
    public var reason: String
    public var gameBuild: String
    public var processPolicy: String
    public var introducedInProfileRevision: Int
    public var testEvidence: [String]
    public var expiresAt: String
    public var removalCondition: String
    public var userVisibleRisk: Bool
    public var performanceRisk: String
}

public struct VendorApproval: Codable, Equatable, Sendable {
    public var vendorId: String
    public var gameBuildDigest: String
    public var hostClassId: String
    public var profileDigest: String
    public var matrixDigest: String
    public var expiresAt: String
    public var scope: String
    public var keyId: String
    public var signature: String

    public var claims: [String: String] {
        ["vendorId": vendorId, "gameBuildDigest": gameBuildDigest, "hostClassId": hostClassId,
         "profileDigest": profileDigest, "matrixDigest": matrixDigest, "expiresAt": expiresAt, "scope": scope]
    }
}

public struct ProviderBinding: Codable, Equatable, Sendable {
    public var component: String
    public var directory: String
}

/// A test-signed companion to immutable profile/manifest bytes; not a production attestation.
public struct LaunchEvidence: Codable, Equatable, Sendable {
    public var profileDigest: String
    public var manifestDigest: String
    public var metadataDigest: String
    public var gameBuildDigest: String
    public var launcherBuildDigest: String?
    public var hostClassId: String
    public var matrixDigest: String
    public var lifecycle: String
    public var certificationExpiresAt: String
    public var fixtureCeilingsOnly: Bool
    public var ceilings: [FeatureCeiling]
    public var masks: [FeatureMask]
    public var workarounds: [WorkaroundRecord]
    public var vendorApproval: VendorApproval?
    public var providers: [String: ProviderBinding]
    public var processDigests: [String: String]
    public var approvedDependencyDigests: [String]

    public static func decode(_ bytes: Data) throws -> Self {
        try EvidenceShape.check(bytes)
        return try JSONDecoder().decode(Self.self, from: bytes)
    }
}

public struct LocalGrant: Codable, Equatable, Sendable {
    public var id: String
    public var gameId: String
    public var purpose: String
    public var access: DriveAccess

    public init(id: String, gameId: String, purpose: String, access: DriveAccess) {
        self.id = id
        self.gameId = gameId
        self.purpose = purpose
        self.access = access
    }
}

/// Registry state may be reused across compiles: an existing ID cannot change contents.
public struct FeatureMaskRegistry: Sendable {
    public private(set) var masks: [String: FeatureMask] = [:]
    private let ceilings: [String: FeatureCeiling]

    public init(ceilings: [FeatureCeiling], fixtureOnly: Bool) throws {
        guard fixtureOnly, Set(ceilings.map(\.provider)).count == ceilings.count else {
            throw CompilerFailure.rejected("feature ceilings must be unique synthetic fixtures")
        }
        self.ceilings = Dictionary(uniqueKeysWithValues: ceilings.map { ($0.provider, $0) })
        for ceiling in ceilings {
            guard ceiling.limits.values.allSatisfy({ $0 >= 0 }),
                  (ceiling.features + Array(ceiling.limits.keys)).allSatisfy({ $0.hasPrefix("fixture.") }) else {
                throw CompilerFailure.rejected("only explicitly synthetic feature names are accepted")
            }
        }
    }

    public mutating func register(_ mask: FeatureMask) throws {
        guard !mask.id.isEmpty, let ceiling = ceilings[mask.provider],
              Set(mask.features).isSubset(of: Set(ceiling.features)),
              mask.limits.allSatisfy({ key, value in
                  value >= 0 && ceiling.limits[key].map { value <= $0 } == true
              }) else {
            throw CompilerFailure.rejected("feature mask exceeds synthetic ceiling")
        }
        if let existing = masks[mask.id], existing != mask {
            throw CompilerFailure.rejected("feature mask identity is immutable")
        }
        masks[mask.id] = mask
    }
}

private enum EvidenceShape {
    static func check(_ data: Data) throws {
        let root = try object(JSONSerialization.jsonObject(with: data), keys: [
            "profileDigest", "manifestDigest", "metadataDigest", "gameBuildDigest", "launcherBuildDigest",
            "hostClassId", "matrixDigest", "lifecycle", "certificationExpiresAt", "fixtureCeilingsOnly",
            "ceilings", "masks",
            "workarounds", "vendorApproval", "providers", "processDigests", "approvedDependencyDigests"
        ])
        try array(root["ceilings"], keys: ["provider", "features", "limits"])
        try array(root["masks"], keys: ["id", "provider", "features", "limits", "workaroundIds"])
        try array(root["workarounds"], keys: [
            "id", "owner", "reason", "gameBuild", "processPolicy", "introducedInProfileRevision",
            "testEvidence", "expiresAt", "removalCondition", "userVisibleRisk", "performanceRisk"
        ])
        if let approval = root["vendorApproval"], !(approval is NSNull) {
            _ = try object(approval, keys: [
                "vendorId", "gameBuildDigest", "hostClassId", "profileDigest", "matrixDigest", "expiresAt",
                "scope", "keyId", "signature"
            ])
        }
        guard let providers = root["providers"] as? [String: Any] else {
            throw CompilerFailure.rejected("providers must be an object")
        }
        for value in providers.values { _ = try object(value, keys: ["component", "directory"]) }
    }

    private static func array(_ value: Any?, keys: Set<String>) throws {
        guard let values = value as? [Any] else { throw CompilerFailure.rejected("evidence field must be an array") }
        for value in values { _ = try object(value, keys: keys) }
    }

    private static func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else {
            throw CompilerFailure.rejected("unknown field or invalid object in launch evidence")
        }
        // Required properties and scalar/map element types are checked by the typed decoder.
        return object
    }
}
