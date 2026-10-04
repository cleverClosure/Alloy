// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private func lifecycleLayer(_ text: String) -> LayerInput {
    let data = Data(text.utf8)
    return LayerInput(descriptor: LayerDescriptor(
        name: "runtime", version: "1", digest: ContentStore.digest(data),
        mediaType: "application/vnd.alloy.test-layer", size: data.count, role: .hostRuntime
    ), contents: data)
}

private func withLifecycleStore(_ body: (URL, ContentStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-lifecycle-\(UUID())")
    defer {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { chmod(url.path, S_IRWXU) }
        }
        try? FileManager.default.removeItem(at: root)
    }
    try body(root, ContentStore(root: root))
}

private func lifecycleFault(_ point: String) -> FaultInjector {
    { observed in
        if observed == point { throw ContentStoreError.injectedTermination(point) }
    }
}

private func corruptLifecycleObject(_ store: ContentStore, input: LayerInput) throws {
    let url = try store.objectURL(input.descriptor.digest)
    #expect(chmod(url.path, S_IRUSR | S_IWUSR) == 0)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var corrupt = input.contents
    corrupt[0] ^= 1
    try handle.write(contentsOf: corrupt)
    try handle.synchronize()
}

@Test("stable activation retry preserves original rollback at every activation boundary",
      arguments: ContentStore.faultPoints)
func lifecycleActivationReplay(point: String) throws {
    try withLifecycleStore { root, store in
        let old = try store.activate(gameID: "game", generationID: "a", layers: [lifecycleLayer("old")])
        let next = lifecycleLayer("new")
        #expect(throws: ContentStoreError.injectedTermination(point)) {
            try store.activate(
                gameID: "game", generationID: "b", layers: [next], operationID: "stable",
                faultInjector: lifecycleFault(point)
            )
        }
        let reopened = try ContentStore(root: root)
        let result = try reopened.activate(
            gameID: "game", generationID: "b", layers: [next], operationID: "stable"
        )
        #expect(result.generationID == "b")
        #expect(try reopened.inspect(gameID: "game").rollback == old)
        let bytes = try Data(contentsOf: reopened.journalURL("stable"))
        _ = try reopened.activate(gameID: "game", generationID: "b", layers: [next], operationID: "stable")
        #expect(try Data(contentsOf: reopened.journalURL("stable")) == bytes)
        #expect(try reopened.inspect(gameID: "game").rollback == old)
    }
}

@Test("old activation replay returns historical result without rolling back later installs")
func lifecycleActivationHistoricalReplay() throws {
    try withLifecycleStore { _, store in
        let input = lifecycleLayer("first")
        let first = try store.activate(gameID: "game", generationID: "a", layers: [input], operationID: "first")
        _ = try store.activate(gameID: "game", generationID: "b", layers: [lifecycleLayer("second")])
        let snapshot = try store.referenceSnapshot(gameID: "game")
        #expect(try store.activate(
            gameID: "game", generationID: "a", layers: [input], operationID: "first"
        ) == first)
        #expect(try store.referenceSnapshot(gameID: "game") == snapshot)
        #expect(throws: ContentLifecycleError.conflictingOperation("first")) {
            try store.activate(gameID: "game", generationID: "a", layers: [lifecycleLayer("other")],
                               operationID: "first")
        }
    }
}

@Test("uninstall rejects stale plans and never replays against a subsequent installation")
func lifecycleUninstallStalePlan() throws {
    try withLifecycleStore { _, store in
        _ = try store.activate(gameID: "game", generationID: "a", layers: [lifecycleLayer("first")])
        let before = try store.referenceSnapshot(gameID: "game")
        _ = try store.activate(gameID: "game", generationID: "b", layers: [lifecycleLayer("second")])
        #expect(throws: ContentLifecycleError.staleReferences("game")) {
            try store.uninstall(gameID: "game", expectedReferences: before, operationID: "stale")
        }
        let expected = try store.referenceSnapshot(gameID: "game")
        try store.uninstall(gameID: "game", expectedReferences: expected, operationID: "remove")
        let later = try store.activate(gameID: "game", generationID: "c", layers: [lifecycleLayer("third")])
        try store.uninstall(gameID: "game", expectedReferences: expected, operationID: "remove")
        #expect(try store.inspect(gameID: "game").active == later)
    }
}

@Test("uninstall recovers every journal boundary and preserves live leased content and saves",
      arguments: ContentStore.uninstallFaultPoints)
func lifecycleUninstallRecovery(point: String) throws {
    try withLifecycleStore { root, store in
        let input = lifecycleLayer("leased runtime")
        _ = try store.activate(gameID: "game", generationID: "a", layers: [input])
        let lease = try store.acquireLease(gameID: "game")
        let sentinel = Data("save sentinel".utf8)
        try store.writeSave(gameID: "game", name: "save", data: sentinel)
        let expected = try store.referenceSnapshot(gameID: "game")
        #expect(throws: ContentStoreError.injectedTermination(point)) {
            try store.uninstall(gameID: "game", expectedReferences: expected,
                                operationID: "remove", faultInjector: lifecycleFault(point))
        }
        let reopened = try ContentStore(root: root)
        #expect(try reopened.inspect(gameID: "game").active == nil)
        #expect(try reopened.collectGarbage().objectsRemoved == 0)
        #expect(try reopened.readSave(gameID: "game", name: "save") == sentinel)
        #expect(try Data(contentsOf: reopened.objectURL(input.descriptor.digest)) == input.contents)
        try reopened.releaseLease(lease)
        #expect(try reopened.collectGarbage().objectsRemoved == 1)
    }
}

@Test("repair restores CAS and all corrupt materialized hard links at every journal boundary",
      arguments: ContentStore.repairFaultPoints)
func lifecycleRepairRecovery(point: String) throws {
    try withLifecycleStore { root, store in
        let input = lifecycleLayer("shared immutable runtime")
        let first = try store.activate(gameID: "game", generationID: "a", layers: [input])
        let second = try store.activate(gameID: "game", generationID: "b", layers: [input])
        let lease = try store.acquireLease(gameID: "game")
        let snapshot = try store.referenceSnapshot(gameID: "game")
        try corruptLifecycleObject(store, input: input)
        #expect(throws: ContentStoreError.self) { try ContentStore(root: root) }
        #expect(throws: ContentStoreError.self) { try store.validateReference(first, gameID: "game") }
        let repair = try ContentStore(root: root, allowDamagedCatalog: true)
        #expect(throws: ContentStoreError.injectedTermination(point)) {
            try repair.repairObjects([input], operationID: "repair", faultInjector: lifecycleFault(point))
        }
        let reopened = try ContentStore(root: root)
        try reopened.validateReference(first, gameID: "game")
        try reopened.validateReference(second, gameID: "game")
        #expect(try reopened.referenceSnapshot(gameID: "game") == snapshot)
        #expect(try reopened.liveLeases() == [lease])
        #expect(try reopened.catalogConsistencyReport().isConsistent)
        #expect(!reopened.pathEntryExists(reopened.repairPayloadDirectory("repair")))
        let result = try reopened.repairObjects([input], operationID: "repair")
        #expect(result.objectCount == 1)
        #expect(result.generationCount == 2)
        try reopened.releaseLease(lease)
    }
}

@Test("repair rejects an altered manifest rather than trusting its new self-computed digest")
func lifecycleRepairRejectsChangedManifest() throws {
    try withLifecycleStore { _, store in
        let input = lifecycleLayer("runtime")
        _ = try store.activate(gameID: "game", generationID: "a", layers: [input])
        let url = store.generationURL(gameID: "game", generationID: "a").appendingPathComponent("manifest.json")
        #expect(chmod(url.path, S_IRUSR | S_IWUSR) == 0)
        let data = try Data(contentsOf: url)
        try (data + Data(" ".utf8)).write(to: url)
        #expect(throws: ContentLifecycleError.changedGeneration("a")) {
            try store.repairObjects([input], operationID: "repair")
        }
        #expect(!store.pathEntryExists(store.maintenanceURL("repair")))
    }
}

@Test("repair refuses a symlinked layer without changing its external target")
func lifecycleRepairRejectsSymlink() throws {
    try withLifecycleStore { root, store in
        let input = lifecycleLayer("runtime")
        _ = try store.activate(gameID: "game", generationID: "a", layers: [input])
        let directory = store.generationURL(gameID: "game", generationID: "a")
        let url = try store.materializedLayerURL(input.descriptor, index: 0, generationDirectory: directory)
        let external = root.appendingPathComponent("sentinel")
        let sentinel = Data("outside layer".utf8)
        try sentinel.write(to: external)
        #expect(chmod(url.deletingLastPathComponent().path, S_IRWXU) == 0)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: external)
        #expect(throws: ContentStoreError.self) {
            try store.repairObjects([input], operationID: "repair")
        }
        #expect(try Data(contentsOf: external) == sentinel)
    }
}

@Test("repair retries partial staging left before its intent journal existed")
func lifecycleRepairPartialStaging() throws {
    try withLifecycleStore { _, store in
        let input = lifecycleLayer("runtime")
        let reference = try store.activate(gameID: "game", generationID: "a", layers: [input])
        try corruptLifecycleObject(store, input: input)
        let payload = try store.repairPayloadURL(input.descriptor, operationID: "repair")
        try store.createDirectory(payload.deletingLastPathComponent())
        try Data("partial".utf8).write(to: payload)
        try store.repairObjects([input], operationID: "repair")
        try store.validateReference(reference, gameID: "game")
        #expect(!store.pathEntryExists(store.repairPayloadDirectory("repair")))
    }
}

@Test("repair may inspect validated reference metadata while active bytes are corrupt")
func lifecycleRepairMetadataSnapshot() throws {
    try withLifecycleStore { root, store in
        let input = lifecycleLayer("runtime")
        _ = try store.activate(gameID: "game", generationID: "a", layers: [input])
        let expected = try store.referenceSnapshot(gameID: "game")
        try corruptLifecycleObject(store, input: input)
        let damaged = try ContentStore(root: root, allowDamagedCatalog: true)
        #expect(throws: ContentStoreError.self) { try damaged.referenceSnapshot(gameID: "game") }
        #expect(try damaged.referenceSnapshot(gameID: "game", validateContents: false) == expected)
        try store.writeAtomic(Data("{\"generationId\":\"../bad\",\"manifestDigest\":\"sha256:bad\"}".utf8),
                              to: store.referenceURL(.active, gameID: "game"))
        #expect(throws: ContentStoreError.self) {
            try damaged.referenceSnapshot(gameID: "game", validateContents: false)
        }
    }
}
