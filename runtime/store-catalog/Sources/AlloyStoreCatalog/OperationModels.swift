// Author: Timur Isaev
import Foundation

public enum OperationState: String, Codable, CaseIterable, Sendable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case paused = "PAUSED"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case cancelling = "CANCELLING"
    case cancelled = "CANCELLED"

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }

    public func allows(_ next: Self) -> Bool {
        switch self {
        case .queued: next == .running
        case .running: [.paused, .succeeded, .failed, .cancelling].contains(next)
        case .paused: [.running, .cancelling].contains(next)
        case .cancelling: next == .cancelled
        case .succeeded, .failed, .cancelled: false
        }
    }
}

public enum OperationKind: String, Codable, CaseIterable, Sendable {
    case discover = "DISCOVER_INSTALLATIONS"
    case fingerprint = "REFRESH_BUILD_FINGERPRINT"
    case install = "INSTALL_RUNTIME"
    case uninstall = "UNINSTALL_RUNTIME"
    case repair = "REPAIR_INSTALLATION"
    case inventory = "STORAGE_INVENTORY"
    case garbageCollection = "COLLECT_GARBAGE"
}

public struct OperationProgress: Codable, Equatable, Sendable {
    public var completedUnits: UInt64 = 0
    public var totalUnits: UInt64 = 0
    public var bytesCompleted: UInt64 = 0
    public var bytesTotal: UInt64 = 0
    public init() {}
}

public struct OperationEvent: Codable, Equatable, Sendable {
    public let state: OperationState
    public let stage: String
}

public struct CatalogOperation: Codable, Equatable, Sendable {
    public let version: Int
    public let operationID: String
    public let kind: OperationKind
    public let idempotencyKey: String
    public let payload: Data
    public let payloadDigest: String
    public let previousAttemptID: String?
    public let createdAt: String
    public internal(set) var updatedAt: String
    public internal(set) var state: OperationState
    public internal(set) var stage: String
    public internal(set) var progress: OperationProgress
    public internal(set) var result: Data?
    public internal(set) var error: String?
    public internal(set) var events: [OperationEvent]
    public internal(set) var canPause: Bool
    public internal(set) var canCancel: Bool
    public let cancellationPolicy: String
}

public enum OperationError: Error, Equatable {
    case invalidKey
    case unknownOperation(String)
    case idempotencyConflict
    case invalidTransition(OperationState, OperationState)
    case immutableTerminal
    case corruptJournal(String)
    case fileSystem(String, Int32)
    case cannotControl(String)
}

public typealias JournalFaultInjector = @Sendable (String) throws -> Void
