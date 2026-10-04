// Author: Timur Isaev

import Foundation

extension ContentStore {
    public static let uninstallFaultPoints = [
        "after-uninstall-journal", "after-uninstall-reference-item",
        "after-uninstall-references", "after-uninstall-complete"
    ]

    public static let repairFaultPoints = [
        "after-repair-journal", "after-repair-cas-stage", "after-repair-cas-item",
        "after-repair-layer-stage", "after-repair-layer-item",
        "after-repair-validation", "after-repair-applied", "after-repair-cleanup",
        "after-repair-complete"
    ]

    /// Repair selection may inspect validated reference metadata while target
    /// bytes are damaged. All normal callers retain content validation.
    public func referenceSnapshot(
        gameID: String, validateContents: Bool = true
    ) throws -> GenerationReferences {
        try validateIdentifier(gameID)
        return try withExclusiveLock {
            try referenceSnapshotUnlocked(gameID: gameID, validateContents: validateContents)
        }
    }

    /// Retires only Alloy runtime references. Generations, leases and saves remain.
    /// The supplied snapshot must match exactly before the durable intent is made.
    /// A repeated operation ID returns its original snapshot without retiring a
    /// later installation. GC performs subsequent reclamation independently.
    @discardableResult
    public func uninstall(
        gameID: String,
        expectedReferences: GenerationReferences,
        operationID: String,
        faultInjector: FaultInjector? = nil
    ) throws -> GenerationReferences {
        try validateIdentifier(gameID)
        try validateIdentifier(operationID)
        return try withExclusiveLock {
            if pathEntryExists(maintenanceURL(operationID)) {
                var operation = try readMaintenance(operationID)
                guard operation.kind == .uninstall, operation.gameID == gameID,
                      operation.references == expectedReferences else {
                    throw ContentLifecycleError.conflictingOperation(operationID)
                }
                try resumeMaintenance(&operation, faultInjector: faultInjector)
                return expectedReferences
            }
            try recoverMaintenanceUnlocked()
            try requireNoPendingActivation(gameID: gameID)
            guard try referenceSnapshotUnlocked(gameID: gameID) == expectedReferences else {
                throw ContentLifecycleError.staleReferences(gameID)
            }
            var operation = MaintenanceOperation(
                operationID: operationID, kind: .uninstall,
                gameID: gameID, references: expectedReferences
            )
            try writeMaintenance(operation)
            try faultInjector?("after-uninstall-journal")
            try resumeMaintenance(&operation, faultInjector: faultInjector)
            return expectedReferences
        }
    }

    func resumeRequestedActivation(
        operationID: String?, gameID: String, generationID: String,
        layers: [LayerInput], healthOutcome: HealthOutcome, faultInjector: FaultInjector? = nil
    ) throws -> GenerationReference? {
        guard let operationID, pathEntryExists(journalURL(operationID)) else { return nil }
        var operation = try readJournal(journalURL(operationID))
        guard operation.operationID == operationID, operation.gameID == gameID,
              operation.generationID == generationID, operation.layers == layers.map(\.descriptor),
              operation.healthOutcome == healthOutcome else {
            throw ContentLifecycleError.conflictingOperation(operationID)
        }
        guard operation.state != .aborted else {
            throw ContentLifecycleError.abortedOperation(operationID)
        }
        if !operation.state.isTerminal {
            try resume(&operation, faultInjector: faultInjector)
            _ = try synchronizeCatalogUnlocked(faultInjector: faultInjector)
        }
        return try activationResult(operation)
    }

    func activationResult(_ operation: ActivationOperation) throws -> GenerationReference {
        let result = operation.healthOutcome == .pass ? operation.candidate : operation.previousActive
        guard let result else { throw ContentStoreError.missingReference("active") }
        return result
    }

    func requireNoPendingActivation(gameID: String) throws {
        for operation in try incompleteOperationsUnlocked() where operation.gameID == gameID {
            throw ContentLifecycleError.pendingActivation(operation.operationID)
        }
    }

    func referenceSnapshotUnlocked(
        gameID: String, validateContents: Bool = true
    ) throws -> GenerationReferences {
        try GenerationReferences(
            active: readReference(.active, gameID: gameID, validateContents: validateContents),
            rollback: readReference(.rollback, gameID: gameID, validateContents: validateContents),
            candidate: readReference(.candidate, gameID: gameID, validateContents: validateContents)
        )
    }

    func recoverMaintenanceUnlocked(faultInjector: FaultInjector? = nil) throws {
        guard pathEntryExists(maintenanceDirectory) else { return }
        guard isDirectory(maintenanceDirectory) else {
            throw ContentStoreError.unsafeStoreEntry(maintenanceDirectory.path)
        }
        for url in try directoryEntries(maintenanceDirectory) where url.pathExtension == "json" {
            var operation = try readMaintenance(url.deletingPathExtension().lastPathComponent)
            try resumeMaintenance(&operation, faultInjector: faultInjector)
        }
    }

    func resumeMaintenance(
        _ operation: inout MaintenanceOperation, faultInjector: FaultInjector?
    ) throws {
        guard operation.state != .complete else { return }
        switch operation.kind {
        case .uninstall:
            try resumeUninstall(&operation, faultInjector: faultInjector)
        case .repair:
            try resumeRepair(&operation, faultInjector: faultInjector)
        }
    }

    func resumeUninstall(
        _ operation: inout MaintenanceOperation, faultInjector: FaultInjector?
    ) throws {
        guard let gameID = operation.gameID, let expected = operation.references else {
            throw ContentLifecycleError.invalidMaintenanceJournal(operation.operationID)
        }
        // A missing reference is an already-completed action. A different one is
        // a later writer and must never be removed by replaying this intent.
        for kind in ReferenceKind.allCases {
            let current = try readReference(kind, gameID: gameID)
            guard current == nil || current == expected.reference(kind) else {
                throw ContentLifecycleError.staleReferences(gameID)
            }
        }
        for kind in ReferenceKind.allCases {
            try removeReference(kind, gameID: gameID)
            try faultInjector?("after-uninstall-reference-item")
        }
        try faultInjector?("after-uninstall-references")
        _ = try synchronizeCatalogUnlocked(faultInjector: nil)
        operation.state = .complete
        try writeMaintenance(operation)
        try faultInjector?("after-uninstall-complete")
    }

    func writeMaintenance(_ operation: MaintenanceOperation) throws {
        try requireSafeDirectory(maintenanceDirectory, create: true)
        try writeAtomic(encoder.encode(operation), to: maintenanceURL(operation.operationID))
    }

    func readMaintenance(_ operationID: String) throws -> MaintenanceOperation {
        try validateIdentifier(operationID)
        let url = maintenanceURL(operationID)
        guard isRegularFile(url) else {
            throw ContentLifecycleError.invalidMaintenanceJournal(operationID)
        }
        let operation: MaintenanceOperation
        do {
            operation = try decoder.decode(MaintenanceOperation.self, from: Data(contentsOf: url))
        } catch {
            throw ContentLifecycleError.invalidMaintenanceJournal(operationID)
        }
        guard operation.schemaVersion == "1.0", operation.operationID == operationID else {
            throw ContentLifecycleError.invalidMaintenanceJournal(operationID)
        }
        switch operation.kind {
        case .uninstall:
            guard let gameID = operation.gameID, operation.references != nil,
                  operation.layers.isEmpty, operation.generations.isEmpty else {
                throw ContentLifecycleError.invalidMaintenanceJournal(operationID)
            }
            try validateIdentifier(gameID)
        case .repair:
            guard operation.gameID == nil, operation.references == nil, !operation.layers.isEmpty else {
                throw ContentLifecycleError.invalidMaintenanceJournal(operationID)
            }
            for layer in operation.layers { try validateLayerDescriptor(layer) }
            for generation in operation.generations {
                try validateIdentifier(generation.gameID)
                try validateIdentifier(generation.reference.generationID)
                _ = try rawSHA256(generation.reference.manifestDigest)
            }
        }
        return operation
    }

    var maintenanceDirectory: URL {
        root.appendingPathComponent("metadata/lifecycle", isDirectory: true)
    }

    func maintenanceURL(_ operationID: String) -> URL {
        maintenanceDirectory.appendingPathComponent("\(operationID).json")
    }
}
