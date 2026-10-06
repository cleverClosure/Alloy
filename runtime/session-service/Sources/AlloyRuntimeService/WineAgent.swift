// Author: Timur Isaev

import AlloyContentStore
import AlloyProfileCompiler
import AlloyRuntimeAPI
import AlloyTitleVolumes
import Darwin
import Foundation

public enum WineAgent {
    public static func run(directory: URL, executable: URL) -> Int32 {
        var start: UInt8 = 0
        guard read(STDIN_FILENO, &start, 1) == 1, start == 71 else { return 42 }
        do {
            let record = try PrivateRecords.read(WineSessionRecord.self,
                                                 from: directory.appendingPathComponent("request.json"))
            let reporter = WineReporter(record: record, directory: directory)
            do {
                guard try ContentStore.digest(Data(contentsOf: executable)) == record.agentDigest else {
                    throw RuntimeFailure.status(.conflict)
                }
                try execute(record, directory: directory, reporter: reporter)
                return 0
            } catch let RuntimeFailure.status(code) {
                try? reporter.update("FAILED", kind: "refused", code: code)
            } catch { try? reporter.update("FAILED", kind: "failed", code: .failed) }
        } catch { return 42 }
        return 42
    }

    private static func execute(_ record: WineSessionRecord, directory: URL, reporter: WineReporter) throws {
        let store = try ContentStore(root: URL(fileURLWithPath: record.contentRoot))
        defer { try? store.releaseLease(record.lease) }
        if record.fault == "wine.missing-lease" { try store.releaseLease(record.lease) }
        try requireLease(record)
        let stored = record.stored
        let compiled = try DevelopmentSessionCompiler.compile(stored.source)
        guard compiled.canonicalJSON == stored.preview.canonicalExport, compiled.specification.runtimeReady,
              !compiled.specification.productionEligible else { throw RuntimeFailure.status(.notReady) }
        try reporter.update("STARTING", kind: "verifying-runtime")
        let runtime: MaterializedRuntime
        do {
            runtime = try store.verifyDevelopmentRuntime(gameID: stored.preview.specification.gameId)
        } catch { throw RuntimeFailure.status(.runtimeIntegrity) }
        guard runtime.reference == stored.preview.generation,
              runtime.treeDigest == compiled.specification.componentDigests["runtimeTree"] else {
            throw RuntimeFailure.status(.runtimeIntegrity)
        }
        try validateFiles(record, runtime: runtime.url)
        let volumes = try TitleVolumeStore(root: URL(fileURLWithPath: record.contentRoot))
        try volumes.withSessionLease(gameID: compiled.specification.gameId, sessionID: stored.sessionID) { _ in
            let plan = try volumes.drivePlan(SessionVolumeRequest(gameID: compiled.specification.gameId,
                sessionID: stored.sessionID, runtimeVolumeID: "runtime", payloadVolumeID: "payload"),
                expectedCacheIdentity: stored.cache, now: Int64(Date().timeIntervalSince1970))
            guard plan == stored.plan else { throw RuntimeFailure.status(.conflict) }
            try launch(record, directory: directory, runtime: runtime, reporter: reporter)
        }
    }

    private static func launch(_ record: WineSessionRecord, directory: URL, runtime: MaterializedRuntime,
                               reporter: WineReporter) throws {
        let stored = record.stored
        let builder = try SessionEnvironment(stateRoot: URL(fileURLWithPath: record.stateRoot),
                                              contentRoot: URL(fileURLWithPath: record.contentRoot))
        try reporter.update("STARTING", kind: "preparing-prefix")
        let input = SessionEnvironmentInput(runtime: runtime.url, generation: runtime.reference.generationID,
            runtimeDigest: runtime.treeDigest, plan: stored.plan, payload: URL(fileURLWithPath: record.payloadRoot))
        let prepared = try builder.prepare(input, sessionRoot: directory) {
            try PrivateRecords.write(BootstrapOwnership(runtime: runtime.url, prefix: $0),
                                     to: directory.appendingPathComponent("bootstrap.json"))
            try WineControl.bootstrap(runtime: runtime.url, prefix: $0, cancelled: { stopRequested(directory) })
            try FileManager.default.removeItem(at: directory.appendingPathComponent("bootstrap.json"))
        }
        let providers = prepared.prefix.appendingPathComponent("drive_c/alloy")
        try privateDirectory(providers)
        try FileManager.default.createSymbolicLink(at: providers.appendingPathComponent("providers"),
                                                   withDestinationURL: runtime.url.appendingPathComponent("providers"))
        try requireLease(record)
        try validateFiles(record, runtime: runtime.url)
        let snapshot = try DevelopmentSessionCompiler.compile(stored.source).snapshot
        var bytes = snapshot.bytes
        if record.fault == "wine.corrupt-snapshot" { bytes[bytes.count - 1] ^= 1 }
        let policy = try PolicyDescriptor(bytes: bytes, expectedDigest: snapshot.digest, directory: directory)
        let log = open(directory.appendingPathComponent("wine.log").path,
                       O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard log >= 0 else { throw RuntimeFailure.status(.failed) }
        defer { close(log) }
        if stopRequested(directory) { try reporter.update("STOPPED", kind: "stopped-before-exec"); return }
        let server = try OwnedWineServer(runtime: runtime.url, prefix: prepared.prefix,
                                         record: record, directory: directory)
        do {
            let child = try SpawnedWine.start(executable: runtime.url.appendingPathComponent("loader/wine"),
                arguments: [stored.request.entryPath], environment: prepared.environment, policy: policy, log: log)
            server.ownership.root = child.identity
            try server.persist()
            let supervisor = try WineTreeSupervisor(server: server, child: child, guestLog: log, reporter: reporter)
            try reporter.update("RUNNING", kind: "policy-delivered")
            let result: (code: Int32, stopped: Bool)
            do { result = try supervisor.run() } catch {
                do { try supervisor.finish() } catch { throw RuntimeFailure.status(.cleanupFailed) }
                throw error
            }
            try supervisor.finish()
            try reporter.update(result.stopped ? "STOPPED" : (result.code == 0 ? "SUCCEEDED" : "FAILED"),
                                kind: "exited", code: result.code == 0 ? .ok : .failed, exitCode: result.code)
        } catch {
            try server.emergencyStop()
            throw error
        }
    }

    private static func requireLease(_ record: WineSessionRecord) throws {
        guard record.lease.holder.processID == getpid() else { throw RuntimeFailure.status(.leaseMissing) }
        try LiveGenerationLease.require(record.lease, contentRoot: record.contentRoot)
    }

    private static func validateFiles(_ record: WineSessionRecord, runtime: URL) throws {
        let input = try DevelopmentSessionInput.decode(record.stored.source)
        for process in input.processes {
            let relative = process.path.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
            let root = URL(fileURLWithPath: record.payloadRoot)
            let file = root.appendingPathComponent(relative)
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_size <= 64 << 20,
                  file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw RuntimeFailure.status(.payloadIntegrity)
            }
            try GuestImage.verify(Data(contentsOf: file), machine: process.machine, digest: process.imageSHA256)
        }
        for policy in [input.defaultPolicy] + input.processes.map(\.policy) {
            let suffix = policy.providerDirectory.dropFirst("C:\\alloy\\providers\\".count)
                .replacingOccurrences(of: "\\", with: "/")
            let provider = runtime.appendingPathComponent("providers/" + suffix)
            var info = stat()
            guard lstat(provider.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw RuntimeFailure.status(.runtimeIntegrity)
            }
        }
    }

    static func stopRequested(_ directory: URL) -> Bool {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop.json").path) { return true }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        return poll(&descriptor, 1, 0) > 0
    }
}

final class WineReporter {
    let record: WineSessionRecord
    let directory: URL
    var events: [WineSessionEvent] = []
    var processes: [WineProcess] = []
    var healthChecks = 0
    var state = "STARTING"
    private var sequence = 0

    init(record: WineSessionRecord, directory: URL) { self.record = record; self.directory = directory }

    func update(_ state: String, kind: String, code: RuntimeCode = .ok, exitCode: Int32? = nil) throws {
        let preview = record.stored.preview
        let correlation = WineCorrelation(sessionID: record.stored.sessionID,
            launchSpecID: preview.specification.launchSpecId, generationID: preview.generation.generationID,
            correlationID: record.correlationID)
        self.state = state
        sequence = max(sequence, events.last?.sequence ?? 0) + 1
        if events.count == 128 { events.removeFirst() }
        events.append(WineSessionEvent(sequence: sequence, kind: kind, correlation: correlation, code: code))
        try PrivateRecords.write(WineSessionSnapshot(sessionID: record.stored.sessionID, preview: preview,
            state: state, code: code, events: events, exitCode: exitCode,
            processes: processes, healthChecks: healthChecks),
            to: directory.appendingPathComponent("state.json"))
    }
}
