// Author: Timur Isaev

import Foundation

public enum LayerRole: String, Codable, CaseIterable, Sendable {
    case hostRuntime = "host-runtime"
    case wineRuntime = "wine-runtime"
    case cpuProvider = "cpu-provider"
    case graphicsProvider = "graphics-provider"
    case nativeService = "native-service"
    case shaderCompiler = "shader-compiler"
    case dependency
    case profile
}

public struct LayerDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let digest: String
    public let mediaType: String
    public let size: Int
    public let role: LayerRole
    public let sourceRevision: String?
    public let licenseID: String?
    public let sbomDigest: String?
    public let symbolsDigest: String?

    public init(
        name: String,
        version: String,
        digest: String,
        mediaType: String,
        size: Int,
        role: LayerRole,
        sourceRevision: String? = nil,
        licenseID: String? = nil,
        sbomDigest: String? = nil,
        symbolsDigest: String? = nil
    ) {
        self.name = name
        self.version = version
        self.digest = digest
        self.mediaType = mediaType
        self.size = size
        self.role = role
        self.sourceRevision = sourceRevision
        self.licenseID = licenseID
        self.sbomDigest = sbomDigest
        self.symbolsDigest = symbolsDigest
    }

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case digest
        case mediaType
        case size
        case role
        case sourceRevision
        case licenseID = "licenseId"
        case sbomDigest
        case symbolsDigest
    }
}

public struct LayerInput: Equatable, Sendable {
    public let descriptor: LayerDescriptor
    public let contents: Data

    public init(descriptor: LayerDescriptor, contents: Data) {
        self.descriptor = descriptor
        self.contents = contents
    }
}

public struct GenerationReference: Codable, Equatable, Sendable {
    public let generationID: String
    public let manifestDigest: String

    public init(generationID: String, manifestDigest: String) {
        self.generationID = generationID
        self.manifestDigest = manifestDigest
    }

    enum CodingKeys: String, CodingKey {
        case generationID = "generationId"
        case manifestDigest
    }
}

public struct GenerationManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "1.0"

    public let schemaVersion: String
    public let gameID: String
    public let generationID: String
    public let layers: [LayerDescriptor]

    init(gameID: String, generationID: String, layers: [LayerDescriptor]) {
        schemaVersion = Self.currentSchemaVersion
        self.gameID = gameID
        self.generationID = generationID
        self.layers = layers
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gameID = "gameId"
        case generationID = "generationId"
        case layers
    }
}

public enum HealthOutcome: String, Codable, Sendable {
    case pass
    case fail
}

public enum OperationState: String, Codable, CaseIterable, Sendable {
    case started
    case downloaded
    case verified
    case published
    case materialized
    case candidatePrepared = "candidate-prepared"
    case rollbackRecorded = "rollback-recorded"
    case activeSwitched = "active-switched"
    case healthChecked = "health-checked"
    case retained
    case complete
    case aborted

    var isTerminal: Bool {
        self == .complete || self == .aborted
    }
}

struct ActivationOperation: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"
    static let kind = "activate-generation"

    let schemaVersion: String
    let kind: String
    let operationID: String
    let gameID: String
    let generationID: String
    let layers: [LayerDescriptor]
    let healthOutcome: HealthOutcome
    let previousActive: GenerationReference?
    var candidate: GenerationReference?
    var state: OperationState

    init(
        operationID: String,
        gameID: String,
        generationID: String,
        layers: [LayerDescriptor],
        healthOutcome: HealthOutcome,
        previousActive: GenerationReference?
    ) {
        schemaVersion = Self.currentSchemaVersion
        kind = Self.kind
        self.operationID = operationID
        self.gameID = gameID
        self.generationID = generationID
        self.layers = layers
        self.healthOutcome = healthOutcome
        self.previousActive = previousActive
        candidate = nil
        state = .started
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case operationID = "operationId"
        case gameID = "gameId"
        case generationID = "generationId"
        case layers
        case healthOutcome
        case previousActive
        case candidate
        case state
    }
}

public struct StoreInspection: Codable, Equatable, Sendable {
    public let active: GenerationReference?
    public let rollback: GenerationReference?
    public let candidate: GenerationReference?
    public let objectCount: Int
    public let incompleteOperationCount: Int

    public init(
        active: GenerationReference?,
        rollback: GenerationReference?,
        candidate: GenerationReference?,
        objectCount: Int,
        incompleteOperationCount: Int
    ) {
        self.active = active
        self.rollback = rollback
        self.candidate = candidate
        self.objectCount = objectCount
        self.incompleteOperationCount = incompleteOperationCount
    }
}

public enum ContentStoreError: Error, CustomStringConvertible, Equatable {
    case corruptObject(String)
    case digestMismatch(expected: String, actual: String)
    case emptyLayerSet
    case incompleteGeneration(String)
    case injectedTermination(String)
    case invalidIdentifier(String)
    case invalidJournal(String)
    case invalidLayer(String)
    case missingDownload(String)
    case missingReference(String)
    case sizeMismatch(expected: Int, actual: Int)
    case systemCall(operation: String, code: Int32)
    case unsupportedSchema(kind: String, version: String)

    public var description: String {
        switch self {
        case let .corruptObject(digest):
            "corrupt CAS object: \(digest)"
        case let .digestMismatch(expected, actual):
            "digest mismatch: expected \(expected), got \(actual)"
        case .emptyLayerSet:
            "a generation must contain at least one layer"
        case let .incompleteGeneration(generation):
            "incomplete generation: \(generation)"
        case let .injectedTermination(point):
            "injected termination at \(point)"
        case let .invalidIdentifier(identifier):
            "invalid identifier: \(identifier)"
        case let .invalidJournal(operation):
            "invalid operation journal: \(operation)"
        case let .invalidLayer(reason):
            "invalid layer: \(reason)"
        case let .missingDownload(operation):
            "missing staged download for operation: \(operation)"
        case let .missingReference(name):
            "missing reference: \(name)"
        case let .sizeMismatch(expected, actual):
            "size mismatch: expected \(expected), got \(actual)"
        case let .systemCall(operation, code):
            "\(operation) failed with errno \(code)"
        case let .unsupportedSchema(kind, version):
            "unsupported \(kind) schema version: \(version)"
        }
    }
}

public typealias FaultInjector = @Sendable (String) throws -> Void
