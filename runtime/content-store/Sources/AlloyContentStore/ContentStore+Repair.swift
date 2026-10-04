// Author: Timur Isaev

import Darwin
import Foundation

extension ContentStore {
    /// Restores verified CAS bytes and every materialized hard link using them.
    /// Open with allowDamagedCatalog only for this recovery entry point. Fetch
    /// replacement inputs through a separate healthy staging store first.
    /// Manifest corruption and missing unrelated objects fail closed.
    @discardableResult
    public func repairObjects(
        _ layers: [LayerInput],
        operationID: String,
        faultInjector: FaultInjector? = nil
    ) throws -> RepairResult {
        try validateIdentifier(operationID)
        try validateLayerInputs(layers)
        return try withExclusiveLock {
            if pathEntryExists(maintenanceURL(operationID)) {
                var operation = try readMaintenance(operationID)
                guard operation.kind == .repair, operation.layers == layers.map(\.descriptor) else {
                    throw ContentLifecycleError.conflictingOperation(operationID)
                }
                try resumeMaintenance(&operation, faultInjector: faultInjector)
                return repairResult(operation)
            }
            try recoverMaintenanceUnlocked()
            guard try incompleteOperationsUnlocked().isEmpty else {
                throw ContentLifecycleError.pendingActivation("repair requires recovered activations")
            }
            let generations = try repairGenerations(for: layers.map(\.descriptor))
            var operation = MaintenanceOperation(
                operationID: operationID, kind: .repair,
                layers: layers.map(\.descriptor), generations: generations
            )
            try stageRepairInputs(layers, operationID: operationID)
            try writeMaintenance(operation)
            try faultInjector?("after-repair-journal")
            try resumeMaintenance(&operation, faultInjector: faultInjector)
            return repairResult(operation)
        }
    }

    func repairResult(_ operation: MaintenanceOperation) -> RepairResult {
        RepairResult(
            objectCount: Set(operation.layers.map(\.digest)).count,
            generationCount: operation.generations.count
        )
    }

    func stageRepairInputs(_ layers: [LayerInput], operationID: String) throws {
        let directory = repairPayloadDirectory(operationID)
        if pathEntryExists(directory), !isDirectory(directory) {
            throw ContentStoreError.unsafeStoreEntry(directory.path)
        }
        try requireSafeDirectory(directory, create: true)
        for layer in layers {
            let url = try repairPayloadURL(layer.descriptor, operationID: operationID)
            if pathEntryExists(url), !isRegularFile(url) {
                throw ContentStoreError.unsafeStoreEntry(url.path)
            }
            // Before the intent exists, an interrupted payload write may have
            // left a partial file. The caller's verified bytes replace it.
            try writeAtomic(layer.contents, to: url)
        }
        try syncDirectory(directory)
        try syncDirectory(directory.deletingLastPathComponent())
    }

    func resumeRepair(
        _ operation: inout MaintenanceOperation, faultInjector: FaultInjector?
    ) throws {
        if operation.state == .prepared {
            for descriptor in operation.layers {
                try repairCASObject(
                    descriptor, operationID: operation.operationID, faultInjector: faultInjector
                )
                try faultInjector?("after-repair-cas-item")
            }
            for generation in operation.generations {
                try repairGeneration(generation, operation: operation, faultInjector: faultInjector)
            }
            _ = try synchronizeCatalogUnlocked(faultInjector: nil)
            try faultInjector?("after-repair-validation")
            operation.state = .applied
            try writeMaintenance(operation)
            try faultInjector?("after-repair-applied")
        }
        let directory = repairPayloadDirectory(operation.operationID)
        if pathEntryExists(directory) {
            guard isDirectory(directory) else {
                throw ContentStoreError.unsafeStoreEntry(directory.path)
            }
            try fileManager.removeItem(at: directory)
            try syncDirectory(directory.deletingLastPathComponent())
        }
        try faultInjector?("after-repair-cleanup")
        operation.state = .complete
        try writeMaintenance(operation)
        try faultInjector?("after-repair-complete")
    }

    func repairCASObject(
        _ descriptor: LayerDescriptor, operationID: String, faultInjector: FaultInjector?
    ) throws {
        let destination = try objectURL(descriptor.digest)
        try requireSafeDirectory(destination.deletingLastPathComponent(), create: true)
        if pathEntryExists(destination), !isRegularFile(destination) {
            throw ContentStoreError.unsafeStoreEntry(destination.path)
        }
        if (try? validateObject(descriptor)) == nil {
            let source = try repairPayloadURL(descriptor, operationID: operationID)
            try verifyRepairPayload(descriptor, at: source)
            let temporary = source.deletingLastPathComponent().appendingPathComponent(
                "published-\(source.lastPathComponent)"
            )
            if pathEntryExists(temporary) {
                guard isRegularFile(temporary) else {
                    throw ContentStoreError.unsafeStoreEntry(temporary.path)
                }
                try fileManager.removeItem(at: temporary)
            }
            guard link(source.path, temporary.path) == 0 else {
                throw ContentStoreError.systemCall(operation: "stage repaired CAS object", code: errno)
            }
            try syncDirectory(temporary.deletingLastPathComponent())
            try faultInjector?("after-repair-cas-stage")
            guard rename(temporary.path, destination.path) == 0 else {
                throw ContentStoreError.systemCall(operation: "publish repaired CAS object", code: errno)
            }
            try syncDirectory(destination.deletingLastPathComponent())
            try syncDirectory(temporary.deletingLastPathComponent())
        }
        guard chmod(destination.path, S_IRUSR | S_IRGRP | S_IROTH) == 0 else {
            throw ContentStoreError.systemCall(operation: "seal repaired CAS object", code: errno)
        }
        try syncFile(destination)
        try validateObject(descriptor)
    }

    func repairGeneration(
        _ generation: RepairGeneration,
        operation: MaintenanceOperation,
        faultInjector: FaultInjector?
    ) throws {
        let directory = generationURL(
            gameID: generation.gameID, generationID: generation.reference.generationID
        )
        let manifest = try repairManifest(at: directory, gameID: generation.gameID)
        guard Self.digest(try Data(contentsOf: directory.appendingPathComponent("manifest.json")))
                == generation.reference.manifestDigest else {
            throw ContentLifecycleError.changedGeneration(generation.reference.generationID)
        }
        let digests = Set(operation.layers.map(\.digest))
        let layerDirectory = directory.appendingPathComponent("layers", isDirectory: true)
        try requireSafeDirectory(layerDirectory)
        guard chmod(layerDirectory.path, S_IRWXU) == 0 else {
            throw ContentStoreError.systemCall(operation: "open repaired generation directory", code: errno)
        }
        defer { _ = chmod(layerDirectory.path, S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) }
        for (index, descriptor) in manifest.layers.enumerated() where digests.contains(descriptor.digest) {
            try replaceRepairLink(
                descriptor, index: index, directory: directory,
                operationID: operation.operationID, faultInjector: faultInjector
            )
            try faultInjector?("after-repair-layer-item")
        }
        guard chmod(layerDirectory.path, S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) == 0 else {
            throw ContentStoreError.systemCall(operation: "seal repaired generation directory", code: errno)
        }
        try syncDirectory(layerDirectory)
        try validateReference(generation.reference, gameID: generation.gameID)
    }

    func replaceRepairLink(
        _ descriptor: LayerDescriptor, index: Int, directory: URL, operationID: String,
        faultInjector: FaultInjector?
    ) throws {
        let destination = try materializedLayerURL(descriptor, index: index, generationDirectory: directory)
        if pathEntryExists(destination), !isRegularFile(destination) {
            throw ContentStoreError.unsafeStoreEntry(destination.path)
        }
        if (try? validateMaterializedLayer(descriptor, index: index, generationDirectory: directory)) != nil {
            return
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(operationID).repair"
        )
        if pathEntryExists(temporary) {
            guard isRegularFile(temporary) else {
                throw ContentStoreError.unsafeStoreEntry(temporary.path)
            }
            try fileManager.removeItem(at: temporary)
        }
        let source = try objectURL(descriptor.digest)
        guard link(source.path, temporary.path) == 0 else {
            throw ContentStoreError.systemCall(operation: "link repaired generation layer", code: errno)
        }
        try syncDirectory(temporary.deletingLastPathComponent())
        try faultInjector?("after-repair-layer-stage")
        guard rename(temporary.path, destination.path) == 0 else {
            throw ContentStoreError.systemCall(operation: "publish repaired generation layer", code: errno)
        }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    func verifyRepairPayload(_ descriptor: LayerDescriptor, at url: URL) throws {
        guard isRegularFile(url) else {
            throw ContentLifecycleError.missingRepairPayload(descriptor.digest)
        }
        let data = try Data(contentsOf: url)
        guard data.count == descriptor.size, Self.digest(data) == descriptor.digest else {
            throw ContentStoreError.corruptObject(descriptor.digest)
        }
    }

    func repairPayloadDirectory(_ operationID: String) -> URL {
        root.appendingPathComponent("metadata/repair-payloads", isDirectory: true)
            .appendingPathComponent(operationID, isDirectory: true)
    }

    func repairPayloadURL(_ descriptor: LayerDescriptor, operationID: String) throws -> URL {
        try repairPayloadDirectory(operationID).appendingPathComponent(rawSHA256(descriptor.digest))
    }

    func requireSafeDirectory(_ url: URL, create: Bool = false) throws {
        let rootComponents = root.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents), isDirectory(root) else {
            throw ContentStoreError.unsafeStoreEntry(url.path)
        }
        var current = root
        for component in components.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            if create, !pathEntryExists(current) { try createDirectory(current) }
            guard isDirectory(current) else {
                throw ContentStoreError.unsafeStoreEntry(current.path)
            }
        }
    }
}
