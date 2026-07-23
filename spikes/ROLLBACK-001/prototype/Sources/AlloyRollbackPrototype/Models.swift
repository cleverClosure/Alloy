// Author: Timur Isaev

import Foundation

public struct GenerationReference: Codable, Equatable, Sendable {
    public let generationID: String
    public let manifestSHA256: String

    public init(generationID: String, manifestSHA256: String) {
        self.generationID = generationID
        self.manifestSHA256 = manifestSHA256
    }
}

public struct GenerationManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let gameID: String
    public let generationID: String
    public let objectSHA256: [String]

    public init(gameID: String, generationID: String, objectSHA256: [String]) {
        schemaVersion = 1
        self.gameID = gameID
        self.generationID = generationID
        self.objectSHA256 = objectSHA256
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
    case candidatePrepared
    case rollbackRecorded
    case activeSwitched
    case healthChecked
    case retained
    case complete
    case aborted

    var isTerminal: Bool {
        self == .complete || self == .aborted
    }
}

struct ActivationOperation: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let operationID: String
    let gameID: String
    let generationID: String
    let expectedObjectSHA256: String
    let healthOutcome: HealthOutcome
    let previousActive: GenerationReference?
    var candidate: GenerationReference?
    var state: OperationState

    init(
        operationID: String,
        gameID: String,
        generationID: String,
        expectedObjectSHA256: String,
        healthOutcome: HealthOutcome,
        previousActive: GenerationReference?
    ) {
        schemaVersion = 1
        self.operationID = operationID
        self.gameID = gameID
        self.generationID = generationID
        self.expectedObjectSHA256 = expectedObjectSHA256
        self.healthOutcome = healthOutcome
        self.previousActive = previousActive
        candidate = nil
        state = .started
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

public enum RuntimeStoreError: Error, CustomStringConvertible, Equatable {
    case corruptObject(String)
    case digestMismatch(expected: String, actual: String)
    case incompleteGeneration(String)
    case injectedTermination(String)
    case invalidIdentifier(String)
    case invalidJournal(String)
    case missingDownload(String)
    case missingReference(String)
    case systemCall(operation: String, code: Int32)

    public var description: String {
        switch self {
        case let .corruptObject(digest):
            "corrupt CAS object: \(digest)"
        case let .digestMismatch(expected, actual):
            "digest mismatch: expected \(expected), got \(actual)"
        case let .incompleteGeneration(generation):
            "incomplete generation: \(generation)"
        case let .injectedTermination(point):
            "injected termination at \(point)"
        case let .invalidIdentifier(identifier):
            "invalid identifier: \(identifier)"
        case let .invalidJournal(operation):
            "invalid operation journal: \(operation)"
        case let .missingDownload(operation):
            "missing staged download for operation: \(operation)"
        case let .missingReference(name):
            "missing reference: \(name)"
        case let .systemCall(operation, code):
            "\(operation) failed with errno \(code)"
        }
    }
}

public typealias FaultInjector = @Sendable (String) throws -> Void
