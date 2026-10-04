// Author: Timur Isaev
import AlloyContentStore
import AlloyStoreCatalog
import Foundation
import Testing

@Suite(.serialized)
struct StorageTests {
    // The single scenario follows one lease across six real activations and three GC passes.
    // swiftlint:disable:next function_body_length
    @Test func inventoryAndGCMatchIndependentDiskCountsAndKeepLeases() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeEngine(root)
        let store = try ContentStore(root: engine.contentRoot)
        for index in 0..<4 {
            let bytes = Data("generation-\(index)\n".utf8)
            let descriptor = LayerDescriptor(
                name: "runtime", version: String(index), digest: ContentStore.digest(bytes),
                mediaType: "application/octet-stream", size: bytes.count, role: .hostRuntime)
            _ = try store.activate(gameID: "fixture", generationID: "generation-\(index)",
                                   layers: [LayerInput(descriptor: descriptor, contents: bytes)])
        }
        let leased = try store.acquireLease(gameID: "fixture")
        // Hold generation 3 while two newer activations make it otherwise unrooted.
        for index in 4..<6 {
            let bytes = Data("generation-\(index)\n".utf8)
            let descriptor = LayerDescriptor(
                name: "runtime", version: String(index), digest: ContentStore.digest(bytes),
                mediaType: "application/octet-stream", size: bytes.count, role: .hostRuntime)
            _ = try store.activate(gameID: "fixture", generationID: "generation-\(index)",
                                   layers: [LayerInput(descriptor: descriptor, contents: bytes)])
        }
        let expected = Dictionary(uniqueKeysWithValues: (0..<6).map { index in
            let bytes = Data("generation-\(index)\n".utf8)
            return (ContentStore.digest(bytes), bytes)
        })
        let before = try objectFiles(engine.contentRoot)
        #expect(before == expected)
        #expect(before.count == 6)
        let request = try engine.getStorageInventory(idempotencyKey: "inventory")
        let observed = try engine.run(request.operationID)
        let inventory = try JSONDecoder().decode(StorageInventory.self, from: #require(observed.result))
        #expect(inventory.objectCount == before.count)
        #expect(inventory.objectBytes == UInt64(before.values.reduce(0) { $0 + $1.count }))
        let collection = try engine.collectGarbage(idempotencyKey: "gc")
        let finished = try engine.run(collection.operationID)
        let report = try JSONDecoder().decode(GarbageCollectionReport.self, from: #require(finished.result))
        let after = try objectFiles(engine.contentRoot)
        let removed = Set(before.keys).subtracting(after.keys)
        #expect(report.removedObjectDigests == removed.sorted())
        #expect(removed == Set((0..<3).map { ContentStore.digest(Data("generation-\($0)\n".utf8)) }))
        for (digest, bytes) in after { #expect(before[digest] == bytes) }
        #expect(report.removedObjectBytes == UInt64(removed.reduce(0) { $0 + (before[$1]?.count ?? 0) }))
        #expect(report.after.objectCount == 3)
        let clean = try engine.collectGarbage(idempotencyKey: "gc-clean")
        let cleanResult = try JSONDecoder().decode(GarbageCollectionReport.self,
                                                   from: #require(engine.run(clean.operationID).result))
        #expect(cleanResult.removedObjectDigests.isEmpty)
        #expect(try objectFiles(engine.contentRoot) == after)
        try store.releaseLease(leased)
        let unleased = try engine.collectGarbage(idempotencyKey: "gc-unleased")
        _ = try engine.run(unleased.operationID)
        #expect(try objectFiles(engine.contentRoot).count == 2)
    }

    @Test(arguments: ["COLLECTING.action-complete", "CONTENT_STORE.after-gc-object-sweep-item"])
    func interruptedGCReportsOriginalBeforeAndAfter(pointToStop: String) throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = try makeEngine(root)
        let store = try ContentStore(root: normal.contentRoot)
        for index in 0..<4 {
            let bytes = Data("gc-recovery-\(index)".utf8)
            let descriptor = LayerDescriptor(name: "runtime", version: String(index),
                                             digest: ContentStore.digest(bytes), mediaType: "application/octet-stream",
                                             size: bytes.count, role: .hostRuntime)
            _ = try store.activate(gameID: "fixture", generationID: "generation-\(index)",
                                   layers: [LayerInput(descriptor: descriptor, contents: bytes)])
        }
        let queued = try normal.collectGarbage(idempotencyKey: "interrupted")
        let interrupted = try makeEngine(root) { point in
            if point == pointToStop { throw StorageInterruption.stopped }
        }
        #expect(throws: StorageInterruption.stopped) { try interrupted.run(queued.operationID) }
        #expect(try normal.journal.get(queued.operationID).state == .running)
        let final = try makeEngine(root).run(queued.operationID)
        let report = try JSONDecoder().decode(GarbageCollectionReport.self, from: #require(final.result))
        #expect(report.before.objectCount == 4)
        #expect(report.after.objectCount == 2)
        #expect(report.removedObjectDigests == (0..<2).map {
            ContentStore.digest(Data("gc-recovery-\($0)".utf8))
        }.sorted())
        #expect(report.lastPass.objectsRemoved == (pointToStop == "COLLECTING.action-complete" ? 0 : 1))
        let bytes = try treeBytes(root)
        #expect(try normal.collectGarbage(idempotencyKey: "interrupted") == final)
        #expect(try treeBytes(root) == bytes)
    }

}

func objectFiles(_ root: URL) throws -> [String: Data] {
    let objects = root.appendingPathComponent("objects/sha256")
    let files = try treeBytes(objects)
    var result: [String: Data] = [:]
    for (path, bytes) in files {
        let components = path.split(separator: "/").suffix(2)
        #expect(components.first?.count == 2 && components.last?.count == 62)
        let digest = "sha256:" + components.joined()
        result[digest] = bytes
    }
    return result
}

private enum StorageInterruption: Error { case stopped }
