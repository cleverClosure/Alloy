// Author: Timur Isaev
import AlloyDiagnostics
import AlloyRuntimeAPI
import Foundation

public enum SessionAdapter {
    public static func observe(_ session: SessionSnapshot, expectedID: String,
                               requestID: String, instanceID: String) throws -> Observation {
        let record = session.record
        let preview = record.preview
        let spec = preview.specification
        guard record.sessionID == expectedID, record.request.previewID == preview.previewID,
              spec.runtimeGenerationId == preview.generation.generationID,
              try StrictJSON.equal(preview.canonicalExport, DiagnosticsJSON.encode(spec)) else {
            throw IntegrationError.identityMismatch
        }
        guard ["RUNNING", "STOPPING", "STOPPED", "SUCCEEDED", "FAILED", "INTERRUPTED"].contains(session.state),
              spec.verification == "unsigned-development", !spec.productionEligible, !spec.runtimeReady,
              Set(session.nodes.map(\.name)).count == session.nodes.count,
              Set(session.nodes.map(\.name)).isSubset(of: ["agent", "child", "grandchild"]),
              Set(session.liveNodes).isSubset(of: Set(session.nodes.map(\.name))),
              session.nodes.allSatisfy({ $0.lease.gameID == spec.gameId
                  && $0.lease.generationID == spec.runtimeGenerationId
                  && $0.lease.manifestDigest == preview.generation.manifestDigest }) else {
            throw IntegrationError.identityMismatch
        }
        guard Set(session.liveNodes).count == session.liveNodes.count,
              Set(session.nodes.map { $0.lease.holder.processID }).count == session.nodes.count,
              session.nodes.allSatisfy({
                  ["RUNNING", "EXITED", "EXITED_ESCALATED", "EXITED_WATCHDOG"].contains($0.state)
              }),
              !["FAILED", "SUCCEEDED", "STOPPED", "INTERRUPTED"].contains(session.state)
                || session.liveNodes.isEmpty else { throw IntegrationError.inconsistentHistory }
        let identity = try DiagnosticIdentity.correlation(
            requestID: requestID, sessionID: record.sessionID, gameID: spec.gameId,
            buildID: spec.gameBuildId, hostID: spec.hostClassId, generationID: spec.runtimeGenerationId,
            profileID: spec.profile.id, profileRevision: String(spec.profile.revision))
        var fields = try [
            DiagnosticIdentity.field("state", session.state),
            DiagnosticIdentity.field("exit_code", session.exitCode.map(String.init) ?? "unavailable"),
            DiagnosticIdentity.field("live_node_count", String(session.liveNodes.count)),
            DiagnosticIdentity.field("fixture_digest", record.fixtureDigest, .componentVersions),
            DiagnosticIdentity.field("scenario", record.request.scenario.rawValue),
            DiagnosticIdentity.field("declared_component_digests", String(
                data: DiagnosticsJSON.encode(spec.componentDigests), encoding: .utf8) ?? "unavailable",
                                     .componentVersions),
            DiagnosticIdentity.field("component_scope", "declarations-only; native-fixture-is-not-a-provider"),
            DiagnosticIdentity.field("session_history", "snapshot-only; no-service-event-sequence")
        ]
        for node in session.nodes.sorted(by: { $0.name < $1.name }) {
            let holder = node.lease.holder
            fields.append(try DiagnosticIdentity.field("owned_" + node.name,
                "\(holder.processID):\(holder.startTimeSeconds):\(holder.startTimeMicroseconds):\(node.state)"))
        }
        return try Observation(source: "runtime.session", serviceInstanceID: instanceID, targetID: record.sessionID,
                               state: session.state, historyComplete: false,
                               events: [DiagnosticIdentity.event("runtime.session.snapshot", identity, fields)])
    }
}
