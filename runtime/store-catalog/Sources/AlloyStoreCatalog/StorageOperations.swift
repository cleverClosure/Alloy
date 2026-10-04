// Author: Timur Isaev
import AlloyContentStore
import Foundation

public typealias StorageInventory = CatalogInventory

public struct GarbageCollectionReport: Codable, Equatable, Sendable {
    public let before: StorageInventory
    public let after: StorageInventory
    public let removedObjectDigests: [String]
    public let removedObjectBytes: UInt64
    public let removedGenerations: [String]
    public let lastPass: GarbageCollectionResult
}

extension InstallationEngine {
    public func getStorageInventory(idempotencyKey: String) throws -> CatalogOperation {
        try journal.create(kind: .inventory, idempotencyKey: idempotencyKey, payload: ["accounting": "UNIQUE_CAS"])
    }

    public func collectGarbage(idempotencyKey: String) throws -> CatalogOperation {
        try journal.create(kind: .garbageCollection, idempotencyKey: idempotencyKey,
                           payload: ["policy": "CONTENT_STORE_REFERENCES_AND_LIVE_LEASES"])
    }

    func executeInventory(_ operation: CatalogOperation) throws -> CatalogOperation {
        _ = try journal.checkpoint(operation.operationID, stage: "INVENTORY", controllable: false)
        let inventory = try ContentStore(root: contentRoot).catalogInventory()
        try faultInjector?("INVENTORY.action-complete")
        return try journal.transition(operation.operationID, to: .succeeded, stage: "SUCCEEDED",
                                      result: StoreCatalog.encode(inventory), controllable: false)
    }

    func executeGarbageCollection(_ operation: CatalogOperation) throws -> CatalogOperation {
        let store = try ContentStore(root: contentRoot)
        let before: CatalogDump
        if let saved = operation.result {
            before = try JSONDecoder().decode(CatalogDump.self, from: saved)
        } else {
            before = try JSONDecoder().decode(CatalogDump.self, from: Data(store.canonicalCatalogDump().utf8))
            _ = try journal.checkpoint(operation.operationID, stage: "COLLECTING", controllable: false,
                                       interimResult: StoreCatalog.encode(before))
        }
        let pass = try store.collectGarbage { point in
            try self.faultInjector?("CONTENT_STORE." + point)
        }
        try faultInjector?("COLLECTING.action-complete")
        let after = try JSONDecoder().decode(CatalogDump.self, from: Data(store.canonicalCatalogDump().utf8))
        let current = Set(after.objects.map(\.digest))
        let removed = before.objects.filter { !current.contains($0.digest) }
        let generations = Set(after.generations.map { $0.gameID + "/" + $0.generationID })
        let removedGenerations = before.generations.map { $0.gameID + "/" + $0.generationID }
            .filter { !generations.contains($0) }.sorted()
        let report = GarbageCollectionReport(before: before.inventory, after: after.inventory,
                                               removedObjectDigests: removed.map(\.digest).sorted(),
                                               removedObjectBytes: removed.reduce(0) { $0 + UInt64($1.size) },
                                               removedGenerations: removedGenerations, lastPass: pass)
        return try journal.transition(operation.operationID, to: .succeeded, stage: "SUCCEEDED",
                                      result: StoreCatalog.encode(report), controllable: false)
    }
}
