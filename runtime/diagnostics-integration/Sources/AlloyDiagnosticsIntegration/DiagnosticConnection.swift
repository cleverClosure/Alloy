// Author: Timur Isaev
import AlloyRuntimeAPI
import Foundation

public struct DiagnosticConnection {
    public let client: RuntimeClient
    public init(endpoint: String) throws {
        guard endpoint.hasPrefix("/"), !endpoint.contains("\0") else { throw IntegrationError.invalidInput }
        client = RuntimeClient(configuration: try ServiceConfiguration.read(endpoint))
    }

    public func read<Value: Codable>(_ method: String, payload: Data = Data("{}".utf8),
                                     as type: Value.Type, timeout: Double = 5) throws -> (String, Value) {
        let response = try client.call(method, payload: payload, timeout: timeout)
        guard response.status.code == .ok else { throw RuntimeFailure.status(response.status.code) }
        return (response.requestID, try StrictJSON.decode(type, from: response.payload))
    }

    public func observe(kind: String, identifier: String, deadline: Double? = nil) throws -> Observation {
        func remaining() throws -> Double {
            let seconds = min(5, (deadline ?? (ProcessInfo.processInfo.systemUptime + 15))
                - ProcessInfo.processInfo.systemUptime)
            guard seconds > 0 else { throw IntegrationError.budgetExceeded }
            return seconds
        }
        let (_, info) = try read("info", as: ServiceInfo.self, timeout: remaining())
        guard info.developmentOnly, !info.gameLaunchAvailable, UUID(uuidString: info.instanceID) != nil else {
            throw IntegrationError.invalidInput
        }
        let observation: Observation
        if kind == "operation" {
            let cursor = OperationCursor(operationID: identifier)
            let (request, update) = try read("operation.updates", payload: RuntimeEncoding.encode(cursor),
                                             as: OperationUpdate.self, timeout: remaining())
            var adapter = OperationAdapter()
            guard let value = try adapter.observe(update, requested: cursor, requestID: request,
                                                  instanceID: info.instanceID) else {
                throw IntegrationError.inconsistentHistory
            }
            observation = value
        } else if kind == "session" {
            let payload = try RuntimeEncoding.encode(IdentifierRequest(identifier))
            let (request, snapshot) = try read("session.get", payload: payload,
                                               as: SessionSnapshot.self, timeout: remaining())
            observation = try SessionAdapter.observe(snapshot, expectedID: identifier, requestID: request,
                                                      instanceID: info.instanceID)
        } else { throw IntegrationError.invalidInput }
        let (_, after) = try read("info", as: ServiceInfo.self, timeout: remaining())
        guard info.instanceID == after.instanceID else { throw IntegrationError.incompleteCapture }
        return observation
    }
}
