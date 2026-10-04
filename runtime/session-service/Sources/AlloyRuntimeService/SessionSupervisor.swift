// Author: Timur Isaev
import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation

/// Only this fixed native fixture can run. No command or executable is accepted
/// from an RPC, a profile, a generation or an environment variable.
public final class SessionSupervisor: @unchecked Sendable {
    public static let methods = ["fixture.start", "fixture.kill-agent", "session.get", "session.list", "session.stop"]
    private let configuration: ServiceConfiguration
    private let launches: LaunchService
    private let root: URL
    private let executable: URL
    private let digest: String
    private let lock = NSLock()
    private var children: [String: Child] = [:]

    private struct Child {
        let process: Process
        let control: Pipe
        let identity: LeaseProcessIdentity?
    }

    public init(configuration: ServiceConfiguration, launches: LaunchService, executable: URL) throws {
        self.configuration = configuration
        self.launches = launches
        self.executable = executable.resolvingSymlinksInPath()
        digest = try ContentStore.digest(Data(contentsOf: self.executable))
        root = URL(fileURLWithPath: configuration.stateRoot).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func handle(_ request: RuntimeRequest) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if request.method == "fixture.start" {
            guard configuration.fixtureMode == true else { throw RuntimeFailure.status(.notReady) }
            let input = try JSONDecoder().decode(FixtureStart.self, from: request.payload)
            return try RuntimeEncoding.encode(start(input))
        }
        if request.method == "session.list" {
            let paths = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            return try RuntimeEncoding.encode(paths.filter { $0.hasPrefix("ses-") }.map { try snapshot($0) })
        }
        let identifier = try JSONDecoder().decode(IdentifierRequest.self, from: request.payload).identifier
        switch request.method {
        case "session.get": return try RuntimeEncoding.encode(snapshot(identifier))
        case "session.stop":
            _ = try snapshot(identifier)
            try PrivateRecords.write(["requested": true], to: directory(identifier).appendingPathComponent("stop.json"))
            if let child = children[identifier] { try? child.control.fileHandleForWriting.close() }
            return try RuntimeEncoding.encode(snapshot(identifier))
        case "fixture.kill-agent":
            guard configuration.fixtureMode == true, let child = children[identifier],
                  child.process.isRunning, let identity = child.identity, NativeProcessIdentity.isLive(identity) else {
                throw RuntimeFailure.status(.conflict)
            }
            kill(child.process.processIdentifier, SIGKILL)
            return try RuntimeEncoding.encode(snapshot(identifier))
        default: throw RuntimeFailure.status(.malformed)
        }
    }

    private func start(_ request: FixtureStart) throws -> SessionSnapshot {
        guard !request.key.isEmpty, request.key.utf8.count <= 256 else { throw RuntimeFailure.status(.malformed) }
        let identifier = "ses-" + ContentStore.sha256Hex(Data(request.key.utf8))
        let directory = try directory(identifier)
        let recordURL = directory.appendingPathComponent("request.json")
        if FileManager.default.fileExists(atPath: recordURL.path) {
            let record = try PrivateRecords.read(FixtureSessionRecord.self, from: recordURL)
            guard try RuntimeEncoding.encode(record.request) == RuntimeEncoding.encode(request) else {
                throw RuntimeFailure.status(.conflict)
            }
            return try snapshot(identifier)
        }
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).count < 128,
              children.values.filter({ $0.process.isRunning }).count < 4,
              try ContentStore.digest(Data(contentsOf: executable)) == digest else {
            throw RuntimeFailure.status(.conflict)
        }
        let preview = try launches.verify(request.previewID)
        let record = FixtureSessionRecord(sessionID: identifier, request: request,
                                          preview: preview, fixtureDigest: digest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try PrivateRecords.write(record, to: recordURL)
        let process = Process()
        let control = Pipe()
        process.executableURL = executable
        process.arguments = ["agent", directory.path, configuration.contentRoot]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = control
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            children[identifier] = Child(process: process, control: control,
                                         identity: NativeProcessIdentity.current(process.processIdentifier))
        } catch {
            try PrivateRecords.write(["code": Int32(42)], to: directory.appendingPathComponent("exit.json"))
            throw error
        }
        return try snapshot(identifier)
    }

    private func snapshot(_ identifier: String) throws -> SessionSnapshot {
        let directory = try directory(identifier)
        let record = try PrivateRecords.read(FixtureSessionRecord.self,
                                            from: directory.appendingPathComponent("request.json"))
        guard record.sessionID == identifier else { throw RuntimeFailure.status(.conflict) }
        var nodes: [FixtureNode] = []
        for name in ["agent", "child", "grandchild"] {
            let path = directory.appendingPathComponent(name + ".json")
            if FileManager.default.fileExists(atPath: path.path) {
                let node = try PrivateRecords.read(FixtureNode.self, from: path)
                guard node.name == name, node.lease.gameID == record.preview.specification.gameId,
                      node.lease.generationID == record.preview.generation.generationID,
                      node.lease.manifestDigest == record.preview.generation.manifestDigest else {
                    throw RuntimeFailure.status(.conflict)
                }
                nodes.append(node)
            }
        }
        let live = nodes.filter { NativeProcessIdentity.mayStillBeLive($0.lease.holder) }.map(\.name)
        var code: Int32?
        if let child = children[identifier], !child.process.isRunning {
            code = child.process.terminationStatus
            try PrivateRecords.write(["code": code ?? 42], to: directory.appendingPathComponent("exit.json"))
            try? child.control.fileHandleForWriting.close()
            children.removeValue(forKey: identifier)
        } else if let exitRecord = try? PrivateRecords.read([String: Int32].self,
                                                           from: directory.appendingPathComponent("exit.json")) {
            code = exitRecord["code"]
        }
        let stopping = FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop.json").path)
        let active = children[identifier]?.process.isRunning ?? false
        let state: String
        if !live.isEmpty || active { state = stopping ? "STOPPING" : "RUNNING" } else if stopping {
            state = "STOPPED"
        } else if code == 0 { state = "SUCCEEDED" } else if code != nil { state = "FAILED" } else {
            state = "INTERRUPTED"
        }
        return SessionSnapshot(record: record, state: state, nodes: nodes, liveNodes: live, exitCode: code)
    }

    private func directory(_ identifier: String) throws -> URL {
        guard identifier.hasPrefix("ses-"), identifier.utf8.count == 68,
              identifier.dropFirst(4).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RuntimeFailure.status(.malformed)
        }
        return root.appendingPathComponent(identifier)
    }
}
