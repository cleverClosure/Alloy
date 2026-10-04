// Author: Timur Isaev
import Darwin
import Foundation

/// One atomic record owns both the operation and its idempotency mapping.
/// Callbacks are test-only fault injection; production callers leave them nil.
public final class OperationJournal: @unchecked Sendable {
    public static let writePoints = ["temp-written", "temp-synced", "published", "directory-synced"]
    public let root: URL
    private let faultInjector: JournalFaultInjector?

    public init(root: URL, faultInjector: JournalFaultInjector? = nil) throws {
        self.root = root.standardizedFileURL
        self.faultInjector = faultInjector
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func create<T: Encodable>(
        kind: OperationKind, idempotencyKey: String, payload: T, previousAttemptID: String? = nil
    ) throws -> CatalogOperation {
        guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256 else { throw OperationError.invalidKey }
        let bytes = try StoreCatalog.encode(payload)
        let identifier = Self.identifier(kind: kind, key: idempotencyKey)
        return try locked {
            if FileManager.default.fileExists(atPath: path(identifier).path) {
                let existing = try read(identifier)
                guard existing.payload == bytes, existing.previousAttemptID == previousAttemptID else {
                    throw OperationError.idempotencyConflict
                }
                return existing
            }
            if let previousAttemptID {
                guard try read(previousAttemptID).state.isTerminal else {
                    throw OperationError.cannotControl("previous attempt is not terminal")
                }
            }
            let now = Self.timestamp()
            let operation = CatalogOperation(
                version: 1, operationID: identifier, kind: kind, idempotencyKey: idempotencyKey,
                payload: bytes, payloadDigest: StoreCatalog.digest(bytes), previousAttemptID: previousAttemptID,
                createdAt: now, updatedAt: now, state: .queued, stage: "QUEUED", progress: OperationProgress(),
                result: nil, error: nil, events: [OperationEvent(state: .queued, stage: "QUEUED")],
                canPause: false, canCancel: true, cancellationPolicy: "RETAIN_VERIFIED_OBJECTS")
            try persist(operation)
            return operation
        }
    }

    public func find(kind: OperationKind, idempotencyKey: String) throws -> CatalogOperation? {
        let identifier = Self.identifier(kind: kind, key: idempotencyKey)
        return try locked {
            guard FileManager.default.fileExists(atPath: path(identifier).path) else { return nil }
            return try read(identifier)
        }
    }

    public func get(_ identifier: String) throws -> CatalogOperation { try locked { try read(identifier) } }

    public func list() throws -> [CatalogOperation] {
        try locked {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try read($0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.operationID < $1.operationID }
        }
    }

    @discardableResult
    public func transition(
        _ identifier: String, to state: OperationState, stage: String,
        progress: OperationProgress? = nil, result: Data? = nil, error: String? = nil,
        controllable: Bool = true
    ) throws -> CatalogOperation {
        try locked {
            var operation = try read(identifier)
            guard !operation.state.isTerminal else { throw OperationError.immutableTerminal }
            guard operation.state.allows(state) else {
                throw OperationError.invalidTransition(operation.state, state)
            }
            if (state == .paused && !operation.canPause) || (state == .cancelling && !operation.canCancel) {
                throw OperationError.cannotControl(identifier)
            }
            operation.state = state
            operation.stage = stage
            operation.updatedAt = Self.timestamp()
            operation.progress = progress ?? operation.progress
            operation.result = result
            operation.error = error
            operation.events.append(OperationEvent(state: state, stage: stage))
            operation.canPause = controllable && state == .running
            operation.canCancel = controllable && (state == .running || state == .paused)
            try validate(operation)
            try persist(operation)
            return operation
        }
    }

    @discardableResult
    public func checkpoint(
        _ identifier: String, stage: String, progress: OperationProgress? = nil, controllable: Bool = true
    ) throws -> CatalogOperation {
        try locked {
            var operation = try read(identifier)
            guard operation.state == .running else { throw OperationError.cannotControl(identifier) }
            if operation.stage == stage && operation.progress == (progress ?? operation.progress)
                && operation.canPause == controllable { return operation }
            operation.stage = stage
            operation.updatedAt = Self.timestamp()
            operation.progress = progress ?? operation.progress
            operation.events.append(OperationEvent(state: .running, stage: stage))
            operation.canPause = controllable
            operation.canCancel = controllable
            try validate(operation)
            try persist(operation)
            return operation
        }
    }

    private func read(_ identifier: String) throws -> CatalogOperation {
        guard Self.safeIdentifier(identifier) else { throw OperationError.unknownOperation(identifier) }
        let url = path(identifier)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OperationError.unknownOperation(identifier)
        }
        do {
            let value = try JSONDecoder().decode(CatalogOperation.self, from: Data(contentsOf: url))
            try validate(value)
            guard value.operationID == identifier else { throw OperationError.corruptJournal(identifier) }
            return value
        } catch { throw OperationError.corruptJournal(identifier) }
    }

    private func validate(_ operation: CatalogOperation) throws {
        guard operation.version == 1, !operation.idempotencyKey.isEmpty,
              operation.operationID == Self.identifier(kind: operation.kind, key: operation.idempotencyKey),
              operation.payloadDigest == StoreCatalog.digest(operation.payload),
              operation.progress.completedUnits <= operation.progress.totalUnits,
              operation.progress.bytesCompleted <= operation.progress.bytesTotal,
              operation.events.first == OperationEvent(state: .queued, stage: "QUEUED"),
              operation.events.last == OperationEvent(state: operation.state, stage: operation.stage),
              !operation.stage.isEmpty else { throw OperationError.corruptJournal(operation.operationID) }
        for (previous, next) in zip(operation.events, operation.events.dropFirst()) {
            guard previous.state.allows(next.state)
                || (previous.state == .running && next.state == .running) else {
                throw OperationError.corruptJournal(operation.operationID)
            }
        }
        if operation.state.isTerminal && (operation.canPause || operation.canCancel) {
            throw OperationError.corruptJournal(operation.operationID)
        }
    }

    private func persist(_ operation: CatalogOperation) throws {
        let bytes = try StoreCatalog.encode(operation)
        let temporary = root.appendingPathComponent(".tmp-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw OperationError.fileSystem("open temporary", errno) }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw OperationError.fileSystem("write temporary", errno) }
                offset += count
            }
        }
        try faultInjector?("\(operation.stage).temp-written")
        guard fsync(descriptor) == 0 else { throw OperationError.fileSystem("sync temporary", errno) }
        try faultInjector?("\(operation.stage).temp-synced")
        guard rename(temporary.path, path(operation.operationID).path) == 0 else {
            throw OperationError.fileSystem("publish journal", errno)
        }
        try faultInjector?("\(operation.stage).published")
        let directory = open(root.path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw OperationError.fileSystem("open directory", errno) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw OperationError.fileSystem("sync directory", errno) }
        try faultInjector?("\(operation.stage).directory-synced")
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        let descriptor = open(
            root.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw OperationError.fileSystem("open lock", errno) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw OperationError.fileSystem("lock", errno) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }

    private func path(_ identifier: String) -> URL { root.appendingPathComponent(identifier + ".json") }
    private static func safeIdentifier(_ value: String) -> Bool {
        value.hasPrefix("op-") && value.count == 67
            && value.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    private static func identifier(kind: OperationKind, key: String) -> String {
        "op-" + StoreCatalog.digest(Data((kind.rawValue + "\u{0}" + key).utf8))
    }
    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
