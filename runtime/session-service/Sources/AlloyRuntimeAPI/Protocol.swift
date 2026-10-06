// Author: Timur Isaev
import Foundation

public enum RuntimeLimits {
    public static let messageBytes = 4 * 1024 * 1024
    public static let requestSeconds: TimeInterval = 30
    public static let identifierBytes = 128
}

public enum RuntimeCode: String, Codable, Sendable {
    case ok = "OK"
    case unauthorized = "UNAUTHORIZED"
    case malformed = "MALFORMED_REQUEST"
    case unsupportedVersion = "UNSUPPORTED_VERSION"
    case expired = "REQUEST_EXPIRED"
    case oversized = "MESSAGE_TOO_LARGE"
    case unavailable = "SERVICE_UNAVAILABLE"
    case conflict = "CONFLICT"
    case notFound = "NOT_FOUND"
    case notReady = "LAUNCH_NOT_RUNTIME_READY"
    case runtimeIntegrity = "RUNTIME_INTEGRITY"
    case payloadIntegrity = "PAYLOAD_INTEGRITY"
    case policyIntegrity = "POLICY_INTEGRITY"
    case leaseMissing = "GENERATION_LEASE_MISSING"
    case watchdog = "SESSION_WATCHDOG"
    case processInventory = "PROCESS_INVENTORY_INCOMPLETE"
    case interrupted = "SESSION_INTERRUPTED"
    case cleanupFailed = "SESSION_CLEANUP_FAILED"
    case failed = "OPERATION_FAILED"
}

public struct RuntimeStatus: Codable, Equatable, Sendable {
    public let code: RuntimeCode
    public let domain: String
    public let messageKey: String
    public let supportCode: String
    public let retryable: Bool

    public init(_ code: RuntimeCode) {
        self.code = code
        domain = "alloy.runtime"
        messageKey = "runtime." + code.rawValue.lowercased()
        supportCode = "RT-" + code.rawValue
        retryable = code == .unavailable
    }
}

public struct RuntimeRequest: Codable, Sendable {
    public var apiVersion: Int
    public var requestID: String
    public var credential: String
    public var deadline: TimeInterval
    public var method: String
    public var payload: Data

    public init(method: String, payload: Data = Data("{}".utf8), credential: String,
                requestID: String = UUID().uuidString, apiVersion: Int = 1,
                deadline: TimeInterval = Date().timeIntervalSince1970 + RuntimeLimits.requestSeconds) {
        self.apiVersion = apiVersion
        self.requestID = requestID
        self.credential = credential
        self.deadline = deadline
        self.method = method
        self.payload = payload
    }
}

public struct RuntimeResponse: Codable, Sendable {
    public let apiVersion: Int
    public let requestID: String
    public let status: RuntimeStatus
    public let payload: Data

    public init(requestID: String = "", code: RuntimeCode, payload: Data = Data("{}".utf8)) {
        apiVersion = 1
        self.requestID = requestID
        status = RuntimeStatus(code)
        self.payload = payload
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard status.code == .ok else { throw RuntimeFailure.status(status.code) }
        return try JSONDecoder().decode(type, from: payload)
    }
}

public enum RuntimeFailure: Error, Equatable {
    case status(RuntimeCode)
    case transport
    case invalidConfiguration
}

public struct ServiceInfo: Codable, Sendable {
    public let instanceID: String
    public let protocolVersion: Int
    public let processID: Int32
    public let userID: UInt32
    public let developmentOnly: Bool
    public let gameLaunchAvailable: Bool
    public let methods: [String]

    public init(instanceID: String, processID: Int32, userID: UInt32, methods: [String],
                gameLaunchAvailable: Bool = false) {
        self.instanceID = instanceID
        protocolVersion = 1
        self.processID = processID
        self.userID = userID
        developmentOnly = true
        self.gameLaunchAvailable = gameLaunchAvailable
        self.methods = methods
    }
}

public enum RuntimeEncoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

@objc public protocol RuntimeWire {
    func exchange(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}
