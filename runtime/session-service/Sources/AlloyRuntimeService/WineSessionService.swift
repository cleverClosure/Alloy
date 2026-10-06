// Author: Timur Isaev

import AlloyContentStore
import AlloyProfileCompiler
import AlloyRuntimeAPI
import Foundation
import Darwin

struct WineSessionRecord: Codable {
    let stored: StoredSyntheticPreview
    let contentRoot: String
    let stateRoot: String
    let payloadRoot: String
    let agentDigest: String
    let correlationID: String
    let lease: GenerationLease
    let fault: String?
}

/// Synthetic opt-in only. The fixture executable is never an input to this driver.
final class WineSessionService: @unchecked Sendable {
    static let methods = ["launch.synthetic.resolve", "wine.session.list"]
    private struct Child: @unchecked Sendable { let process: Process; let control: Pipe }
    private let configuration: ServiceConfiguration
    private let previews: SyntheticPreviewStore
    private let executable: URL
    private let executableDigest: String
    private let root: URL
    private let lock = NSLock()
    private let preparationQueue = DispatchQueue(label: "com.alloy.wine-preparation")
    private let maintenanceQueue = DispatchQueue(label: "com.alloy.wine-recovery")
    private var timer: DispatchSourceTimer?
    private var recovered: Set<String> = []
    private var children: [String: Child] = [:]
    private var preparing: Set<String> = []

    init(configuration: ServiceConfiguration, executable: URL) throws {
        self.configuration = configuration
        self.executable = executable
        executableDigest = try ContentStore.digest(Data(contentsOf: executable))
        previews = try SyntheticPreviewStore(configuration: configuration)
        root = URL(fileURLWithPath: configuration.stateRoot).appendingPathComponent("wine-sessions")
        try privateDirectory(root)
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            let directory = try directory(name)
            try PrivateRecords.write(["requested": true], to: directory.appendingPathComponent("stop.json"))
        }
        let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.maintain() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    private func maintain() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where !recovered.contains(name) {
            lock.lock()
            let isPreparing = preparing.contains(name)
            lock.unlock()
            if isPreparing { continue }
            guard let directory = try? directory(name) else { continue }
            guard let record = try? PrivateRecords.read(WineSessionRecord.self,
                      from: directory.appendingPathComponent("request.json")) else { continue }
            if NativeProcessIdentity.mayStillBeLive(record.lease.holder) { continue }
            let stateURL = directory.appendingPathComponent("state.json")
            let previous = try? PrivateRecords.read(WineSessionSnapshot.self, from: stateURL)
            let ownership = try? PrivateRecords.read(WineOwnership.self,
                from: directory.appendingPathComponent("ownership.json"))
            let survivors = ownership?.identities.contains(where: NativeProcessIdentity.mayStillBeLive) ?? false
            if let previous, ["SUCCEEDED", "STOPPED", "FAILED", "INTERRUPTED"].contains(previous.state),
               previous.code != .cleanupFailed, !survivors {
                recovered.insert(name)
                continue
            }
            let reporter = WineReporter(record: record, directory: directory)
            reporter.events = previous?.events ?? []
            reporter.healthChecks = previous?.healthChecks ?? 0
            do {
                reporter.processes = try WineRecovery.recover(record: record, directory: directory)
                try reporter.update("INTERRUPTED", kind: "restart-reconciled", code: .interrupted)
            } catch {
                try? reporter.update("FAILED", kind: "recovery-failed", code: .cleanupFailed)
            }
            if let owned = try? PrivateRecords.read(WineOwnership.self,
                    from: directory.appendingPathComponent("ownership.json")),
               owned.identities.contains(where: NativeProcessIdentity.mayStillBeLive) { continue }
            recovered.insert(name)
        }
    }

    func handles(_ request: RuntimeRequest) -> Bool {
        if Self.methods.contains(request.method) { return true }
        guard ["launch.game", "launch.verify", "session.get", "session.stop"].contains(request.method),
              let input = try? JSONDecoder().decode(IdentifierRequest.self, from: request.payload) else { return false }
        return input.identifier.hasPrefix("wine-")
    }

    func handle(_ request: RuntimeRequest) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        do { return try route(request) } catch is CompilerFailure { throw RuntimeFailure.status(.notReady) }
    }

    private func route(_ request: RuntimeRequest) throws -> Data {
        switch request.method {
        case "launch.synthetic.resolve":
            return try RuntimeEncoding.encode(previews.resolve(JSONDecoder().decode(
                SyntheticResolveRequest.self, from: request.payload)))
        case "wine.session.list":
            let identifiers = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            return try RuntimeEncoding.encode(identifiers.map(snapshot))
        default: break
        }
        let identifier = try JSONDecoder().decode(IdentifierRequest.self, from: request.payload).identifier
        switch request.method {
        case "launch.game": return try RuntimeEncoding.encode(start(identifier, correlation: request.requestID))
        case "launch.verify": return try RuntimeEncoding.encode(previews.verify(identifier).preview)
        case "session.get": return try RuntimeEncoding.encode(snapshot(identifier))
        case "session.stop":
            let path = try directory(identifier).appendingPathComponent("stop.json")
            _ = try snapshot(identifier)
            try PrivateRecords.write(["requested": true], to: path)
            try children[identifier]?.control.fileHandleForWriting.close()
            return try RuntimeEncoding.encode(snapshot(identifier))
        default: throw RuntimeFailure.status(.malformed)
        }
    }

    private func start(_ identifier: String, correlation: String) throws -> WineSessionSnapshot {
        // Canonical preview checks are bounded. Store construction and lease acquisition
        // hash runtime contents and must never occupy the synchronous client request.
        let stored = try previews.verify(identifier, currentGeneration: false)
        let directory = try directory(stored.sessionID)
        if FileManager.default.fileExists(atPath: directory.path) {
            let previous = try snapshot(stored.sessionID)
            guard previous.preview.previewID == identifier else { throw RuntimeFailure.status(.conflict) }
            return previous
        }
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).count < 128,
              children.values.filter({ $0.process.isRunning }).count < 4,
              let payload = configuration.syntheticPayloadRoot,
              try ContentStore.digest(Data(contentsOf: executable)) == executableDigest else {
            throw RuntimeFailure.status(.conflict)
        }
        let process = Process(), control = Pipe()
        process.executableURL = executable
        process.arguments = [directory.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = control
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            guard let holder = NativeProcessIdentity.current(process.processIdentifier) else {
                throw RuntimeFailure.status(.failed)
            }
            try privateDirectory(directory)
            let pending = PendingWineLaunch(stored: stored, holder: holder, correlationID: correlation)
            try PrivateRecords.write(pending, to: directory.appendingPathComponent("pending.json"))
            let child = Child(process: process, control: control)
            children[stored.sessionID] = child
            preparing.insert(stored.sessionID)
            preparationQueue.async { [self] in prepare(pending, child: child, payload: payload, directory: directory) }
            return pending.snapshot(state: "STARTING")
        } catch {
            try? control.fileHandleForWriting.close()
            // The helper has received no gate byte and cannot access this unpublished request.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func prepare(_ pending: PendingWineLaunch, child: Child, payload: String, directory: URL) {
        defer {
            lock.lock()
            preparing.remove(pending.stored.sessionID)
            lock.unlock()
        }
        var store: ContentStore?
        var lease: GenerationLease?
        do {
            if configuration.testFault == "wine.delayed-preparation" { Thread.sleep(forTimeInterval: 3) }
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop.json").path),
                  NativeProcessIdentity.isLive(pending.holder) else {
                throw RuntimeFailure.status(.interrupted)
            }
            let content = try ContentStore(root: URL(fileURLWithPath: configuration.contentRoot))
            store = content
            let stored = pending.stored
            guard stored.preview.expiresAt > Date().timeIntervalSince1970,
                  try content.referenceSnapshot(gameID: stored.preview.specification.gameId,
                      validateContents: false).active == stored.preview.generation else {
                throw RuntimeFailure.status(.conflict)
            }
            let acquired = try content.acquireLease(gameID: stored.preview.specification.gameId,
                generation: stored.preview.generation, holderProcessID: pending.holder.processID)
            lease = acquired
            guard acquired.holder == pending.holder else { throw RuntimeFailure.status(.conflict) }
            let record = WineSessionRecord(stored: stored, contentRoot: configuration.contentRoot,
                stateRoot: configuration.stateRoot, payloadRoot: payload, agentDigest: executableDigest,
                correlationID: pending.correlationID, lease: acquired, fault: configuration.testFault)
            lock.lock()
            defer { lock.unlock() }
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop.json").path),
                  NativeProcessIdentity.isLive(pending.holder) else { throw RuntimeFailure.status(.interrupted) }
            try PrivateRecords.write(record, to: directory.appendingPathComponent("request.json"))
            try child.control.fileHandleForWriting.write(contentsOf: Data([71]))
        } catch {
            let dead = closePendingGate(pending, child: child)
            if dead, let lease { try? store?.releaseLease(lease) }
            let stopped = FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop.json").path)
            let code: RuntimeCode
            if !dead {
                code = .cleanupFailed
            } else if stopped {
                code = .ok
            } else if case let RuntimeFailure.status(status) = error {
                code = status
            } else { code = .failed }
            try? PrivateRecords.write(pending.snapshot(state: stopped && dead ? "STOPPED" : "FAILED", code: code),
                                      to: directory.appendingPathComponent("state.json"))
        }
    }

    private func closePendingGate(_ pending: PendingWineLaunch, child: Child) -> Bool {
        try? child.control.fileHandleForWriting.close()
        // EOF releases only this gated helper; it has not executed Wine. Do not
        // release the generation while its captured holder may still exist.
        let deadline = Date().addingTimeInterval(2)
        while NativeProcessIdentity.mayStillBeLive(pending.holder), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if NativeProcessIdentity.isLive(pending.holder) { kill(pending.holder.processID, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(2)
        while NativeProcessIdentity.mayStillBeLive(pending.holder), Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let dead = !NativeProcessIdentity.mayStillBeLive(pending.holder)
        return dead
    }

    private func snapshot(_ identifier: String) throws -> WineSessionSnapshot {
        let directory = try directory(identifier)
        let state = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: state.path) {
            return try PrivateRecords.read(WineSessionSnapshot.self, from: state)
        }
        if let pending = try? PrivateRecords.read(PendingWineLaunch.self,
                                                  from: directory.appendingPathComponent("pending.json")) {
            if preparing.contains(identifier) {
                let stopped = FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop.json").path)
                return pending.snapshot(state: stopped ? "STOPPING" : "STARTING")
            }
            return pending.snapshot(state: NativeProcessIdentity.mayStillBeLive(pending.holder)
                ? "STARTING" : "INTERRUPTED")
        }
        let record = try PrivateRecords.read(WineSessionRecord.self,
                                             from: directory.appendingPathComponent("request.json"))
        let status = NativeProcessIdentity.mayStillBeLive(record.lease.holder) ? "STARTING" : "INTERRUPTED"
        return WineSessionSnapshot(sessionID: identifier, preview: record.stored.preview, state: status)
    }

    private func directory(_ identifier: String) throws -> URL {
        let suffix = identifier.dropFirst(5)
        guard identifier.hasPrefix("wine-"), suffix.utf8.count == 64,
              suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RuntimeFailure.status(.malformed)
        }
        return root.appendingPathComponent(identifier)
    }
}

/// Durable admission before expensive runtime validation. The helper is still on its stdin gate.
private struct PendingWineLaunch: Codable, @unchecked Sendable {
    let stored: StoredSyntheticPreview
    let holder: LeaseProcessIdentity
    let correlationID: String

    func snapshot(state: String, code: RuntimeCode = .ok) -> WineSessionSnapshot {
        let preview = stored.preview
        let resultCode: RuntimeCode = state == "INTERRUPTED" ? .interrupted : code
        let event = WineSessionEvent(sequence: 1, kind: "launch-" + state.lowercased(),
            correlation: WineCorrelation(sessionID: stored.sessionID, launchSpecID: preview.specification.launchSpecId,
                generationID: preview.generation.generationID, correlationID: correlationID), code: resultCode)
        return WineSessionSnapshot(sessionID: stored.sessionID, preview: preview, state: state,
            code: resultCode, events: ["STARTING", "STOPPING"].contains(state) ? [] : [event])
    }
}
