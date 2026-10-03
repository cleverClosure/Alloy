// Author: Tim Isaev

import Foundation

// Filesystem, registry, dependency, health-check, telemetry, and
// certification objects from docs/schemas/game-profile.schema.json. Split
// from GameProfileModels.swift to keep each file under the house
// file-length limit; see that file's header for the shared transcription
// technique.

public struct FilesystemPolicy: Decodable, Equatable, Sendable {
    public let driveMappings: [DriveMapping]?
    public let caseMode: FilesystemCaseMode?
    public let denyHostRoot: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case driveMappings, caseMode, denyHostRoot
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        driveMappings = try container.optionalValue(
            [DriveMapping].self, forKey: .driveMappings, at: path, expected: "array"
        )
        caseMode = try container.optionalEnum(forKey: .caseMode, at: path)
        denyHostRoot = try container.optionalBool(forKey: .denyHostRoot, at: path)
    }
}

public struct DriveMapping: Decodable, Equatable, Sendable {
    public let letter: String
    public let target: DriveTarget
    public let access: DriveAccess
    public let grantId: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case letter, target, access, grantId
    }

    static let requiredKeys: Set<CodingKeys> = [.letter, .target, .access]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        letter = try container.requiredPatternString(SchemaPattern.driveLetter, forKey: .letter, at: path)
        target = try container.requiredEnum(forKey: .target, at: path)
        access = try container.requiredEnum(forKey: .access, at: path)
        grantId = try container.optionalValue(String.self, forKey: .grantId, at: path, expected: "string")
    }
}

public struct RegistryPolicy: Decodable, Equatable, Sendable {
    public let sets: [RegistryMutation]?
    public let deletes: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sets, deletes
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        sets = try container.optionalValue([RegistryMutation].self, forKey: .sets, at: path, expected: "array")
        deletes = try container.optionalValue([String].self, forKey: .deletes, at: path, expected: "array of string")
    }
}

/// `$defs/registryMutation`: `value` has schema `{}` — any valid JSON.
public struct RegistryMutation: Decodable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let type: RegistryValueType
    public let value: JSONValue

    enum CodingKeys: String, CodingKey, CaseIterable {
        case key, name, type, value
    }

    static let requiredKeys: Set<CodingKeys> = [.key, .name, .type, .value]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        key = try container.requiredValue(String.self, forKey: .key, at: path, expected: "string")
        name = try container.requiredValue(String.self, forKey: .name, at: path, expected: "string")
        type = try container.requiredEnum(forKey: .type, at: path)
        value = try container.requiredValue(JSONValue.self, forKey: .value, at: path, expected: "any JSON value")
    }
}

public struct Dependency: Decodable, Equatable, Sendable {
    public let id: String
    public let source: DependencySource
    public let installMode: DependencyInstallMode
    public let digest: String?
    public let licenseGate: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, source, installMode, digest, licenseGate
    }

    static let requiredKeys: Set<CodingKeys> = [.id, .source, .installMode]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        id = try container.requiredValue(String.self, forKey: .id, at: path, expected: "string")
        source = try container.requiredEnum(forKey: .source, at: path)
        installMode = try container.requiredEnum(forKey: .installMode, at: path)
        digest = try container.optionalPatternString(SchemaPattern.digestWithAlgorithm, forKey: .digest, at: path)
        licenseGate = try container.optionalValue(String.self, forKey: .licenseGate, at: path, expected: "string")
    }
}

public struct HealthCheck: Decodable, Equatable, Sendable {
    public let kind: HealthCheckKind
    public let target: String?
    public let deadlineSeconds: Int?
    public let severity: HealthCheckSeverity

    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, target, deadlineSeconds, severity
    }

    static let requiredKeys: Set<CodingKeys> = [.kind, .severity]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        kind = try container.requiredEnum(forKey: .kind, at: path)
        target = try container.optionalValue(String.self, forKey: .target, at: path, expected: "string")
        deadlineSeconds = try container.optionalInt(forKey: .deadlineSeconds, at: path, minimum: 1)
        severity = try container.requiredEnum(forKey: .severity, at: path)
    }
}

public struct TelemetryPolicy: Decodable, Equatable, Sendable {
    public let defaultLevel: TelemetryLevel?
    public let redactionPolicy: String?
    public let sampling: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case defaultLevel, redactionPolicy, sampling
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        defaultLevel = try container.optionalEnum(forKey: .defaultLevel, at: path)
        redactionPolicy = try container.optionalValue(
            String.self, forKey: .redactionPolicy, at: path, expected: "string"
        )
        sampling = try container.optionalDouble(forKey: .sampling, at: path, minimum: 0, maximum: 1)
    }
}

public struct CertificationRecord: Decodable, Equatable, Sendable {
    public let level: CertificationLevel
    public let testedAt: String
    public let testPlanId: String
    public let matrixDigest: String
    public let knownLimitations: [String]?
    public let expiresAt: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case level, testedAt, testPlanId, matrixDigest, knownLimitations, expiresAt
    }

    static let requiredKeys: Set<CodingKeys> = [.level, .testedAt, .testPlanId, .matrixDigest]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        level = try container.requiredEnum(forKey: .level, at: path)
        testedAt = try container.requiredDateTimeString(forKey: .testedAt, at: path)
        testPlanId = try container.requiredValue(String.self, forKey: .testPlanId, at: path, expected: "string")
        matrixDigest = try container.requiredPatternString(
            SchemaPattern.digestWithAlgorithm, forKey: .matrixDigest, at: path
        )
        knownLimitations = try container.optionalValue(
            [String].self, forKey: .knownLimitations, at: path, expected: "array of string"
        )
        expiresAt = try container.optionalDateTimeString(forKey: .expiresAt, at: path)
    }
}
