// Author: Timur Isaev

import Foundation

// Each type's `init(from:)` is the validator for the corresponding object in
// docs/schemas/game-profile.schema.json: it opens with `strictContainer`
// (additionalProperties: false + required keys), then decodes every property
// through one of the typed helpers in JSONSupport.swift so a pattern, enum,
// format, or numeric-bound violation produces a `ValidationFailure` naming
// its exact path rather than a generic decode error. CodingKeys stays
// internal (not private) so SchemaDriftTests can read `allCases` back.

public struct GameProfileDocument: Decodable, Equatable, Sendable {
    public let schemaVersion: String
    public let profileId: String
    public let revision: Int
    public let supersedes: [String]?
    public let game: GameInfo
    public let selectors: ProfileSelectors
    public let runtime: RuntimeConfiguration
    public let processPolicies: [ProcessPolicy]
    public let filesystem: FilesystemPolicy?
    public let registry: RegistryPolicy?
    public let dependencies: [Dependency]?
    public let healthChecks: [HealthCheck]?
    public let telemetry: TelemetryPolicy?
    public let certification: CertificationRecord

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, profileId, revision, supersedes, game, selectors, runtime
        case processPolicies, filesystem, registry, dependencies, healthChecks, telemetry, certification
    }

    static let requiredKeys: Set<CodingKeys> = [
        .schemaVersion, .profileId, .revision, .game, .selectors, .runtime, .processPolicies, .certification
    ]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        schemaVersion = try container.requiredConstString("1.0", forKey: .schemaVersion, at: path)
        profileId = try container.requiredPatternString(SchemaPattern.profileId, forKey: .profileId, at: path)
        revision = try container.requiredInt(forKey: .revision, at: path, minimum: 1)
        supersedes = try container.optionalValue(
            [String].self, forKey: .supersedes, at: path, expected: "array of string"
        )
        if let supersedes {
            try checkArrayConstraints(supersedes, path: renderPath(path, appending: "supersedes"), uniqueBy: { $0 })
        }
        game = try container.requiredValue(GameInfo.self, forKey: .game, at: path, expected: "object")
        selectors = try container.requiredValue(
            ProfileSelectors.self, forKey: .selectors, at: path, expected: "object"
        )
        runtime = try container.requiredValue(
            RuntimeConfiguration.self, forKey: .runtime, at: path, expected: "object"
        )
        processPolicies = try container.requiredValue(
            [ProcessPolicy].self, forKey: .processPolicies, at: path, expected: "array"
        )
        try checkArrayConstraints(processPolicies, path: renderPath(path, appending: "processPolicies"), minItems: 1)
        filesystem = try container.optionalValue(
            FilesystemPolicy.self, forKey: .filesystem, at: path, expected: "object"
        )
        registry = try container.optionalValue(RegistryPolicy.self, forKey: .registry, at: path, expected: "object")
        dependencies = try container.optionalValue(
            [Dependency].self, forKey: .dependencies, at: path, expected: "array"
        )
        healthChecks = try container.optionalValue(
            [HealthCheck].self, forKey: .healthChecks, at: path, expected: "array"
        )
        telemetry = try container.optionalValue(TelemetryPolicy.self, forKey: .telemetry, at: path, expected: "object")
        certification = try container.requiredValue(
            CertificationRecord.self, forKey: .certification, at: path, expected: "object"
        )
    }
}

public struct GameInfo: Decodable, Equatable, Sendable {
    public let canonicalId: String
    public let displayName: String
    public let publisher: String?
    public let storefronts: [Storefront]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case canonicalId, displayName, publisher, storefronts
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(
            decoder, keyedBy: CodingKeys.self, required: [.canonicalId, .displayName, .storefronts]
        )
        let path = decoder.codingPath
        canonicalId = try container.requiredValue(String.self, forKey: .canonicalId, at: path, expected: "string")
        displayName = try container.requiredValue(String.self, forKey: .displayName, at: path, expected: "string")
        publisher = try container.optionalValue(String.self, forKey: .publisher, at: path, expected: "string")
        storefronts = try container.requiredValue([Storefront].self, forKey: .storefronts, at: path, expected: "array")
        try checkArrayConstraints(storefronts, path: renderPath(path, appending: "storefronts"), minItems: 1)
    }
}

public struct Storefront: Decodable, Equatable, Sendable {
    public let kind: StorefrontKind
    public let appId: String
    public let branch: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, appId, branch
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: [.kind, .appId])
        let path = decoder.codingPath
        kind = try container.requiredEnum(forKey: .kind, at: path)
        appId = try container.requiredValue(String.self, forKey: .appId, at: path, expected: "string")
        branch = try container.optionalValue(String.self, forKey: .branch, at: path, expected: "string")
    }
}

public struct ProfileSelectors: Decodable, Equatable, Sendable {
    public let gameBuild: BuildSelector
    public let launcherBuild: BuildSelector?
    public let host: HostSelector

    enum CodingKeys: String, CodingKey, CaseIterable {
        case gameBuild, launcherBuild, host
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: [.gameBuild, .host])
        let path = decoder.codingPath
        gameBuild = try container.requiredValue(BuildSelector.self, forKey: .gameBuild, at: path, expected: "object")
        launcherBuild = try container.optionalValue(
            BuildSelector.self, forKey: .launcherBuild, at: path, expected: "object"
        )
        host = try container.requiredValue(HostSelector.self, forKey: .host, at: path, expected: "object")
    }
}

/// `$defs/buildSelector`: `additionalProperties: false` plus an `anyOf` that
/// requires at least one of `version`, `manifestId`, `requiredFiles`.
public struct BuildSelector: Decodable, Equatable, Sendable {
    public let version: String?
    public let manifestId: String?
    public let requiredFiles: [RequiredFile]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, manifestId, requiredFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        version = try container.optionalValue(String.self, forKey: .version, at: path, expected: "string")
        manifestId = try container.optionalValue(String.self, forKey: .manifestId, at: path, expected: "string")
        requiredFiles = try container.optionalValue(
            [RequiredFile].self, forKey: .requiredFiles, at: path, expected: "array"
        )
        guard version != nil || manifestId != nil || requiredFiles != nil else {
            throw ValidationFailure.noSelectorPresent(
                path: renderPath(path),
                oneOf: ["version", "manifestId", "requiredFiles"]
            )
        }
    }
}

public struct RequiredFile: Decodable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let size: Int?
    public let peTimestamp: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case path, sha256, size, peTimestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: [.path, .sha256])
        let path = decoder.codingPath
        self.path = try container.requiredValue(String.self, forKey: .path, at: path, expected: "string")
        sha256 = try container.requiredPatternString(SchemaPattern.hexDigest64, forKey: .sha256, at: path)
        size = try container.optionalInt(forKey: .size, at: path, minimum: 0)
        peTimestamp = try container.optionalInt(forKey: .peTimestamp, at: path, minimum: 0)
    }
}

public struct HostSelector: Decodable, Equatable, Sendable {
    public let architecture: String
    public let macos: MacOSRange?
    public let gpuFamilies: [String]?
    public let memoryClassesGiB: [Int]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case architecture, macos, gpuFamilies, memoryClassesGiB
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: [.architecture, .macos])
        let path = decoder.codingPath
        architecture = try container.requiredConstString("arm64", forKey: .architecture, at: path)
        macos = try container.requiredValue(MacOSRange.self, forKey: .macos, at: path, expected: "object")
        gpuFamilies = try container.optionalValue(
            [String].self, forKey: .gpuFamilies, at: path, expected: "array of string"
        )
        if let gpuFamilies {
            try checkArrayConstraints(gpuFamilies, path: renderPath(path, appending: "gpuFamilies"), uniqueBy: { $0 })
        }
        memoryClassesGiB = try container.optionalValue(
            [Int].self, forKey: .memoryClassesGiB, at: path, expected: "array of integer"
        )
        if let memoryClassesGiB {
            for (index, value) in memoryClassesGiB.enumerated() {
                guard value >= 8 else {
                    throw ValidationFailure.belowMinimum(
                        path: renderPath(path, appending: "memoryClassesGiB") + "[\(index)]",
                        minimum: 8,
                        actual: Double(value)
                    )
                }
            }
            try checkArrayConstraints(
                memoryClassesGiB,
                path: renderPath(path, appending: "memoryClassesGiB"),
                uniqueBy: { String($0) }
            )
        }
    }
}

/// `host.macos` has no `required` array in the schema: all three members —
/// including `min`, despite every fixture setting it — are individually
/// optional.
public struct MacOSRange: Decodable, Equatable, Sendable {
    public let min: String?
    public let maxExclusive: String?
    public let allowedBuilds: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case min, maxExclusive, allowedBuilds
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        min = try container.optionalValue(String.self, forKey: .min, at: path, expected: "string")
        maxExclusive = try container.optionalValue(String.self, forKey: .maxExclusive, at: path, expected: "string")
        allowedBuilds = try container.optionalValue(
            [String].self, forKey: .allowedBuilds, at: path, expected: "array of string"
        )
    }
}

public struct RuntimeConfiguration: Decodable, Equatable, Sendable {
    public let generation: String
    public let layers: [LayerSpec]
    public let cpuProvider: CPUProvider
    public let defaultGraphicsProvider: GraphicsProvider
    public let syncProvider: SyncProvider?
    public let windowsVersion: String?
    public let locale: String?
    public let timezoneMode: TimezoneMode?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case generation, layers, cpuProvider, defaultGraphicsProvider
        case syncProvider, windowsVersion, locale, timezoneMode
    }

    static let requiredKeys: Set<CodingKeys> = [.generation, .layers, .cpuProvider, .defaultGraphicsProvider]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        generation = try container.requiredValue(String.self, forKey: .generation, at: path, expected: "string")
        layers = try container.requiredValue([LayerSpec].self, forKey: .layers, at: path, expected: "array")
        try checkArrayConstraints(layers, path: renderPath(path, appending: "layers"), minItems: 1)
        cpuProvider = try container.requiredEnum(forKey: .cpuProvider, at: path)
        defaultGraphicsProvider = try container.requiredEnum(forKey: .defaultGraphicsProvider, at: path)
        syncProvider = try container.optionalEnum(forKey: .syncProvider, at: path)
        windowsVersion = try container.optionalValue(String.self, forKey: .windowsVersion, at: path, expected: "string")
        locale = try container.optionalValue(String.self, forKey: .locale, at: path, expected: "string")
        timezoneMode = try container.optionalEnum(forKey: .timezoneMode, at: path)
    }
}

public struct LayerSpec: Decodable, Equatable, Sendable {
    public let role: ProfileLayerRole
    public let digest: String
    public let size: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case role, digest, size
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: [.role, .digest])
        let path = decoder.codingPath
        role = try container.requiredEnum(forKey: .role, at: path)
        digest = try container.requiredPatternString(SchemaPattern.digestWithAlgorithm, forKey: .digest, at: path)
        size = try container.optionalInt(forKey: .size, at: path, minimum: 0)
    }
}
