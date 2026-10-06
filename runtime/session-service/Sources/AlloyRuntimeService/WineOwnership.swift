// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation

struct WineOwnership: Codable {
    let runtime: URL
    let prefix: URL
    let serverLease: GenerationLease
    var root: LeaseProcessIdentity?
    var processes: [WineProcess] = []

    var identities: [LeaseProcessIdentity] {
        [serverLease.holder] + [root].compactMap { $0 } + processes.compactMap(\.native)
    }
}

/// Persisted before the guest starts. The persistent server pins the generation
/// even if both the service and its agent disappear between child observations.
final class OwnedWineServer {
    let process: Process
    let gate = Pipe()
    let log: FileHandle
    let record: WineSessionRecord
    let directory: URL
    let store: ContentStore
    var ownership: WineOwnership

    init(runtime: URL, prefix: URL, record: WineSessionRecord, directory: URL) throws {
        self.record = record
        self.directory = directory
        store = try ContentStore(root: URL(fileURLWithPath: record.contentRoot))
        let path = directory.appendingPathComponent("server.log")
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RuntimeFailure.status(.failed) }
        log = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        process = Process()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        process.executableURL = executable
        process.arguments = ["--server", directory.path]
        process.environment = SessionEnvironment.scrubbed(runtime: runtime, prefix: prefix)
        process.standardInput = gate
        process.standardOutput = log
        process.standardError = log
        try PrivateRecords.write(BootstrapOwnership(runtime: runtime, prefix: prefix),
                                 to: directory.appendingPathComponent("bootstrap.json"))
        try process.run()
        let identity = NativeProcessIdentity.current(process.processIdentifier)
        do {
            let lease = try store.acquireLease(gameID: record.stored.preview.specification.gameId,
                generation: record.stored.preview.generation, holderProcessID: process.processIdentifier)
            ownership = WineOwnership(runtime: runtime, prefix: prefix, serverLease: lease)
        } catch {
            try? gate.fileHandleForWriting.close()
            if let identity, NativeProcessIdentity.isLive(identity) { kill(identity.processID, SIGKILL) }
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
            guard !process.isRunning else { throw RuntimeFailure.status(.cleanupFailed) }
            throw error
        }
        do {
            try persist()
            try FileManager.default.removeItem(at: directory.appendingPathComponent("bootstrap.json"))
            try gate.fileHandleForWriting.write(contentsOf: Data([71]))
            try gate.fileHandleForWriting.close()
            try awaitReady(path: path)
        } catch {
            try emergencyStop()
            throw error
        }
    }

    private func awaitReady(path: URL) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard process.isRunning else { throw RuntimeFailure.status(.processInventory) }
            let data = try Data(contentsOf: path)
            if String(data: data, encoding: .utf8)?.contains("wineserver: starting (pid=") == true { return }
            usleep(10_000)
        }
        throw RuntimeFailure.status(.processInventory)
    }

    func emergencyStop() throws {
        let environment = SessionEnvironment.scrubbed(runtime: ownership.runtime, prefix: ownership.prefix)
        _ = try? WineControl.run(ownership.runtime.appendingPathComponent("server/wineserver"),
                                 arguments: ["-k"], environment: environment, seconds: 2)
        for identity in ownership.identities where NativeProcessIdentity.isLive(identity) {
            kill(identity.processID, SIGKILL)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while ownership.identities.contains(where: NativeProcessIdentity.mayStillBeLive),
              DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
        try release()
    }

    func persist() throws {
        try PrivateRecords.write(ownership, to: directory.appendingPathComponent("ownership.json"))
    }

    func release() throws {
        guard ownership.identities.allSatisfy({ !NativeProcessIdentity.mayStillBeLive($0) }) else {
            throw RuntimeFailure.status(.cleanupFailed)
        }
        try store.releaseLease(ownership.serverLease)
    }
}
