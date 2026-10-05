// Author: Timur Isaev
import AlloyDiagnostics
import Foundation

public struct FailureSummary: Codable, Equatable, Sendable {
    public let bundleID: String
    public let outcome: String
    public let complete: Bool
    public let targetID: String
    public let eventCount: Int
    public let localOnly: Bool
}

public enum CaptureBundle {
    public static func prepare(_ capture: FailureCapture) throws -> PreparedBundle {
        guard capture.version == 1, capture.elapsedSeconds.isFinite, capture.elapsedSeconds >= 0,
              capture.elapsedSeconds <= 36, capture.observations.count <= 32,
              let last = capture.observations.last, let identity = last.events.first?.correlation else {
            throw IntegrationError.invalidInput
        }
        let events = capture.observations.flatMap(\.events) + capture.artifacts
        guard events.count <= 1_000 else { throw IntegrationError.budgetExceeded }
        let header = try DiagnosticIdentity.event("diagnostic.capture", identity, [
            DiagnosticIdentity.field("outcome", capture.outcome),
            DiagnosticIdentity.field("complete", String(capture.complete)),
            DiagnosticIdentity.field("target_id", last.targetID),
            DiagnosticIdentity.field("source", last.source),
            DiagnosticIdentity.field("event_count", String(events.count)),
            DiagnosticIdentity.field("elapsed_seconds", String(capture.elapsedSeconds)),
            DiagnosticIdentity.field("service_instances",
                                     capture.observations.map(\.serviceInstanceID).joined(separator: ","))
        ])
        _ = try validate([header] + events, bundleID: "pending")
        return try BundleBuilder.prepare(events: [header] + events)
    }

    public static func summary(_ bundle: SealedBundle) throws -> FailureSummary {
        try validate(bundle.events, bundleID: bundle.manifest.bundleID)
    }

    public static func validate(_ events: [StructuredEvent], bundleID: String) throws -> FailureSummary {
        guard let header = events.first, header.eventCode == "diagnostic.capture" else {
            throw IntegrationError.invalidBundle
        }
        func field(_ name: String) throws -> String {
            guard let value = header.fields.first(where: { $0.name == name })?.value else {
                throw IntegrationError.invalidBundle
            }
            return value
        }
        let outcome = try field("outcome")
        let complete = try field("complete")
        let target = try field("target_id")
        let source = try field("source")
        guard ["true", "false"].contains(complete),
              Int(try field("event_count")) == events.count - 1, events.count > 1,
              source == "runtime.operation" || source == "runtime.session" else {
            throw IntegrationError.invalidBundle
        }
        let identity = header.correlation
        guard target == (source == "runtime.operation" ? identity.operationID : identity.sessionID),
              target != DiagnosticIdentity.unavailable else { throw IntegrationError.identityMismatch }
        for event in events.dropFirst() {
            let other = event.correlation
            guard identity.operationID == other.operationID, identity.sessionID == other.sessionID,
                  identity.gameID == other.gameID, identity.buildID == other.buildID,
                  identity.runtimeGenerationID == other.runtimeGenerationID,
                  identity.hostClassID == other.hostClassID, identity.profileID == other.profileID,
                  identity.profileRevision == other.profileRevision else { throw IntegrationError.identityMismatch }
        }
        try validateOutcome(outcome, complete: complete == "true", events: Array(events.dropFirst()))
        return FailureSummary(bundleID: bundleID, outcome: outcome, complete: complete == "true",
                              targetID: target, eventCount: events.count, localOnly: true)
    }

    private static func validateOutcome(_ outcome: String, complete: Bool, events: [StructuredEvent]) throws {
        let snapshots = events.filter { $0.eventCode.hasSuffix(".snapshot") }
        guard let final = snapshots.last else { throw IntegrationError.incompleteCapture }
        let values = Dictionary(uniqueKeysWithValues: final.fields.map { ($0.name, $0.value) })
        let code = values["exit_code"]
        let state = values["state"]
        let allowed = ["clean", "operation-failed", "native-fixture-signal-abort", "native-fixture-watchdog-hang",
                       "native-fixture-failed", "service-interruption", "budget-exceeded", "native-capture-incomplete"]
        guard allowed.contains(outcome) else { throw IntegrationError.invalidBundle }
        let incomplete = ["service-interruption", "budget-exceeded", "native-capture-incomplete"].contains(outcome)
        guard complete != incomplete else { throw IntegrationError.incompleteCapture }
        if complete, outcome == "clean" {
            guard ["SUCCEEDED", "STOPPED", "CANCELLED"].contains(state) else {
                throw IntegrationError.incompleteCapture
            }
        } else if complete {
            guard state == "FAILED" else { throw IntegrationError.incompleteCapture }
        }
        try validateNative(outcome, code: code, events: events)
    }

    private static func validateNative(_ outcome: String, code: String?, events: [StructuredEvent]) throws {
        if outcome == "native-fixture-signal-abort" {
            guard code == "6", events.contains(where: { $0.eventCode == "runtime.native.exit" }) else {
                throw IntegrationError.incompleteCapture
            }
        }
        if outcome == "native-fixture-watchdog-hang" {
            guard code == "43", events.contains(where: { $0.eventCode == "runtime.native.sample" }) else {
                throw IntegrationError.incompleteCapture
            }
        }
    }
}
