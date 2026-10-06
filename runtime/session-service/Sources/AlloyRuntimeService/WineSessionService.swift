// Author: Timur Isaev

import AlloyContentStore
import AlloyProfileCompiler
import AlloyRuntimeAPI
import Foundation

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
    private struct Child { let process: Process; let control: Pipe }
    private let configuration: ServiceConfiguration
    private let previews: SyntheticPreviewStore
    private let executable: URL
    private let executableDigest: String
    private let root: URL
    private let lock = NSLock()
    private var children: [String: Child] = [:]

    init(configuration: ServiceConfiguration, executable: URL) throws {
        self.configuration = configuration
        self.executable = executable
        executableDigest = try ContentStore.digest(Data(contentsOf: executable))
        previews = try SyntheticPreviewStore(configuration: configuration)
        root = URL(fileURLWithPath: configuration.stateRoot).appendingPathComponent("wine-sessions")
        try privateDirectory(root)
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
        let stored = try previews.verify(identifier)
        let directory = try directory(stored.sessionID)
        let recordURL = directory.appendingPathComponent("request.json")
        if FileManager.default.fileExists(atPath: recordURL.path) {
            let previous = try PrivateRecords.read(WineSessionRecord.self, from: recordURL)
            guard previous.stored.preview.previewID == identifier else { throw RuntimeFailure.status(.conflict) }
            return try snapshot(stored.sessionID)
        }
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).count < 128,
              children.values.filter({ $0.process.isRunning }).count < 4,
              let payload = configuration.syntheticPayloadRoot,
              try ContentStore.digest(Data(contentsOf: executable)) == executableDigest else {
            throw RuntimeFailure.status(.conflict)
        }
        try privateDirectory(directory)
        let process = Process(), control = Pipe()
        process.executableURL = executable
        process.arguments = [directory.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = control
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let store = try ContentStore(root: URL(fileURLWithPath: configuration.contentRoot))
            let lease = try store.acquireLease(gameID: stored.preview.specification.gameId,
                                               generation: stored.preview.generation,
                                               holderProcessID: process.processIdentifier)
            let record = WineSessionRecord(stored: stored, contentRoot: configuration.contentRoot,
                                            stateRoot: configuration.stateRoot, payloadRoot: payload,
                                            agentDigest: executableDigest, correlationID: correlation,
                                            lease: lease, fault: configuration.testFault)
            try PrivateRecords.write(record, to: recordURL)
            children[stored.sessionID] = Child(process: process, control: control)
            try control.fileHandleForWriting.write(contentsOf: Data([71]))
            return try snapshot(stored.sessionID)
        } catch {
            try? control.fileHandleForWriting.close()
            throw error
        }
    }

    private func snapshot(_ identifier: String) throws -> WineSessionSnapshot {
        let directory = try directory(identifier)
        let record = try PrivateRecords.read(WineSessionRecord.self,
                                             from: directory.appendingPathComponent("request.json"))
        let state = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: state.path) {
            return try PrivateRecords.read(WineSessionSnapshot.self, from: state)
        }
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
