// Author: Timur Isaev
@testable import AlloyClientCore
import AlloyRuntimeAPI
import AlloyStoreCatalog
import Foundation
import Testing

struct ReconciliationTests {
    private func update(_ states: [String], from start: Int = 0, worker: Bool = false) throws -> OperationUpdate {
        let events = states.map { ["state": $0, "stage": "proof"] }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "version": 1, "operationID": "op-proof", "kind": "INSTALL_RUNTIME", "idempotencyKey": "proof",
            "payload": "", "payloadDigest": "digest", "createdAt": "start", "updatedAt": "update",
            "state": states.last ?? "QUEUED", "stage": "proof", "progress": ["completedUnits": 0,
                "totalUnits": 0, "bytesCompleted": 0, "bytesTotal": 0],
            "events": events, "canPause": false, "canCancel": false, "cancellationPolicy": "proof"
        ])
        let operation = try JSONDecoder().decode(CatalogOperation.self, from: bytes)
        return OperationUpdate(snapshot: operation,
            events: (start..<states.count).map { SequencedOperationEvent(index: $0, event: operation.events[$0]) },
            next: OperationCursor(operationID: operation.operationID, nextIndex: states.count),
            hasMore: false, workerActive: worker)
    }

    @Test func duplicateDelayedAndMissingNotificationsConvergeOnSnapshot() throws {
        var projection = OperationReconciler()
        let queued = try update(["QUEUED"])
        let finished = try update(["QUEUED", "RUNNING", "SUCCEEDED"], from: 1)
        try projection.accept(queued)
        // No intermediate RUNNING notification was delivered.
        try projection.accept(finished)
        try projection.accept(finished)
        try projection.accept(queued)
        #expect(projection.values.count == 1)
        #expect(projection.values["op-proof"]?.snapshot.state == .succeeded)
        #expect(projection.values["op-proof"]?.revision == 3)
    }

    @Test func wrongCursorAndTerminalRegressionAreRefused() throws {
        var projection = OperationReconciler()
        let finished = try update(["QUEUED", "RUNNING", "SUCCEEDED"])
        let wrongCursor = OperationUpdate(snapshot: finished.snapshot, events: finished.events,
            next: OperationCursor(operationID: "another-operation", nextIndex: 3), hasMore: false, workerActive: false)
        #expect(throws: ClientServiceError.self) { try projection.accept(wrongCursor) }
        try projection.accept(finished)
        let regression = try update(["QUEUED", "RUNNING", "SUCCEEDED", "RUNNING"])
        #expect(throws: ClientServiceError.self) { try projection.accept(regression) }
        #expect(projection.values["op-proof"]?.snapshot.state == .succeeded)
    }

    @Test func sameRevisionCanChangeWorkerButNotOperationState() throws {
        var projection = OperationReconciler()
        try projection.accept(update(["QUEUED", "RUNNING"], worker: true))
        try projection.accept(update(["QUEUED", "RUNNING"], worker: false))
        #expect(projection.values["op-proof"]?.workerActive == false)
        #expect(throws: ClientServiceError.self) { try projection.accept(update(["QUEUED", "FAILED"])) }
    }

    @Test @MainActor func supportSummaryExcludesLocalIdentifiersAndPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-summary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PreferencesStore(directory: root)
        let store = ClientStore(snapshot: .fixture(.available), storage: storage)
        let controller = RuntimeController(store: store, storage: storage)
        controller.problem = .service(ClientServiceError.changedBuild)
        let summary = controller.supportSummary
        #expect(summary.contains("CLIENT-BUILD-CHANGED"))
        #expect(!summary.contains(root.path) && !summary.contains("Atlas") && !summary.contains("steam:"))
    }
}
