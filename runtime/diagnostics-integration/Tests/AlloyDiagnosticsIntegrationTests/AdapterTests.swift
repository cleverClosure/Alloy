// Author: Timur Isaev
import AlloyDiagnostics
import AlloyRuntimeAPI
import AlloyStoreCatalog
import Foundation
import Testing
@testable import AlloyDiagnosticsIntegration

struct AdapterTests {
    func update(state: String = "QUEUED", stages: [String] = ["QUEUED"],
                indices: [Int]? = nil) throws -> OperationUpdate {
        let events = stages.map { ["state": $0, "stage": $0] }
        let snapshot: [String: Any] = [
            "version": 1, "operationID": "op-observed", "kind": "STORAGE_INVENTORY", "idempotencyKey": "test",
            "payload": "e30=", "payloadDigest": "sha256:test", "createdAt": "2026-10-05", "updatedAt": "2026-10-05",
            "state": state, "stage": state, "progress": ["completedUnits": 0, "totalUnits": 0,
                "bytesCompleted": 0, "bytesTotal": 0], "events": events,
            "canPause": false, "canCancel": false, "cancellationPolicy": "test"
        ]
        let value: [String: Any] = ["snapshot": snapshot, "revision": events.count,
            "events": (indices ?? Array(events.indices)).map { ["index": $0, "event": events[$0]] as [String: Any] },
            "next": ["operationID": "op-observed", "nextIndex": events.count], "hasMore": false, "workerActive": false]
        return try StrictJSON.decode(OperationUpdate.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func exactIdentityAndUnknownEvidence() throws {
        var adapter = OperationAdapter()
        let observed = try adapter.observe(update(), requested: .init(operationID: "op-observed"),
                                                  requestID: "rpc-read", instanceID: "instance-one")
        let result = try #require(observed)
        #expect(result.events.first?.correlation.requestID == "rpc-read")
        #expect(result.events.first?.correlation.operationID == "op-observed")
        #expect(result.events.first?.correlation.sessionID == "unavailable")
        #expect(result.events.first?.correlation.providerBuildDigests == ["unavailable": "unavailable"])
        #expect(result.historyComplete)
        #expect(throws: IntegrationError.identityMismatch) {
            try adapter.observe(update(), requested: .init(operationID: "wrong"),
                                requestID: "rpc-read", instanceID: "instance-one")
        }
    }

    @Test func duplicateAndDelayedDelivery() throws {
        var adapter = OperationAdapter()
        let cursor = OperationCursor(operationID: "op-observed")
        let first = try update()
        let later = try update(state: "RUNNING", stages: ["QUEUED", "RUNNING"])
        #expect(try adapter.observe(first, requested: cursor, requestID: "a", instanceID: "i") != nil)
        #expect(try adapter.observe(later, requested: cursor, requestID: "b", instanceID: "i") != nil)
        #expect(try adapter.observe(first, requested: cursor, requestID: "c", instanceID: "i") == nil)
        #expect(try adapter.observe(later, requested: cursor, requestID: "d", instanceID: "i") == nil)
    }

    @Test func omittedAndOutOfOrderAuditEventsFail() throws {
        for indices in [[0], [1, 0]] {
            var adapter = OperationAdapter()
            #expect(throws: IntegrationError.inconsistentHistory) {
                try adapter.observe(update(state: "RUNNING", stages: ["QUEUED", "RUNNING"], indices: indices),
                                    requested: .init(operationID: "op-observed"), requestID: "rpc", instanceID: "i")
            }
        }
    }

    @Test func numericUUIDIsIdentityButFreeTextSecretIsNot() throws {
        let identity = try DiagnosticIdentity.correlation(requestID: "12345678-1234-4123-8123-123456789012")
        let event = try DiagnosticIdentity.event("runtime.test", identity, [
            DiagnosticIdentity.field("detail", "password=planted-secret", .errorCode)
        ])
        #expect(event.correlation == identity)
        #expect(event.fields.first?.value == "[REDACTED]")
        #expect(throws: RedactionError.self) {
            try DiagnosticIdentity.event("runtime.test",
                DiagnosticIdentity.correlation(requestID: "password=planted-secret"), [])
        }
    }

    @Test func unclassifiedWireFieldsAreRefused() throws {
        let info = ServiceInfo(instanceID: "observed", processID: 123, userID: 501, methods: [])
        var object = try #require(JSONSerialization.jsonObject(with: RuntimeEncoding.encode(info)) as? [String: Any])
        object["futurePrivateData"] = "must-not-silently-disappear"
        #expect(throws: IntegrationError.unsupportedFields) {
            try StrictJSON.decode(ServiceInfo.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
}
