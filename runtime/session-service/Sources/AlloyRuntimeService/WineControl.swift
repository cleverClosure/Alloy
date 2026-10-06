// Author: Timur Isaev

import AlloyRuntimeAPI
import Darwin
import Foundation

/// Only fixed Wine control commands. Guest launch and process supervision have separate ownership.
public enum WineControl {
    public static func bootstrap(runtime: URL, prefix: URL) throws {
        let environment = SessionEnvironment.scrubbed(runtime: runtime, prefix: prefix)
        // Wineboot creates a fresh private prefix; it never receives session policy.
        let loader = runtime.appendingPathComponent("loader/wine")
        do {
            guard try run(loader, arguments: ["wineboot", "-u"], environment: environment, seconds: 60) == 0 else {
                throw RuntimeFailure.status(.failed)
            }
            try wait(runtime: runtime, environment: environment)
            guard try run(loader, arguments: ["wineboot", "-r"], environment: environment, seconds: 30) == 0 else {
                throw RuntimeFailure.status(.failed)
            }
            try wait(runtime: runtime, environment: environment)
        } catch {
            try? stop(runtime: runtime, prefix: prefix)
            throw error
        }
    }

    private static func wait(runtime: URL, environment: [String: String]) throws {
        // Bootstrap can leave registration children after wineboot exits. Killing
        // that server would cache a race-dependent, partially registered prefix.
        guard try run(runtime.appendingPathComponent("server/wineserver"), arguments: ["-w"],
                      environment: environment, seconds: 45) == 0 else { throw RuntimeFailure.status(.failed) }
    }

    public static func stop(runtime: URL, prefix: URL) throws {
        let environment = SessionEnvironment.scrubbed(runtime: runtime, prefix: prefix)
        let server = runtime.appendingPathComponent("server/wineserver")
        let status = try run(server, arguments: ["-k"], environment: environment, seconds: 3)
        guard [0, 1].contains(status),
              try run(server, arguments: ["-w"], environment: environment, seconds: 5) == 0 else {
            throw RuntimeFailure.status(.failed)
        }
    }

    static func run(_ executable: URL, arguments: [String], environment: [String: String],
                    seconds: Double) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: environment["WINEPREFIX"]!)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let identity = NativeProcessIdentity.current(process.processIdentifier)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
        if process.isRunning {
            if let identity, NativeProcessIdentity.isLive(identity) { kill(identity.processID, SIGKILL) }
            let killDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < killDeadline { usleep(10_000) }
            throw RuntimeFailure.status(.expired)
        }
        return process.terminationStatus
    }
}
