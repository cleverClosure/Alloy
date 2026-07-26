// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private struct FixtureModeManifest: Decodable {
    let author: String
    let schemaVersion: String
    let entries: [FixtureModeEntry]
}

private struct FixtureModeEntry: Decodable {
    let path: String
    let mode: String
}

private enum CompatibilityFixtureError: Error {
    case invalidModeManifest
    case systemCall(String, Int32)
}

private func compatibilityFixturesDirectoryURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
}

private func compatibilityFixtureURL() -> URL {
    compatibilityFixturesDirectoryURL()
        .appendingPathComponent("main-21136e4-store", isDirectory: true)
}

private func restoreAndValidateFixtureModes(root: URL) throws {
    let manifestURL = compatibilityFixturesDirectoryURL()
        .appendingPathComponent("main-21136e4-modes.json")
    let manifest = try JSONDecoder().decode(
        FixtureModeManifest.self,
        from: Data(contentsOf: manifestURL)
    )
    guard manifest.author == "Timur Isaev",
          manifest.schemaVersion == "1.0" else {
        throw CompatibilityFixtureError.invalidModeManifest
    }

    for entry in manifest.entries {
        guard let expectedMode = Int(entry.mode, radix: 8) else {
            throw CompatibilityFixtureError.invalidModeManifest
        }
        let url = root.appendingPathComponent(entry.path)
        guard chmod(url.path, mode_t(expectedMode)) == 0 else {
            throw CompatibilityFixtureError.systemCall("chmod \(entry.path)", errno)
        }
        var information = stat()
        guard lstat(url.path, &information) == 0,
              Int(information.st_mode & 0o777) == expectedMode else {
            throw CompatibilityFixtureError.invalidModeManifest
        }
    }
}

private func withCompatibilityFixture(
    _ body: (URL, ContentStore) throws -> Void
) throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-content-store-compatibility-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    let root = container.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: compatibilityFixtureURL(), to: root)
    try restoreAndValidateFixtureModes(root: root)
    defer {
        let enumerator = FileManager.default.enumerator(
            at: container,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            chmod(url.path, S_IRWXU)
        }
        chmod(container.path, S_IRWXU)
        try? FileManager.default.removeItem(at: container)
    }
    try body(root, ContentStore(root: root))
}

private func compatibilityCatalogInventory(
    leaseCount: Int
) -> CatalogInventory {
    CatalogInventory(
        objectCount: 3,
        objectBytes: 65,
        objectReferenceCount: 4,
        generationCount: 2,
        referenceCount: 2,
        leaseCount: leaseCount
    )
}

@Test("current-main fixture opens with a v3 catalog without source migration")
func currentMainFixtureIsBackwardCompatible() throws {
    try withCompatibilityFixture { root, store in
        #expect(store.isRegularFile(store.catalogURL))
        #expect(try store.catalogConsistencyReport() == .consistent)
        #expect(try store.catalogInventory() == compatibilityCatalogInventory(leaseCount: 0))
        let openTimeDump = try store.canonicalCatalogDump()

        try store.recoverAll()
        #expect(try store.catalogConsistencyReport() == .consistent)
        #expect(try store.canonicalCatalogDump() == openTimeDump)
        let inspection = try store.inspect(gameID: "fixture-game")
        let active = try #require(inspection.active)
        let rollback = try #require(inspection.rollback)

        #expect(active.generationID == "generation-b")
        #expect(rollback.generationID == "generation-a")
        #expect(inspection.candidate == nil)
        #expect(inspection.objectCount == 3)
        #expect(inspection.incompleteOperationCount == 0)
        #expect(try store.readSave(
            gameID: "fixture-game",
            name: "compatibility.sav"
        ) == Data("save-sentinel-main-21136e4".utf8))
        try store.validateReference(active, gameID: "fixture-game")
        try store.validateReference(rollback, gameID: "fixture-game")

        let manifestURL = root
            .appendingPathComponent("generations/fixture-game/generation-b/manifest.json")
        let manifest = try JSONDecoder().decode(
            GenerationManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let plan = try store.preflightDiskSpace(for: manifest.layers)
        #expect(plan.additionalBytesRequired == 0)
        #expect(plan.presentObjectCount == 2)
        #expect(try store.estimateGarbageCollectionReclaim().totalBytes == 0)

        let lease = try store.acquireLease(
            gameID: "fixture-game",
            generation: active
        )
        #expect(lease.objectDigests.count == 2)
        #expect(try store.catalogConsistencyReport() == .consistent)
        #expect(try store.catalogInventory() == compatibilityCatalogInventory(leaseCount: 1))
        #expect(try store.collectGarbage() == .zero)
        try store.releaseLease(lease)
        #expect(try store.catalogConsistencyReport() == .consistent)
        #expect(try store.catalogInventory() == compatibilityCatalogInventory(leaseCount: 0))
        #expect(try store.collectGarbage() == .zero)
    }
}
