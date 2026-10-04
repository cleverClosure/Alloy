// Author: Timur Isaev
import AlloyRuntimeAPI
import Darwin
import Foundation

public final class RequestRouter: Sendable {
    public let instanceID = UUID().uuidString
    public let configuration: ServiceConfiguration

    public init(configuration: ServiceConfiguration) { self.configuration = configuration }

    public func exchange(_ bytes: Data, peerUID: UInt32, now: TimeInterval = Date().timeIntervalSince1970) -> Data {
        let response: RuntimeResponse
        if bytes.count > RuntimeLimits.messageBytes {
            response = RuntimeResponse(code: .oversized)
        } else if let request = try? JSONDecoder().decode(RuntimeRequest.self, from: bytes) {
            response = validateAndRoute(request, peerUID: peerUID, now: now)
        } else {
            response = RuntimeResponse(code: .malformed)
        }
        // Every error envelope is a fixed schema with no arbitrary error/path text.
        guard let encoded = try? RuntimeEncoding.encode(response), encoded.count <= RuntimeLimits.messageBytes else {
            return (try? RuntimeEncoding.encode(RuntimeResponse(requestID: response.requestID, code: .oversized)))
                ?? Data()
        }
        return encoded
    }

    private func validateAndRoute(_ request: RuntimeRequest, peerUID: UInt32, now: TimeInterval) -> RuntimeResponse {
        let requestID = request.requestID.utf8.count <= RuntimeLimits.identifierBytes ? request.requestID : ""
        func failure(_ code: RuntimeCode) -> RuntimeResponse { RuntimeResponse(requestID: requestID, code: code) }
        guard peerUID == getuid(), Self.constantTimeEqual(request.credential, configuration.credential) else {
            return failure(.unauthorized)
        }
        guard request.apiVersion == 1 else { return failure(.unsupportedVersion) }
        guard !requestID.isEmpty, request.deadline.isFinite, request.deadline >= now,
              request.deadline <= now + RuntimeLimits.requestSeconds + 1 else { return failure(.expired) }
        guard request.method == "info", request.payload == Data("{}".utf8) else { return failure(.malformed) }
        let info = ServiceInfo(instanceID: instanceID, processID: getpid(), userID: getuid(), methods: ["info"])
        guard let payload = try? RuntimeEncoding.encode(info) else { return failure(.failed) }
        return RuntimeResponse(requestID: requestID, code: .ok, payload: payload)
    }

    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left.utf8)
        let rhs = Array(right.utf8)
        guard lhs.count == 64, rhs.count == 64 else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
