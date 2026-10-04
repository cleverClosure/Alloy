// Author: Timur Isaev
import AlloyRuntimeAPI
import AlloyStoreCatalog
import Darwin
import Foundation

/// Journal methods lock on disk. The worker queue owns side effects; active IDs
/// are protected by a short NSLock, which is never held while doing I/O.
public final class OperationService: @unchecked Sendable {
    public static let methods = [
        "catalog.list", "catalog.get", "catalog.discover", "install.plan", "install.start", "uninstall.plan",
        "uninstall.start", "repair.start", "inventory.start", "gc.start", "discovery.start", "fingerprint.start",
        "operation.get", "operation.list", "operation.run", "operation.pause", "operation.resume",
        "operation.cancel", "operation.updates"
    ]
    public let engine: InstallationEngine
    private let libraries: [URL]
    private let configuration: ServiceConfiguration
    private let worker = DispatchQueue(label: "com.alloy.runtime.operations")
    private let lock = NSLock()
    private var active = Set<String>()
    private let ownershipDescriptor: Int32

    public init(configuration: ServiceConfiguration) throws {
        self.configuration = configuration
        try OwnedRoots.prepare(configuration.stateRoot)
        try OwnedRoots.prepare(configuration.contentRoot)
        let state = URL(fileURLWithPath: configuration.stateRoot)
        let descriptor = open(state.appendingPathComponent("service.lock").path,
                              O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RuntimeFailure.invalidConfiguration }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw RuntimeFailure.status(.conflict)
        }
        ownershipDescriptor = descriptor
        libraries = (configuration.libraryRoots ?? []).map { URL(fileURLWithPath: $0) }
        let injection: JournalFaultInjector? = configuration.fixtureMode == true ? { @Sendable point in
            guard configuration.testFault == point else { return }
            let marker = state.appendingPathComponent("test-fault-fired")
            let file = open(marker.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard file >= 0 else { return }
            fsync(file)
            close(file)
            kill(getpid(), SIGKILL)
        } : nil
        do {
            engine = try InstallationEngine(root: state.appendingPathComponent("catalog"),
                                            contentRoot: URL(fileURLWithPath: configuration.contentRoot),
                                            faultInjector: injection)
        } catch { close(descriptor); throw error }
        for operation in try engine.journal.list() where !operation.state.isTerminal && operation.state != .paused {
            enqueue(operation.operationID)
        }
    }

    deinit { close(ownershipDescriptor) }

    public func handle(_ request: RuntimeRequest) throws -> Data {
        do {
            let result = try route(request)
            if configuration.fixtureMode == true, configuration.testFault == "REPLY.gate" {
                let marker = URL(fileURLWithPath: configuration.stateRoot).appendingPathComponent("reply-ready")
                let descriptor = open(marker.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
                if descriptor >= 0 { close(descriptor); Thread.sleep(forTimeInterval: 2) }
            }
            return result
        } catch let error as OperationError {
            throw RuntimeFailure.status(Self.code(error))
        } catch let error as InstallationError {
            throw RuntimeFailure.status(Self.code(error))
        } catch let error as CatalogError {
            switch error {
            case .unknownGame, .unknownInstallation: throw RuntimeFailure.status(.notFound)
            default: throw RuntimeFailure.status(.conflict)
            }
        }
    }

    private static func code(_ error: OperationError) -> RuntimeCode {
        switch error {
        case .unknownOperation: .notFound
        case .idempotencyConflict, .cannotControl, .invalidTransition, .immutableTerminal: .conflict
        case .invalidKey: .malformed
        default: .failed
        }
    }

    private static func code(_ error: InstallationError) -> RuntimeCode {
        switch error {
        case .invalidIdentifier, .unknownKind: .malformed
        case .unknownPlan, .noInstalledPlan: .notFound
        case .unexpectedGeneration: .conflict
        case .corruptPlan: .failed
        }
    }

    private func route(_ request: RuntimeRequest) throws -> Data {
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: request.payload)
        }
        func identifier() throws -> String { try decode(IdentifierRequest.self).identifier }
        switch request.method {
        case "catalog.list":
            let query = try decode(PageQuery.self)
            return try encode(StoreCatalog(libraryRoots: libraries).listGames(
                pageSize: query.limit ?? 100, pageToken: query.cursor))
        case "catalog.get": return try encode(StoreCatalog(libraryRoots: libraries).getGame(identifier()))
        case "catalog.discover": return try encode(StoreCatalog(libraryRoots: libraries).discoverInstallations())
        case "install.plan": return try planInstall(decode(InstallPlanRequest.self))
        case "uninstall.plan":
            let input = try decode(UninstallPlanRequest.self)
            return try encode(engine.planUninstall(gameID: input.gameID, installationID: input.installationID))
        case "install.start", "uninstall.start", "repair.start", "fingerprint.start":
            return try start(request.method, input: decode(KeyedIdentifier.self))
        case "inventory.start", "gc.start", "discovery.start":
            return try start(request.method, key: decode(KeyRequest.self).key)
        default: return try routeControl(request)
        }
    }

    private func routeControl(_ request: RuntimeRequest) throws -> Data {
        func identifier() throws -> String {
            try JSONDecoder().decode(IdentifierRequest.self, from: request.payload).identifier
        }
        switch request.method {
        case "operation.get": return try encode(engine.journal.get(identifier()))
        case "operation.list": return try encode(engine.journal.list())
        case "operation.updates":
            return try encode(updates(JSONDecoder().decode(OperationCursor.self, from: request.payload)))
        case "operation.run", "operation.resume":
            let operation = try engine.journal.get(identifier())
            if request.method == "operation.resume" {
                guard operation.state == .paused else { throw RuntimeFailure.status(.conflict) }
            }
            guard enqueue(operation.operationID, resume: request.method == "operation.resume")
                || request.method == "operation.run" else { throw RuntimeFailure.status(.conflict) }
            return try encode(operation)
        case "operation.pause": return try encode(engine.pauseOperation(identifier()))
        case "operation.cancel": return try encode(engine.cancelOperation(identifier()))
        default: throw RuntimeFailure.status(.malformed)
        }
    }

    private func planInstall(_ input: InstallPlanRequest) throws -> Data {
        guard (1...64).contains(input.layers.count), (1...4).contains(input.baseURLs.count),
              input.layers.allSatisfy({ $0.size >= 0 && $0.size <= 256 * 1024 * 1024 }),
              input.baseURLs.allSatisfy({ ["http", "https"].contains($0.scheme ?? "")
                  && $0.user == nil && $0.password == nil && $0.host != nil }) else {
            throw RuntimeFailure.status(.malformed)
        }
        return try encode(engine.planInstall(gameID: input.gameID, installationID: input.installationID,
                                              generationID: input.generationID,
                                              layers: input.layers, baseURLs: input.baseURLs))
    }

    private func start(_ method: String, input: KeyedIdentifier) throws -> Data {
        let operation: CatalogOperation
        switch method {
        case "install.start":
            operation = try engine.startInstall(planID: input.identifier, idempotencyKey: input.key)
        case "uninstall.start":
            operation = try engine.startUninstall(planID: input.identifier, idempotencyKey: input.key)
        case "repair.start": operation = try engine.repairInstallation(input.identifier, idempotencyKey: input.key)
        default:
            operation = try engine.refreshBuildFingerprint(
                installationID: input.identifier, libraryRoots: libraries, idempotencyKey: input.key)
        }
        return try encode(operation)
    }

    private func start(_ method: String, key: String) throws -> Data {
        let operation: CatalogOperation
        switch method {
        case "inventory.start": operation = try engine.getStorageInventory(idempotencyKey: key)
        case "gc.start": operation = try engine.collectGarbage(idempotencyKey: key)
        default: operation = try engine.discoverInstallations(libraryRoots: libraries, idempotencyKey: key)
        }
        return try encode(operation)
    }

    @discardableResult
    private func enqueue(_ identifier: String, resume: Bool = false) -> Bool {
        lock.lock()
        let inserted = active.insert(identifier).inserted
        lock.unlock()
        guard inserted else { return false }
        worker.async { [self] in
            defer { lock.lock(); active.remove(identifier); lock.unlock() }
            do {
                if resume { _ = try engine.resumeOperation(identifier) } else { _ = try engine.run(identifier) }
            } catch {
                // Ambiguous publication remains RUNNING in the authoritative journal.
                // Clients see workerActive=false and can explicitly retry the same ID.
            }
        }
        return true
    }

    private func updates(_ cursor: OperationCursor) throws -> OperationUpdate {
        let operation = try engine.journal.get(cursor.operationID)
        guard cursor.nextIndex >= 0, cursor.nextIndex <= operation.events.count else {
            throw RuntimeFailure.status(.conflict)
        }
        let end = min(cursor.nextIndex + 128, operation.events.count)
        let events = (cursor.nextIndex..<end).map { SequencedOperationEvent(index: $0, event: operation.events[$0]) }
        lock.lock()
        let running = active.contains(cursor.operationID)
        lock.unlock()
        return OperationUpdate(snapshot: operation, events: events,
                               next: OperationCursor(operationID: cursor.operationID, nextIndex: end),
                               hasMore: end < operation.events.count, workerActive: running)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try RuntimeEncoding.encode(value) }
}
