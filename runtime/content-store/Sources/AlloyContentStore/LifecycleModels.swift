// Author: Timur Isaev

import Foundation

/// The exact runtime references observed when an uninstall is planned.
public struct GenerationReferences: Codable, Equatable, Sendable {
    public let active: GenerationReference?
    public let rollback: GenerationReference?
    public let candidate: GenerationReference?

    public init(
        active: GenerationReference?, rollback: GenerationReference?, candidate: GenerationReference?
    ) {
        self.active = active
        self.rollback = rollback
        self.candidate = candidate
    }

    func reference(_ kind: ReferenceKind) -> GenerationReference? {
        switch kind {
        case .active: active
        case .rollback: rollback
        case .candidate: candidate
        }
    }
}

public struct RepairResult: Codable, Equatable, Sendable {
    public let objectCount: Int
    public let generationCount: Int
}

public enum ContentLifecycleError: Error, Equatable, Sendable {
    case conflictingOperation(String)
    case abortedOperation(String)
    case pendingActivation(String)
    case staleReferences(String)
    case invalidMaintenanceJournal(String)
    case changedGeneration(String)
    case missingRepairPayload(String)
}

struct RepairGeneration: Codable, Equatable {
    let gameID: String
    let reference: GenerationReference
}

struct MaintenanceOperation: Codable, Equatable {
    enum Kind: String, Codable { case uninstall, repair }
    enum State: String, Codable { case prepared, applied, complete }

    let schemaVersion: String
    let operationID: String
    let kind: Kind
    let gameID: String?
    let references: GenerationReferences?
    let layers: [LayerDescriptor]
    let generations: [RepairGeneration]
    var state: State

    init(
        operationID: String, kind: Kind, gameID: String? = nil,
        references: GenerationReferences? = nil, layers: [LayerDescriptor] = [],
        generations: [RepairGeneration] = []
    ) {
        schemaVersion = "1.0"
        self.operationID = operationID
        self.kind = kind
        self.gameID = gameID
        self.references = references
        self.layers = layers
        self.generations = generations
        state = .prepared
    }
}
