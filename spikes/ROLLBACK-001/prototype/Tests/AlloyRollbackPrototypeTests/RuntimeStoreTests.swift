// Author: Timur Isaev

import Foundation
import Darwin
import Testing

@testable import AlloyRollbackPrototype

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-rollback-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func withStore(
    _ body: (URL, RuntimeStore) throws -> Void
) throws {
    let root = try temporaryRoot()
    defer {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            chmod(url.path, S_IRWXU)
        }
        chmod(root.path, S_IRWXU)
        try? FileManager.default.removeItem(at: root)
    }
    try body(root, RuntimeStore(root: root))
}

@Test("successful update preserves rollback and save")
func successfulUpdatePreservesRollbackAndSave() throws {
    try withStore { _, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            payload: Data("payload-a".utf8)
        )
        try store.writeSave(gameID: "game", name: "save.bin", data: Data("save-v1".utf8))

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            payload: Data("payload-b".utf8)
        )

        let inspection = try store.inspect(gameID: "game")
        #expect(inspection.active?.generationID == "generation-b")
        #expect(inspection.rollback?.generationID == "generation-a")
        #expect(inspection.candidate == nil)
        #expect(inspection.objectCount == 2)
        #expect(inspection.incompleteOperationCount == 0)
        #expect(try store.readSave(gameID: "game", name: "save.bin") == Data("save-v1".utf8))
    }
}

@Test("failed health window restores previous generation")
func failedHealthWindowRestoresPreviousGeneration() throws {
    try withStore { _, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            payload: Data("payload-a".utf8)
        )
        try store.writeSave(gameID: "game", name: "save.bin", data: Data("save-v1".utf8))

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            payload: Data("payload-b".utf8),
            healthOutcome: .fail
        )

        let inspection = try store.inspect(gameID: "game")
        #expect(inspection.active?.generationID == "generation-a")
        #expect(inspection.rollback?.generationID == "generation-a")
        #expect(inspection.candidate == nil)
        #expect(try store.readSave(gameID: "game", name: "save.bin") == Data("save-v1".utf8))
    }
}

@Test("duplicate payload shares one CAS object")
func duplicatePayloadSharesOneObject() throws {
    try withStore { _, store in
        let payload = Data("shared-payload".utf8)
        _ = try store.activate(gameID: "game", generationID: "generation-a", payload: payload)
        _ = try store.activate(gameID: "game", generationID: "generation-b", payload: payload)

        let inspection = try store.inspect(gameID: "game")
        #expect(inspection.objectCount == 1)
        #expect(inspection.active?.generationID == "generation-b")
    }
}

@Test("digest mismatch cannot activate")
func digestMismatchCannotActivate() throws {
    try withStore { _, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            payload: Data("payload-a".utf8)
        )

        #expect(throws: RuntimeStoreError.self) {
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-b",
                payload: Data("payload-b".utf8),
                expectedSHA256: String(repeating: "0", count: 64)
            )
        }
        #expect(try store.inspect(gameID: "game").active?.generationID == "generation-a")
    }
}

@Test("corrupt local object is quarantined before activation")
func corruptLocalObjectIsQuarantined() throws {
    try withStore { _, store in
        let payload = Data("payload-b".utf8)
        let digest = RuntimeStore.sha256(payload)
        let corruptObject = store.objectURL(digest)
        try store.createDirectory(corruptObject.deletingLastPathComponent())
        try Data("corrupt".utf8).write(to: corruptObject)

        _ = try store.activate(
            gameID: "game",
            generationID: "generation-b",
            payload: payload
        )

        let quarantine = try store.fileManager.contentsOfDirectory(
            at: store.quarantineDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(quarantine.count == 1)
        #expect(try store.inspect(gameID: "game").active?.generationID == "generation-b")
    }
}

@Test(
    "recovery is idempotent at every lifecycle boundary",
    arguments: RuntimeStore.faultPoints
)
func recoveryIsIdempotent(faultPoint: String) throws {
    try withStore { root, store in
        _ = try store.activate(
            gameID: "game",
            generationID: "generation-a",
            payload: Data("payload-a".utf8)
        )
        try store.writeSave(gameID: "game", name: "save.bin", data: Data("save-v1".utf8))

        #expect(throws: RuntimeStoreError.injectedTermination(faultPoint)) {
            _ = try store.activate(
                gameID: "game",
                generationID: "generation-b",
                payload: Data("payload-b".utf8),
                faultInjector: { point in
                    if point == faultPoint {
                        throw RuntimeStoreError.injectedTermination(point)
                    }
                }
            )
        }

        let recovered = try RuntimeStore(root: root)
        try recovered.recoverAll()
        try recovered.recoverAll()
        let inspection = try recovered.inspect(gameID: "game")
        #expect(inspection.active?.generationID == "generation-b")
        #expect(inspection.rollback?.generationID == "generation-a")
        #expect(inspection.candidate == nil)
        #expect(inspection.incompleteOperationCount == 0)
        #expect(try recovered.readSave(gameID: "game", name: "save.bin") == Data("save-v1".utf8))
    }
}

@Test("path traversal identifiers are rejected")
func pathTraversalIdentifiersAreRejected() throws {
    try withStore { _, store in
        #expect(throws: RuntimeStoreError.invalidIdentifier("../escape")) {
            _ = try store.activate(
                gameID: "../escape",
                generationID: "generation-a",
                payload: Data()
            )
        }
    }
}
