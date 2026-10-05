// Author: Timur Isaev
import AlloyDiagnostics
import AlloyRuntimeAPI
import AlloyStoreCatalog
import Foundation

public struct OperationAdapter {
    private var last: OperationUpdate?
    public init() {}

    /// Snapshots contain full history. The paginated tail must agree exactly;
    /// a missing or changed event is an error, never silently repaired evidence.
    public mutating func observe(_ update: OperationUpdate, requested: OperationCursor,
                                 requestID: String, instanceID: String) throws -> Observation? {
        let snapshot = update.snapshot
        let history = snapshot.events
        guard snapshot.operationID == requested.operationID,
              update.next.operationID == requested.operationID else { throw IntegrationError.identityMismatch }
        guard snapshot.version == 1, history.first?.state == .queued, history.count <= 512,
              update.revision == history.count, requested.nextIndex >= 0,
              requested.nextIndex <= update.revision else { throw IntegrationError.inconsistentHistory }
        let end = min(requested.nextIndex + 128, history.count)
        guard update.next.nextIndex == end, update.hasMore == (end < history.count),
              update.events.map(\.index) == Array(requested.nextIndex..<end),
              update.events.map(\.event) == Array(history[requested.nextIndex..<end]),
              history.last?.state == snapshot.state, history.last?.stage == snapshot.stage else {
            throw IntegrationError.inconsistentHistory
        }
        if let last {
            guard last.snapshot.operationID == snapshot.operationID else { throw IntegrationError.identityMismatch }
            let common = min(last.revision, update.revision)
            guard Array(last.snapshot.events.prefix(common)) == Array(history.prefix(common)) else {
                throw IntegrationError.inconsistentHistory
            }
            if update.revision < last.revision { return nil }
            if last.snapshot.state.isTerminal && last.snapshot != snapshot {
                throw IntegrationError.inconsistentHistory
            }
            if snapshot == last.snapshot { return nil }
        }
        let identity = try identity(snapshot, requestID: requestID)
        var events = try history.enumerated().map { index, event in
            try DiagnosticIdentity.event("runtime.operation.event", identity, [
                DiagnosticIdentity.field("event_index", String(index)),
                DiagnosticIdentity.field("state", event.state.rawValue),
                DiagnosticIdentity.field("stage", event.stage)
            ])
        }
        events.append(try DiagnosticIdentity.event("runtime.operation.snapshot", identity, [
            DiagnosticIdentity.field("state", snapshot.state.rawValue),
            DiagnosticIdentity.field("revision", String(update.revision)),
            DiagnosticIdentity.field("kind", snapshot.kind.rawValue),
            DiagnosticIdentity.field("worker_active", String(update.workerActive)),
            DiagnosticIdentity.field("error", snapshot.error ?? "none", .errorCode)
        ]))
        last = update
        return Observation(source: "runtime.operation", serviceInstanceID: instanceID,
                           targetID: snapshot.operationID, state: snapshot.state.rawValue,
                           historyComplete: true, events: events)
    }

    private func identity(_ operation: CatalogOperation, requestID: String) throws -> CorrelationID {
        if operation.kind == .install || operation.kind == .repair {
            let plan = try StrictJSON.decode(InstallPlan.self, from: operation.payload)
            return try DiagnosticIdentity.correlation(requestID: requestID, operationID: operation.operationID,
                                                       gameID: plan.gameID, generationID: plan.generationID)
        }
        if operation.kind == .uninstall {
            let plan = try StrictJSON.decode(UninstallPlan.self, from: operation.payload)
            return try DiagnosticIdentity.correlation(requestID: requestID, operationID: operation.operationID,
                                                       gameID: plan.gameID,
                                                       generationID: plan.expectedReferences.active?.generationID
                                                           ?? DiagnosticIdentity.unavailable)
        }
        return try DiagnosticIdentity.correlation(requestID: requestID, operationID: operation.operationID)
    }
}
