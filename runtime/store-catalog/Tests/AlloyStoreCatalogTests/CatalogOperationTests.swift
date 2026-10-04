// Author: Timur Isaev
import AlloyContentStore
import AlloyStoreCatalog
import Foundation
import Testing

@Test func multipleLayerPauseResumesToExactManifestAndProgress() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let secondBytes = Data("second known layer".utf8)
    let second = LayerDescriptor(name: "wine", version: "1", digest: ContentStore.digest(secondBytes),
                                  mediaType: "application/octet-stream", size: secondBytes.count, role: .wineRuntime)
    let server = try LoopbackHTTPFixture { request in
        FixtureHTTPResponse(
            body: request.path.contains(String(second.digest.dropFirst(7))) ? secondBytes : runtimeBytes)
    }
    defer { server.stop() }
    let engine = try makeEngine(root) { point in
        if point == "FETCHING_0.action-complete" {
            let control = try makeEngine(root)
            let operation = try #require(control.journal.list().first)
            _ = try control.pauseOperation(operation.operationID)
        }
    }
    let plan = try engine.planInstall(gameID: "fixture", installationID: "fixture-install", generationID: "two-layers",
                                      layers: [runtimeDescriptor(), second], baseURLs: [server.baseURL])
    let queued = try engine.startInstall(planID: plan.planID, idempotencyKey: "two-layers")
    #expect(try engine.run(queued.operationID).state == .paused)
    let completed = try makeEngine(root).resumeOperation(queued.operationID)
    #expect(completed.state == .succeeded)
    #expect(completed.progress.totalUnits == 2 && completed.progress.completedUnits == 2)
    #expect(completed.progress.bytesCompleted == UInt64(runtimeBytes.count + secondBytes.count))
    let store = try ContentStore(root: engine.contentRoot)
    let reference = try #require(store.referenceSnapshot(gameID: "fixture").active)
    try store.validateReference(reference, gameID: "fixture")
}

@Test func discoveryAndRefreshAreDurableOperations() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try makeEngine(root)
    let library = packageRoot.appendingPathComponent("Tests/Fixtures/MultiGameLibrary")
    let request = try engine.discoverInstallations(libraryRoots: [library], idempotencyKey: "discover")
    let discovered = try engine.run(request.operationID)
    let installations = try JSONDecoder().decode([GameInstallation].self, from: #require(discovered.result))
    #expect(installations.count == 2)
    let identifier = try #require(installations.first?.installationID)
    let refresh = try engine.refreshBuildFingerprint(installationID: identifier,
                                                     libraryRoots: [library], idempotencyKey: "refresh")
    #expect(try engine.run(refresh.operationID).state == .succeeded)
    let bad = try engine.refreshBuildFingerprint(installationID: "missing",
                                                 libraryRoots: [library], idempotencyKey: "bad")
    #expect(try engine.run(bad.operationID).state == .failed)
}
