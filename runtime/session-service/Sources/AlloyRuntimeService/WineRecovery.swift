// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation

/// Reconciles a dead agent from its durable server epoch and complete trace.
/// A live agent is stopped through its control record instead of racing it.
enum WineRecovery {
    static func recover(record: WineSessionRecord, directory: URL) throws -> [WineProcess] {
        guard !NativeProcessIdentity.mayStillBeLive(record.lease.holder) else {
            throw RuntimeFailure.status(.cleanupFailed)
        }
        let path = directory.appendingPathComponent("ownership.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            try cleanupBootstrap(record: record, directory: directory)
            let store = try ContentStore(root: URL(fileURLWithPath: record.contentRoot))
            try store.releaseLease(record.lease)
            return []
        }
        let ownership = try PrivateRecords.read(WineOwnership.self, from: path)
        let trace = WineTrace(session: record.stored.sessionID, rootPID: ownership.root?.processID ?? -1,
                              entry: record.stored.request.entryPath)
        var reader: FileHandle?
        var inventoryError: Error?
        defer { try? reader?.close() }
        do {
            reader = try FileHandle(forReadingFrom: directory.appendingPathComponent("server.log"))
            try trace.append(reader?.read(upToCount: 16 << 20) ?? Data())
        } catch { inventoryError = error }

        // A recorded Unix PID without a previously observed kernel start time
        // is historical evidence, never authority to signal its current owner.
        // Prefix-scoped server control also reaches children the agent had not
        // yet observed. Corrupt or absent diagnostics must not prevent cleanup.
        try stop(ownership)
        if inventoryError == nil {
            do {
                try trace.append(reader?.read(upToCount: 16 << 20) ?? Data())
                try trace.validateComplete()
            } catch { inventoryError = error }
        }
        if let inventoryError { throw inventoryError }
        let store = try ContentStore(root: URL(fileURLWithPath: record.contentRoot))
        for lease in [ownership.serverLease, record.lease] { try store.releaseLease(lease) }
        return trace.processes.map { process in
            var result = process
            if let prior = ownership.processes.first(where: { $0.identifier == process.identifier }) {
                result.native = prior.native
                result.classification = prior.classification
                result.policyID = prior.policyID
            }
            return result
        }
    }

    private static func stop(_ ownership: WineOwnership) throws {
        let environment = SessionEnvironment.scrubbed(runtime: ownership.runtime, prefix: ownership.prefix)
        _ = try? WineControl.run(ownership.runtime.appendingPathComponent("server/wineserver"),
                                 arguments: ["-k"], environment: environment, seconds: 2)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while ownership.identities.contains(where: NativeProcessIdentity.mayStillBeLive),
              DispatchTime.now().uptimeNanoseconds < deadline { usleep(20_000) }
        for identity in ownership.identities where NativeProcessIdentity.isLive(identity) {
            kill(identity.processID, SIGKILL)
        }
        let killed = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while ownership.identities.contains(where: NativeProcessIdentity.mayStillBeLive),
              DispatchTime.now().uptimeNanoseconds < killed { usleep(10_000) }
        guard ownership.identities.allSatisfy({ !NativeProcessIdentity.mayStillBeLive($0) }) else {
            throw RuntimeFailure.status(.cleanupFailed)
        }
    }

    private static func cleanupBootstrap(record: WineSessionRecord, directory: URL) throws {
        let path = directory.appendingPathComponent("bootstrap.json")
        if FileManager.default.fileExists(atPath: path.path) {
            let bootstrap = try PrivateRecords.read(BootstrapOwnership.self, from: path)
            try WineControl.stop(runtime: bootstrap.runtime, prefix: bootstrap.prefix)
        }
    }
}

struct BootstrapOwnership: Codable {
    let runtime: URL
    let prefix: URL
}
