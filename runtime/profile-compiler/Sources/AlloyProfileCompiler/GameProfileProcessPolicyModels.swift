// Author: Timur Isaev

import Foundation

// Process-policy objects from docs/schemas/game-profile.schema.json's
// `$defs/processPolicy`. Split from GameProfileModels.swift to keep each
// file under the house file-length limit; see that file's header for the
// shared transcription technique.

public struct ProcessPolicy: Decodable, Equatable, Sendable {
    public let id: String
    public let priority: Int
    public let match: ProcessMatch
    public let execution: ProcessExecution
    public let services: ProcessServices?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, priority, match, execution, services
    }

    static let requiredKeys: Set<CodingKeys> = [.id, .priority, .match, .execution]

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self, required: Self.requiredKeys)
        let path = decoder.codingPath
        id = try container.requiredValue(String.self, forKey: .id, at: path, expected: "string")
        priority = try container.requiredInt(forKey: .priority, at: path, minimum: 0, maximum: 100000)
        match = try container.requiredValue(ProcessMatch.self, forKey: .match, at: path, expected: "object")
        execution = try container.requiredValue(ProcessExecution.self, forKey: .execution, at: path, expected: "object")
        services = try container.optionalValue(ProcessServices.self, forKey: .services, at: path, expected: "object")
    }
}

/// `$defs/processPolicy.match`: `additionalProperties: false`, no `required`
/// array, but `minProperties: 1` — at least one match dimension must be set.
public struct ProcessMatch: Decodable, Equatable, Sendable {
    public let pathGlob: String?
    public let sha256: String?
    public let peMachine: PEMachine?
    public let productName: String?
    public let parentPolicyId: String?
    public let commandLineRegex: String?
    public let moduleFingerprint: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case pathGlob, sha256, peMachine, productName, parentPolicyId, commandLineRegex, moduleFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        pathGlob = try container.optionalValue(String.self, forKey: .pathGlob, at: path, expected: "string")
        sha256 = try container.optionalPatternString(SchemaPattern.hexDigest64, forKey: .sha256, at: path)
        peMachine = try container.optionalEnum(forKey: .peMachine, at: path)
        productName = try container.optionalValue(String.self, forKey: .productName, at: path, expected: "string")
        parentPolicyId = try container.optionalValue(String.self, forKey: .parentPolicyId, at: path, expected: "string")
        commandLineRegex = try container.optionalValue(
            String.self, forKey: .commandLineRegex, at: path, expected: "string"
        )
        moduleFingerprint = try container.optionalValue(
            [String].self, forKey: .moduleFingerprint, at: path, expected: "array of string"
        )
        let presentCount = [
            pathGlob != nil, sha256 != nil, peMachine != nil, productName != nil,
            parentPolicyId != nil, commandLineRegex != nil, moduleFingerprint != nil
        ].filter { $0 }.count
        guard presentCount >= 1 else {
            throw ValidationFailure.tooFewProperties(path: renderPath(path), minimum: 1, actual: 0)
        }
    }
}

public struct ProcessExecution: Decodable, Equatable, Sendable {
    public let cpuProvider: ExecutionCPUProvider?
    public let graphicsProvider: ExecutionGraphicsProvider?
    public let syncProvider: ExecutionSyncProvider?
    public let featureMask: String?
    public let dllOverrides: [String: DLLLoadOrder]?
    public let environment: [String: String]?
    public let workingDirectory: String?
    public let networkPolicy: ProcessNetworkPolicy?
    public let debugPolicy: ProcessDebugPolicy?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case cpuProvider, graphicsProvider, syncProvider, featureMask
        case dllOverrides, environment, workingDirectory, networkPolicy, debugPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        cpuProvider = try container.optionalEnum(forKey: .cpuProvider, at: path)
        graphicsProvider = try container.optionalEnum(forKey: .graphicsProvider, at: path)
        syncProvider = try container.optionalEnum(forKey: .syncProvider, at: path)
        featureMask = try container.optionalValue(String.self, forKey: .featureMask, at: path, expected: "string")
        dllOverrides = try container.optionalEnumMap(forKey: .dllOverrides, at: path)
        environment = try container.optionalValue(
            [String: String].self, forKey: .environment, at: path, expected: "object of string"
        )
        workingDirectory = try container.optionalValue(
            String.self, forKey: .workingDirectory, at: path, expected: "string"
        )
        networkPolicy = try container.optionalEnum(forKey: .networkPolicy, at: path)
        debugPolicy = try container.optionalEnum(forKey: .debugPolicy, at: path)
    }
}

public struct ProcessServices: Decodable, Equatable, Sendable {
    public let audio: String?
    public let input: String?
    public let media: String?
    public let presentation: String?
    public let storage: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case audio, input, media, presentation, storage
    }

    public init(from decoder: Decoder) throws {
        let container = try strictContainer(decoder, keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        audio = try container.optionalValue(String.self, forKey: .audio, at: path, expected: "string")
        input = try container.optionalValue(String.self, forKey: .input, at: path, expected: "string")
        media = try container.optionalValue(String.self, forKey: .media, at: path, expected: "string")
        presentation = try container.optionalValue(String.self, forKey: .presentation, at: path, expected: "string")
        storage = try container.optionalValue(String.self, forKey: .storage, at: path, expected: "string")
    }
}
