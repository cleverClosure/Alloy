// Author: Timur Isaev

import AlloyContentStore
import AlloyProfileCompiler
import AlloyRuntimeAPI
import Darwin
import Foundation

final class WineTreeSupervisor {
    private let server: OwnedWineServer
    private let child: SpawnedWine
    private let guestLog: Int32
    private let trace: WineTrace
    private let reader: FileHandle
    private let source: DevelopmentSessionInput
    private let reporter: WineReporter
    private var rootExit: Int32?
    private var healthChecks = 0
    private var lastHealth: UInt64 = 0

    init(server: OwnedWineServer, child: SpawnedWine, guestLog: Int32,
         reporter: WineReporter) throws {
        self.server = server
        self.child = child
        self.guestLog = guestLog
        self.reporter = reporter
        source = try DevelopmentSessionInput.decode(server.record.stored.source)
        trace = WineTrace(session: server.record.stored.sessionID, rootPID: child.processID,
                          entry: server.record.stored.request.entryPath)
        reader = try FileHandle(forReadingFrom: server.directory.appendingPathComponent("server.log"))
        server.ownership.root = child.identity
        try server.persist()
    }

    func run() throws -> (code: Int32, stopped: Bool) {
        let duration = UInt64(server.record.stored.request.maximumSeconds) * 1_000_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + duration
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try refresh()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw RuntimeFailure.status(.watchdog) }
            if rootExit != nil, !trace.processes.isEmpty,
               trace.processes.filter({ !$0.imagePath.lowercased().hasPrefix("c:\\windows\\") }).allSatisfy(\.exited) {
                return (rootExit!, false)
            }
            if WineAgent.stopRequested(server.directory) { return (0, true) }
            guard server.process.isRunning else { throw RuntimeFailure.status(.processInventory) }
            usleep(20_000)
        }
        throw RuntimeFailure.status(.watchdog)
    }

    func finish() throws {
        // The explicit synthetic guest contract supports a cooperative T: stop
        // marker. No cleanup client may accidentally start a replacement server.
        try? reporter.update("STOPPING", kind: "stop-graceful")
        try? PrivateRecords.write(["requested": true],
            to: server.ownership.prefix.appendingPathComponent("dosdevices/t:/stop"))
        let grace = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < grace {
            try? refresh(checkHealth: false)
            usleep(20_000)
        }
        try? reporter.update("STOPPING", kind: "stop-wineserver")
        let environment = SessionEnvironment.scrubbed(runtime: server.ownership.runtime,
                                                       prefix: server.ownership.prefix)
        _ = try? WineControl.run(server.ownership.runtime.appendingPathComponent("server/wineserver"),
                                 arguments: ["-k"], environment: environment, seconds: 2)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try? refresh(checkHealth: false)
            if server.ownership.identities.allSatisfy({ !NativeProcessIdentity.mayStillBeLive($0) }) { break }
            usleep(20_000)
        }
        try? reporter.update("STOPPING", kind: "stop-kill")
        let survivors = server.ownership.identities.filter(NativeProcessIdentity.isLive)
        if !survivors.isEmpty { try? reporter.update("STOPPING", kind: "kill-escalated") }
        for identity in survivors { kill(identity.processID, SIGKILL) }
        let killed = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < killed {
            if rootExit == nil { rootExit = child.pollExit() }
            if server.ownership.identities.allSatisfy({ !NativeProcessIdentity.mayStillBeLive($0) }) { break }
            usleep(10_000)
        }
        try refresh(checkHealth: false)
        let dead = Set(server.ownership.processes.compactMap { process -> String? in
            guard let identity = process.native, !NativeProcessIdentity.mayStillBeLive(identity) else { return nil }
            return process.identifier
        })
        trace.confirmNativeExit(dead)
        server.ownership.processes = trace.processes.enumerated().map { index, process in
            var value = server.ownership.processes[index]
            value.exited = process.exited
            return value
        }
        try server.persist()
        try trace.validateComplete()
        try server.release()
        try publish(kind: "tree-empty")
    }

    private func refresh(checkHealth: Bool = true) throws {
        var file = stat()
        let offset = try reader.offset()
        guard fstat(reader.fileDescriptor, &file) == 0, file.st_size >= 0,
              UInt64(file.st_size) >= offset, file.st_size <= 16 << 20 else {
            throw RuntimeFailure.status(.processInventory)
        }
        let data = try reader.read(upToCount: 16 << 20) ?? Data()
        try trace.append(data)
        if rootExit == nil { rootExit = child.pollExit() }
        var processes = trace.processes
        var nativeChanged = false
        for index in processes.indices {
            if let previous = server.ownership.processes.first(where: {
                $0.identifier == processes[index].identifier
            }) {
                processes[index].native = previous.native
            }
            classify(&processes[index])
            if !processes[index].exited, processes[index].native == nil,
               let pid = processes[index].unixPID, let identity = WineProcessMembership.observe(pid,
                    executable: server.ownership.runtime.appendingPathComponent("loader/wine"),
                    prefix: server.ownership.prefix) {
                processes[index].native = identity
                nativeChanged = true
            }
        }
        let changed = processes.count != server.ownership.processes.count || !data.isEmpty || nativeChanged
        server.ownership.processes = processes
        if changed { try server.persist() }
        if checkHealth { try health() }
        if changed { try publish(kind: "process-inventory") }
    }

    private func classify(_ process: inout WineProcess) {
        if let known = source.processes.first(where: { $0.path.lowercased() == process.imagePath.lowercased() }) {
            process.classification = "known"
            process.policyID = known.policy.id
        } else {
            process.classification = process.imagePath.lowercased().hasPrefix("c:\\windows\\") ? "runtime" : "unknown"
            process.policyID = source.defaultPolicy.id
        }
    }

    private func health() throws {
        var info = stat()
        guard fstat(guestLog, &info) == 0, info.st_size <= 1 << 20 else {
            throw RuntimeFailure.status(.oversized)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastHealth < 1_000_000_000 { return }
        lastHealth = now
        try LiveGenerationLease.require(server.record.lease, contentRoot: server.record.contentRoot)
        try LiveGenerationLease.require(server.ownership.serverLease, contentRoot: server.record.contentRoot)
        healthChecks += 1
        try publish(kind: "health-ok")
    }

    private func publish(kind: String) throws {
        reporter.processes = server.ownership.processes
        reporter.healthChecks = healthChecks
        try reporter.update(reporter.state, kind: kind)
    }
}
