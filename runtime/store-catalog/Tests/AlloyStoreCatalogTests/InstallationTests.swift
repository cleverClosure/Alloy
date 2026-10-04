// Author: Timur Isaev
import AlloyContentStore
import AlloyStoreCatalog
import Foundation
import Testing

let runtimeBytes = Data("catalog synthetic runtime layer\n".utf8)

func runtimeDescriptor() -> LayerDescriptor {
    LayerDescriptor(name: "fixture", version: "1", digest: ContentStore.digest(runtimeBytes),
                    mediaType: "application/octet-stream", size: runtimeBytes.count, role: .hostRuntime)
}

func makeEngine(_ root: URL, fault: JournalFaultInjector? = nil) throws -> InstallationEngine {
    try InstallationEngine(root: root.appendingPathComponent("catalog"),
                           contentRoot: root.appendingPathComponent("content"), faultInjector: fault)
}

func makeInstall(_ engine: InstallationEngine, baseURL: URL) throws -> CatalogOperation {
    let plan = try engine.planInstall(gameID: "fixture", installationID: "fixture-install",
                                      generationID: "fixture-generation", layers: [runtimeDescriptor()],
                                      baseURLs: [baseURL])
    return try engine.startInstall(planID: plan.planID, idempotencyKey: "fixture-install")
}

@Suite(.serialized)
struct InstallationTests {
    @Test func installRepairUninstallAndExactReplay() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LoopbackHTTPFixture { _ in FixtureHTTPResponse(body: runtimeBytes) }
        defer { server.stop() }
        let engine = try makeEngine(root)
        let queued = try makeInstall(engine, baseURL: server.baseURL)
        #expect(queued.state == .queued)
        let installed = try engine.run(queued.operationID)
        #expect(installed.state == .succeeded)
        let before = try treeBytes(root)
        #expect(try makeInstall(engine, baseURL: server.baseURL) == installed)
        #expect(try treeBytes(root) == before)
        let store = try ContentStore(root: engine.contentRoot)
        let active = try #require(store.referenceSnapshot(gameID: "fixture").active)
        try store.validateReference(active, gameID: "fixture")
        let hash = String(runtimeDescriptor().digest.dropFirst(7))
        let object = engine.contentRoot.appendingPathComponent("objects/sha256/\(hash.prefix(2))/\(hash.dropFirst(2))")
        // Mutating the inode also corrupts the materialized hard link.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: object.path)
        let writer = try FileHandle(forWritingTo: object)
        try writer.write(contentsOf: Data(repeating: 88, count: runtimeBytes.count))
        try writer.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: object.path)
        #expect(throws: (any Error).self) { try store.validateReference(active, gameID: "fixture") }
        let repair = try engine.repairInstallation("fixture-install", idempotencyKey: "repair")
        #expect(try engine.run(repair.operationID).state == .succeeded)
        try ContentStore(root: engine.contentRoot).validateReference(active, gameID: "fixture")
        #expect(try Data(contentsOf: object) == runtimeBytes)
        let plan = try engine.planUninstall(gameID: "fixture", installationID: "fixture-install")
        let uninstall = try engine.startUninstall(planID: plan.planID, idempotencyKey: "uninstall")
        let removed = try engine.run(uninstall.operationID)
        #expect(removed.state == .succeeded)
        #expect(try ContentStore(root: engine.contentRoot).referenceSnapshot(gameID: "fixture").active == nil)
        let after = try treeBytes(root)
        #expect(try engine.startUninstall(planID: plan.planID, idempotencyKey: "uninstall") == removed)
        #expect(try treeBytes(root) == after)
    }

    @Test func cooperativePauseResumeAndCancelHaveRealControls() throws {
        let server = try LoopbackHTTPFixture { _ in FixtureHTTPResponse(body: runtimeBytes) }
        defer { server.stop() }
        for action in ["pause", "cancel"] {
            let root = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let engine = try makeEngine(root) { point in
                if point == "FETCHING_0.action-complete" {
                    let control = try makeEngine(root)
                    let operation = try #require(control.journal.list().first)
                    if action == "pause" {
                        _ = try control.pauseOperation(operation.operationID)
                    } else {
                        _ = try control.cancelOperation(operation.operationID)
                    }
                }
            }
            let queued = try makeInstall(engine, baseURL: server.baseURL)
            let controlled = try engine.run(queued.operationID)
            #expect(controlled.state == (action == "pause" ? .paused : .cancelled))
            #expect(try ContentStore(root: engine.contentRoot).referenceSnapshot(gameID: "fixture").active == nil)
            if action == "pause" {
                #expect(try makeEngine(root).resumeOperation(queued.operationID).state == .succeeded)
            } else {
                #expect(try engine.run(queued.operationID).state == .cancelled)
            }
        }
    }

    @Test func staleUninstallFailsWithoutRemovingNewerInstall() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LoopbackHTTPFixture { _ in FixtureHTTPResponse(body: runtimeBytes) }
        defer { server.stop() }
        let engine = try makeEngine(root)
        _ = try engine.run(makeInstall(engine, baseURL: server.baseURL).operationID)
        let plan = try engine.planUninstall(gameID: "fixture", installationID: "fixture-install")
        let store = try ContentStore(root: engine.contentRoot)
        let newer = try store.activate(gameID: "fixture", generationID: "newer",
                                        layers: [LayerInput(descriptor: runtimeDescriptor(), contents: runtimeBytes)])
        let operation = try engine.startUninstall(planID: plan.planID, idempotencyKey: "stale-uninstall")
        let result = try engine.run(operation.operationID)
        #expect(result.state == .failed)
        #expect(result.error?.contains("staleReferences") == true)
        #expect(try store.referenceSnapshot(gameID: "fixture").active == newer)
    }

    @Test func repeatedRepairRecoveryKeepsOriginalResult() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LoopbackHTTPFixture { _ in FixtureHTTPResponse(body: runtimeBytes) }
        defer { server.stop() }
        let engine = try makeEngine(root)
        _ = try engine.run(makeInstall(engine, baseURL: server.baseURL).operationID)
        let hash = String(runtimeDescriptor().digest.dropFirst(7))
        let object = engine.contentRoot.appendingPathComponent("objects/sha256/\(hash.prefix(2))/\(hash.dropFirst(2))")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: object.path)
        let writer = try FileHandle(forWritingTo: object)
        try writer.write(contentsOf: Data(repeating: 88, count: runtimeBytes.count))
        try writer.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: object.path)
        let repair = try engine.repairInstallation("fixture-install", idempotencyKey: "repair")
        for point in ["REPAIRING.action-complete", "FETCHING_0.action-complete"] {
            let interrupted = try makeEngine(root) { observed in
                if observed == point { throw SimulatedInterruption.stopped }
            }
            #expect(throws: SimulatedInterruption.stopped) { try interrupted.run(repair.operationID) }
            #expect(try engine.journal.get(repair.operationID).canCancel == false)
        }
        let result = try makeEngine(root).run(repair.operationID)
        #expect(result.state == .succeeded)
        let repaired = try JSONDecoder().decode(RepairResult.self, from: #require(result.result))
        #expect(repaired.objectCount == 1)
        #expect(try Data(contentsOf: object) == runtimeBytes)
    }

    @Test func everyInstallationJournalStageSurvivesSIGKILL() throws {
        let server = try LoopbackHTTPFixture { _ in FixtureHTTPResponse(body: runtimeBytes) }
        defer { server.stop() }
        let stages = ["QUEUED", "STARTING", "FETCHING_0", "VERIFIED", "ACTIVATING", "SUCCEEDED"]
        let points = stages.flatMap { stage in OperationJournal.writePoints.map { stage + "." + $0 } }
            + ["FETCHING_0.action-complete", "ACTIVATING.action-complete"]
        for point in points {
            let root = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(try runInstallProbe(root, baseURL: server.baseURL, fault: point) == 9)
            #expect(try runInstallProbe(root, baseURL: server.baseURL) == 0)
            let engine = try makeEngine(root)
            #expect(try engine.journal.list().count == 1)
            #expect(try engine.journal.list().first?.state == .succeeded)
            let store = try ContentStore(root: engine.contentRoot)
            let references = try store.referenceSnapshot(gameID: "fixture")
            let active = try #require(references.active)
            #expect(active.generationID == "fixture-generation")
            #expect(references.rollback == nil)
            try store.validateReference(active, gameID: "fixture")
        }
    }
}

private func runInstallProbe(_ root: URL, baseURL: URL, fault: String? = nil) throws -> Int32 {
    let child = Process()
    child.executableURL = packageRoot.appendingPathComponent(".build/debug/alloy-store-catalog")
    child.arguments = ["install-probe", root.path, baseURL.absoluteString]
    child.standardOutput = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "ALLOY_CATALOG_FAULT")
    environment["ALLOY_CATALOG_FAULT"] = fault
    child.environment = environment
    try child.run()
    child.waitUntilExit()
    return child.terminationStatus
}

private enum SimulatedInterruption: Error { case stopped }
