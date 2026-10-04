// Author: Timur Isaev
import AlloyContentStore
import Foundation

extension InstallationEngine {
    func executeInstall(_ operation: CatalogOperation) throws -> CatalogOperation {
        let plan = try JSONDecoder().decode(InstallPlan.self, from: operation.payload)
        let store = try ContentStore(root: contentRoot)
        let layers = try fetchLayers(plan, operation: operation, store: store)
        guard try journal.get(operation.operationID).state == .running else {
            return try journal.get(operation.operationID)
        }
        _ = try journal.checkpoint(operation.operationID, stage: "ACTIVATING", controllable: false)
        let reference = try store.activate(gameID: plan.gameID, generationID: plan.generationID,
                                           layers: layers, operationID: operation.operationID)
        guard reference.generationID == plan.generationID else { throw InstallationError.unexpectedGeneration }
        try store.validateReference(reference, gameID: plan.gameID)
        try faultInjector?("ACTIVATING.action-complete")
        return try journal.transition(operation.operationID, to: .succeeded, stage: "SUCCEEDED",
                                      result: StoreCatalog.encode(reference), controllable: false)
    }

    func executeUninstall(_ operation: CatalogOperation) throws -> CatalogOperation {
        let plan = try JSONDecoder().decode(UninstallPlan.self, from: operation.payload)
        _ = try journal.checkpoint(operation.operationID, stage: "UNINSTALLING", controllable: false)
        let references = try ContentStore(root: contentRoot).uninstall(
            gameID: plan.gameID, expectedReferences: plan.expectedReferences, operationID: operation.operationID)
        try faultInjector?("UNINSTALLING.action-complete")
        return try journal.transition(operation.operationID, to: .succeeded, stage: "SUCCEEDED",
                                      result: StoreCatalog.encode(references), controllable: false)
    }

    func executeRepair(_ operation: CatalogOperation) throws -> CatalogOperation {
        let plan = try JSONDecoder().decode(InstallPlan.self, from: operation.payload)
        let store = try ContentStore(root: contentRoot, allowDamagedCatalog: true)
        guard let active = try store.referenceSnapshot(gameID: plan.gameID, validateContents: false).active,
              active.generationID == plan.generationID else { throw InstallationError.unexpectedGeneration }
        if operation.canCancel, (try? store.validateReference(active, gameID: plan.gameID)) != nil {
            return try journal.transition(operation.operationID, to: .succeeded, stage: "SUCCEEDED",
                                          result: StoreCatalog.encode(["repairRequired": false]), controllable: false)
        }
        let staging = try ContentStore(root: root.appendingPathComponent("repair-downloads"))
        let layers = try fetchLayers(plan, operation: operation, store: staging)
        guard try journal.get(operation.operationID).state == .running else {
            return try journal.get(operation.operationID)
        }
        _ = try journal.checkpoint(operation.operationID, stage: "REPAIRING", controllable: false)
        let result = try store.repairObjects(layers, operationID: operation.operationID)
        try store.validateReference(active, gameID: plan.gameID)
        try faultInjector?("REPAIRING.action-complete")
        return try journal.transition(operation.operationID, to: .succeeded, stage: "SUCCEEDED",
                                      result: StoreCatalog.encode(result), controllable: false)
    }

    private func fetchLayers(
        _ plan: InstallPlan, operation: CatalogOperation, store: ContentStore
    ) throws -> [LayerInput] {
        var inputs: [LayerInput] = []
        var progress = OperationProgress()
        progress.totalUnits = UInt64(plan.layers.count)
        for descriptor in plan.layers {
            guard descriptor.size >= 0 else { throw InstallationError.corruptPlan(plan.planID) }
            let (total, overflow) = progress.bytesTotal.addingReportingOverflow(UInt64(descriptor.size))
            guard !overflow else { throw InstallationError.corruptPlan(plan.planID) }
            progress.bytesTotal = total
        }
        for (index, descriptor) in plan.layers.enumerated() {
            guard try journal.get(operation.operationID).state == .running else { return inputs }
            _ = try journal.checkpoint(operation.operationID, stage: "FETCHING_\(index)", progress: progress,
                                       controllable: operation.canCancel)
            let fetched = try store.fetchObject(descriptor, from: plan.baseURLs,
                                                operationID: operation.operationID + "-layer-\(index)")
            inputs.append(LayerInput(descriptor: descriptor, contents: try Data(contentsOf: fetched.objectURL)))
            progress.completedUnits += 1
            progress.bytesCompleted += UInt64(descriptor.size)
            try faultInjector?("FETCHING_\(index).action-complete")
        }
        if try journal.get(operation.operationID).state == .running {
            _ = try journal.checkpoint(operation.operationID, stage: "VERIFIED", progress: progress,
                                       controllable: operation.canCancel)
        }
        return inputs
    }
}
