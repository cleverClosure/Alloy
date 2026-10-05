// Author: Timur Isaev
import AlloyDiagnostics
import Foundation

public enum IntegrationError: String, Error {
    case invalidInput, identityMismatch, inconsistentHistory, unsupportedFields, budgetExceeded
    case incompleteCapture, unsafeDestination, invalidBundle, unavailable
}

/// Only selected, classified facts cross this boundary; never raw RPCs or endpoint capabilities.
public struct Observation: Codable, Equatable, Sendable {
    public let version: Int
    public let source: String
    public let serviceInstanceID: String
    public let targetID: String
    public let state: String
    public let historyComplete: Bool
    public let events: [StructuredEvent]

    public init(source: String, serviceInstanceID: String, targetID: String, state: String,
                historyComplete: Bool, events: [StructuredEvent]) {
        version = 1
        self.source = source
        self.serviceInstanceID = serviceInstanceID
        self.targetID = targetID
        self.state = state
        self.historyComplete = historyComplete
        self.events = events
    }
}

public enum StrictJSON {
    /// Codable normally discards new fields. This adapter refuses them until classified.
    public static func decode<Value: Codable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.count <= 4 * 1024 * 1024 else { throw IntegrationError.budgetExceeded }
        let value = try JSONDecoder().decode(type, from: data)
        guard try equal(data, DiagnosticsJSON.encode(value)) else { throw IntegrationError.unsupportedFields }
        return value
    }

    public static func equal(_ lhs: Data, _ rhs: Data) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: lhs, options: [.fragmentsAllowed])
        let right = try JSONSerialization.jsonObject(with: rhs, options: [.fragmentsAllowed])
        return (left as AnyObject).isEqual(right)
    }
}

public enum DiagnosticIdentity {
    /// Reserved compatibility marker for v1's mandatory identity slots, never an observed identifier.
    public static let unavailable = "unavailable"

    static func correlation(requestID: String, operationID: String = unavailable,
                            sessionID: String = unavailable, gameID: String = unavailable,
                            buildID: String = unavailable, hostID: String = unavailable,
                            generationID: String = unavailable, profileID: String = unavailable,
                            profileRevision: String = unavailable) throws -> CorrelationID {
        try CorrelationID(requestID: requestID, operationID: operationID, sessionID: sessionID,
                          gameID: gameID, buildID: buildID, hostClassID: hostID,
                          runtimeGenerationID: generationID, profileID: profileID,
                          profileRevision: profileRevision, processPolicyID: unavailable,
                          providerBuildDigests: [unavailable: unavailable], testPlan: "diag-163-local",
                          runner: "local-runtime-client")
    }

    static func field(_ name: String, _ value: String, _ kind: DataClass = .runtimeOutcome) throws -> EventField {
        try EventField(name: name, value: value, dataClass: kind)
    }

    static func event(_ code: String, _ identity: CorrelationID, _ fields: [EventField]) throws -> StructuredEvent {
        let event = try StructuredEvent(eventCode: code,
                                       timestampUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
                                       correlation: identity, fields: fields + [
            field("provenance", "local-development; no-guest-or-provider-execution-evidence"),
            field("request_scope", "diagnostic-read; originating-RPC-request-ID-not-retained"),
            field("missing_identity_marker", unavailable),
            field("provider_evidence", "unavailable"), field("process_policy_evidence", "unavailable")
        ])
        return try EventRedactor.redact(event).event
    }
}
