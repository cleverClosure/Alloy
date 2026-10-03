// Author: Tim Isaev

import Foundation

// Transcribed from docs/schemas/runtime-manifest.schema.json the same way
// GameProfileModels.swift transcribes the profile schema — see that file's
// header comment for the technique.

public enum ReleaseRing: String, Codable, CaseIterable, Equatable, Sendable {
    case development
    case lab
    case canary
    case stable
    case quarantined
}

public struct RuntimeManifestDocument: Decodable, Equatable, Sendable {
    public let schemaVersion: String
    public let generationId: String
    public let createdAt: String
    public let components: [RuntimeComponent]
    public let hostRequirements: RuntimeHostRequirements
    public let provenance: RuntimeProvenance
    public let activation: RuntimeActivation?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, generationId, createdAt, components, hostRequirements, provenance, activation
    }

    static let requiredKeys: Set<CodingKeys> = [
        .schemaVersion, .generationId, .createdAt, .components, .hostRequirements, .provenance
    ]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        schemaVersion = try container.requiredConstString("1.0", forKey: .schemaVersion, at: path)
        generationId = try container.requiredPatternString(
            SchemaPattern.generationId, forKey: .generationId, at: path
        )
        createdAt = try container.requiredDateTimeString(forKey: .createdAt, at: path)
        components = try container.requiredValue(
            [RuntimeComponent].self, forKey: .components, at: path, expected: "array"
        )
        try checkArrayConstraints(components, path: renderPath(path, appending: "components"), minItems: 1)
        hostRequirements = try container.requiredValue(
            RuntimeHostRequirements.self, forKey: .hostRequirements, at: path, expected: "object"
        )
        provenance = try container.requiredValue(
            RuntimeProvenance.self, forKey: .provenance, at: path, expected: "object"
        )
        activation = try container.optionalValue(
            RuntimeActivation.self, forKey: .activation, at: path, expected: "object"
        )
    }
}

public struct RuntimeComponent: Decodable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let digest: String
    public let mediaType: String
    public let size: Int
    public let licenseId: String?
    public let sourceRevision: String?
    public let sbomDigest: String?
    public let symbolsDigest: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name, version, digest, mediaType, size, licenseId, sourceRevision, sbomDigest, symbolsDigest
    }

    static let requiredKeys: Set<CodingKeys> = [.name, .version, .digest, .mediaType, .size]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        name = try container.requiredValue(String.self, forKey: .name, at: path, expected: "string")
        version = try container.requiredValue(String.self, forKey: .version, at: path, expected: "string")
        digest = try container.requiredPatternString(SchemaPattern.digestWithAlgorithm, forKey: .digest, at: path)
        mediaType = try container.requiredValue(String.self, forKey: .mediaType, at: path, expected: "string")
        size = try container.requiredInt(forKey: .size, at: path, minimum: 0)
        licenseId = try container.optionalValue(String.self, forKey: .licenseId, at: path, expected: "string")
        sourceRevision = try container.optionalValue(String.self, forKey: .sourceRevision, at: path, expected: "string")
        sbomDigest = try container.optionalPatternString(
            SchemaPattern.digestWithAlgorithm, forKey: .sbomDigest, at: path
        )
        symbolsDigest = try container.optionalPatternString(
            SchemaPattern.digestWithAlgorithm, forKey: .symbolsDigest, at: path
        )
    }
}

public struct RuntimeHostRequirements: Decodable, Equatable, Sendable {
    public let architecture: String
    public let minimumMacOS: String
    public let metalFeatureSets: [String]?
    public let requiredEntitlements: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case architecture, minimumMacOS, metalFeatureSets, requiredEntitlements
    }

    static let requiredKeys: Set<CodingKeys> = [.architecture, .minimumMacOS]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        architecture = try container.requiredConstString("arm64", forKey: .architecture, at: path)
        minimumMacOS = try container.requiredValue(String.self, forKey: .minimumMacOS, at: path, expected: "string")
        metalFeatureSets = try container.optionalValue(
            [String].self, forKey: .metalFeatureSets, at: path, expected: "array of string"
        )
        requiredEntitlements = try container.optionalValue(
            [String].self, forKey: .requiredEntitlements, at: path, expected: "array of string"
        )
    }
}

public struct RuntimeProvenance: Decodable, Equatable, Sendable {
    public let builderId: String
    public let sourceDigest: String
    public let buildRecipeDigest: String
    public let attestationDigest: String
    public let reproducible: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case builderId, sourceDigest, buildRecipeDigest, attestationDigest, reproducible
    }

    static let requiredKeys: Set<CodingKeys> = [.builderId, .sourceDigest, .buildRecipeDigest, .attestationDigest]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        builderId = try container.requiredValue(String.self, forKey: .builderId, at: path, expected: "string")
        sourceDigest = try container.requiredValue(String.self, forKey: .sourceDigest, at: path, expected: "string")
        buildRecipeDigest = try container.requiredValue(
            String.self, forKey: .buildRecipeDigest, at: path, expected: "string"
        )
        attestationDigest = try container.requiredValue(
            String.self, forKey: .attestationDigest, at: path, expected: "string"
        )
        reproducible = try container.optionalBool(forKey: .reproducible, at: path)
    }
}

public struct RuntimeActivation: Decodable, Equatable, Sendable {
    public let minimumClientVersion: String?
    public let releaseRing: ReleaseRing?
    public let rollbackGenerationId: String?
    public let healthWindowSessions: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case minimumClientVersion, releaseRing, rollbackGenerationId, healthWindowSessions
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        minimumClientVersion = try container.optionalValue(
            String.self, forKey: .minimumClientVersion, at: path, expected: "string"
        )
        releaseRing = try container.optionalEnum(forKey: .releaseRing, at: path)
        rollbackGenerationId = try container.optionalValue(
            String.self, forKey: .rollbackGenerationId, at: path, expected: "string"
        )
        healthWindowSessions = try container.optionalInt(forKey: .healthWindowSessions, at: path, minimum: 1)
    }
}
