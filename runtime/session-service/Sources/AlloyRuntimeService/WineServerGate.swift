// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation

/// Exec preserves the leased kernel birth identity. EOF before durable ownership
/// makes this child exit without ever starting Wine or opening a server socket.
public enum WineServerGate {
    public static func run(directory: URL, executable: URL) -> Int32 {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1, byte == 71 else { return 42 }
        do {
            let record = try PrivateRecords.read(WineSessionRecord.self,
                from: directory.appendingPathComponent("request.json"))
            let ownership = try PrivateRecords.read(WineOwnership.self,
                from: directory.appendingPathComponent("ownership.json"))
            guard ownership.serverLease.holder.processID == getpid(),
                  try ContentStore.digest(Data(contentsOf: executable)) == record.agentDigest else { return 42 }
            try LiveGenerationLease.require(ownership.serverLease, contentRoot: record.contentRoot)
            if record.fault == "wine.unresponsive-server" {
                // Fault control: an unresponsive server must reach native kill.
                // Signal masks survive exec; ordinary guests are separate children.
                var blocked = sigset_t()
                sigemptyset(&blocked)
                sigaddset(&blocked, SIGINT)
                guard sigprocmask(SIG_BLOCK, &blocked, nil) == 0 else { return 42 }
            }
            let server = ownership.runtime.appendingPathComponent("server/wineserver")
            let values: [String] = [server.path, "-f", "-p", "-d"]
            var arguments: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
            arguments.append(nil)
            defer { arguments.forEach { free($0) } }
            arguments.withUnsafeMutableBufferPointer { _ = execv(server.path, $0.baseAddress!) }
        } catch { return 42 }
        return 42
    }
}
