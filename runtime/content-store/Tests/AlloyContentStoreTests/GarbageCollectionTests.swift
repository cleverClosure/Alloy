// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private func gcTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-content-store-gc-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func withGCStore(
    _ body: (URL, ContentStore) throws -> Void
) throws {
    let root = try gcTestRoot()
    defer {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            chmod(url.path, S_IRWXU)
        }
        chmod(root.path, S_IRWXU)
        try? FileManager.default.removeItem(at: root)
    }
    try body(root, ContentStore(root: root))
}

private func gcLayer(_ value: String) -> LayerInput {
    let data = Data(value.utf8)
    return LayerInput(
        descriptor: LayerDescriptor(
            name: "gc-test-runtime",
            version: value,
            digest: ContentStore.digest(data),
            mediaType: "application/vnd.alloy.test-layer",
            size: data.count,
            role: .hostRuntime
        ),
        contents: data
    )
}

@discardableResult
private func activateGCGeneration(
    _ store: ContentStore,
    gameID: String = "game",
    generationID: String
) throws -> GenerationReference {
    try store.activate(
        gameID: gameID,
        generationID: generationID,
        layers: [gcLayer("payload-\(gameID)-\(generationID)")]
    )
}

@Test("mark and sweep collects one unreachable generation and CAS object")
func garbageCollectionRemovesUnreachableState() throws {
    try withGCStore { _, store in
        _ = try activateGCGeneration(store, generationID: "generation-a")
        _ = try activateGCGeneration(store, generationID: "generation-b")
        _ = try activateGCGeneration(store, generationID: "generation-c")
        let abandonedDownload = store.downloadsDirectory
            .appendingPathComponent("abandoned", isDirectory: true)
        try store.createDirectory(abandonedDownload)
        try Data("download".utf8).write(
            to: abandonedDownload.appendingPathComponent("payload.part")
        )
        try Data("quarantine".utf8).write(
            to: store.quarantineDirectory.appendingPathComponent("orphan")
        )

        let result = try store.collectGarbage()

        #expect(result.generationsRemoved == 1)
        #expect(result.objectsRemoved == 1)
        #expect(result.downloadsRemoved == 1)
        #expect(result.quarantineEntriesRemoved == 1)
        #expect(result.bytesReclaimed > 0)
        #expect(!store.pathEntryExists(store.generationURL(
            gameID: "game",
            generationID: "generation-a"
        )))
        #expect(try store.inspect(gameID: "game").objectCount == 2)
        #expect(try store.inspect(gameID: "game").active?.generationID == "generation-c")
        #expect(try store.inspect(gameID: "game").rollback?.generationID == "generation-b")
    }
}

@Test("fully referenced store collects exactly zero")
func garbageCollectionFullyReferencedControl() throws {
    try withGCStore { _, store in
        _ = try activateGCGeneration(store, generationID: "generation-a")
        #expect(try store.collectGarbage() == .zero)
        #expect(try store.inspect(gameID: "game").objectCount == 1)
    }
}

@Test("active rollback candidate and every game are roots")
func everyReferenceAndGameIsRoot() throws {
    try withGCStore { _, store in
        let old = try activateGCGeneration(store, gameID: "game-one", generationID: "old")
        _ = try activateGCGeneration(store, gameID: "game-one", generationID: "rollback")
        _ = try activateGCGeneration(store, gameID: "game-one", generationID: "active")
        _ = try activateGCGeneration(store, gameID: "game-two", generationID: "active")
        try store.withExclusiveLock {
            try store.writeReference(old, kind: .candidate, gameID: "game-one")
        }

        #expect(try store.collectGarbage() == .zero)
        #expect(try store.inspect(gameID: "game-one").objectCount == 4)
        #expect(try store.inspect(gameID: "game-two").active?.generationID == "active")
    }
}

@Test("live lease remains a root after references advance")
func liveLeaseBlocksGarbageCollection() throws {
    try withGCStore { _, store in
        let old = try activateGCGeneration(store, generationID: "generation-a")
        let lease = try store.acquireLease(gameID: "game", generation: old)
        _ = try activateGCGeneration(store, generationID: "generation-b")
        _ = try activateGCGeneration(store, generationID: "generation-c")

        #expect(try store.collectGarbage() == .zero)
        try store.releaseLease(lease)
        let collected = try store.collectGarbage()
        #expect(collected.generationsRemoved == 1)
        #expect(collected.objectsRemoved == 1)
    }
}

@Test("a lease digest set must exactly match its generation manifest")
func malformedLeaseDigestSubsetFailsClosed() throws {
    try withGCStore { _, store in
        let leasedGeneration = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [gcLayer("leased-a"), gcLayer("leased-b")]
        )
        let lease = try store.acquireLease(
            gameID: "game",
            generation: leasedGeneration
        )
        _ = try activateGCGeneration(store, generationID: "generation-b")
        _ = try activateGCGeneration(store, generationID: "generation-c")

        let leaseURL = store.leaseURL(lease.leaseID)
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: leaseURL)
            ) as? [String: Any]
        )
        object["objectDigests"] = [try #require(lease.objectDigests.first)]
        try store.writeAtomic(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            to: leaseURL
        )

        #expect(throws: ContentStoreError.invalidLease(lease.leaseID)) {
            _ = try store.collectGarbage()
        }
        #expect(store.pathEntryExists(store.generationURL(
            gameID: "game",
            generationID: "generation-a"
        )))
        #expect(try store.inspect(gameID: "game").objectCount == 4)
    }
}

@Test("reachable dot-prefixed generation IDs are never mistaken for staging")
func reachableDotPrefixedGenerationSurvives() throws {
    try withGCStore { _, store in
        let reference = try activateGCGeneration(
            store,
            generationID: ".hidden-generation"
        )

        #expect(try store.collectGarbage() == .zero)
        try store.validateReference(reference, gameID: "game")
    }
}

@Test("collecting a hard-linked generation preserves every shared object mode")
func garbageCollectionPreservesSharedObjectModes() throws {
    try withGCStore { _, store in
        let shared = gcLayer("shared")
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            layers: [shared, gcLayer("unique-a")]
        )
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            layers: [shared, gcLayer("unique-b")]
        )
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-c",
            layers: [shared, gcLayer("unique-c")]
        )

        let objectURL = try store.objectURL(shared.descriptor.digest)
        let generationBURL = try store.materializedLayerURL(
            shared.descriptor,
            index: 0,
            generationDirectory: store.generationURL(
                gameID: "game",
                generationID: "generation-b"
            )
        )
        let generationCURL = try store.materializedLayerURL(
            shared.descriptor,
            index: 0,
            generationDirectory: store.generationURL(
                gameID: "game",
                generationID: "generation-c"
            )
        )

        let result = try store.collectGarbage()
        #expect(result.generationsRemoved == 1)
        for url in [objectURL, generationBURL, generationCURL] {
            let permissions = try #require(
                FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    as? NSNumber
            )
            #expect(permissions.intValue == 0o444)
        }
    }
}

@Test("generation symlink makes collection fail closed without following it")
func generationSymlinkIsNeverFollowed() throws {
    try withGCStore { root, store in
        _ = try activateGCGeneration(store, generationID: "generation-a")
        let external = root.appendingPathComponent("external", isDirectory: true)
        try store.createDirectory(external)
        let sentinel = external.appendingPathComponent("sentinel")
        try Data("do-not-touch".utf8).write(to: sentinel)
        let symlink = store.generationsDirectory
            .appendingPathComponent("game", isDirectory: true)
            .appendingPathComponent("unexpected-link")
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: external.path
        )

        #expect(throws: ContentStoreError.self) {
            _ = try store.collectGarbage()
        }
        #expect(try Data(contentsOf: sentinel) == Data("do-not-touch".utf8))
        #expect(store.pathEntryExists(symlink))
    }
}

@Test("unexpected CAS symlink makes collection fail closed")
func unexpectedCASSymlinkFailsClosed() throws {
    try withGCStore { root, store in
        _ = try activateGCGeneration(store, generationID: "generation-a")
        let target = root.appendingPathComponent("external-object")
        try Data("do-not-touch".utf8).write(to: target)
        let shard = store.objectsDirectory.appendingPathComponent("ff", isDirectory: true)
        try store.createDirectory(shard)
        let symlink = shard.appendingPathComponent(String(repeating: "0", count: 62))
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: target.path
        )

        #expect(throws: ContentStoreError.self) {
            _ = try store.collectGarbage()
        }
        #expect(try Data(contentsOf: target) == Data("do-not-touch".utf8))
        #expect(store.pathEntryExists(symlink))
    }
}

@Test(
    "garbage collection is restartable at every destructive boundary",
    arguments: ContentStore.garbageCollectionFaultPoints
)
func garbageCollectionFaultRecovery(faultPoint: String) throws {
    try withGCStore { _, store in
        _ = try activateGCGeneration(store, generationID: "generation-a")
        _ = try activateGCGeneration(store, generationID: "generation-b")
        _ = try activateGCGeneration(store, generationID: "generation-c")
        let abandoned = store.downloadsDirectory
            .appendingPathComponent("abandoned", isDirectory: true)
        try store.createDirectory(abandoned)
        try Data("download".utf8).write(to: abandoned.appendingPathComponent("part"))
        try Data("quarantine".utf8).write(
            to: store.quarantineDirectory.appendingPathComponent("orphan")
        )

        #expect(throws: ContentStoreError.injectedTermination(faultPoint)) {
            _ = try store.collectGarbage { point in
                if point == faultPoint {
                    throw ContentStoreError.injectedTermination(point)
                }
            }
        }

        let recovered = try ContentStore(root: store.root)
        _ = try recovered.collectGarbage()
        #expect(try recovered.collectGarbage() == .zero)
        #expect(try recovered.inspect(gameID: "game").active?.generationID == "generation-c")
        #expect(try recovered.inspect(gameID: "game").rollback?.generationID == "generation-b")
        #expect(try recovered.inspect(gameID: "game").objectCount == 2)
    }
}
