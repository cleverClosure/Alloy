// Author: Timur Isaev
import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation

@main struct FixtureMain {
    static func main() {
        umask(0o077)
        // Stop is a control-pipe action. Ignoring TERM exercises bounded KILL
        // escalation; parent death still closes the pipe and triggers cleanup.
        signal(SIGTERM, SIG_IGN)
        do { exit(try run()) } catch { exit(42) }
    }

    static func run() throws -> Int32 {
        let args = CommandLine.arguments
        guard args.count == 4, ["agent", "child", "grandchild"].contains(args[1]) else {
            throw RuntimeFailure.status(.malformed)
        }
        let name = args[1]
        let directory = URL(fileURLWithPath: args[2])
        let content = URL(fileURLWithPath: args[3])
        let record = try PrivateRecords.read(FixtureSessionRecord.self,
                                            from: directory.appendingPathComponent("request.json"))
        let executable = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
        guard try ContentStore.digest(Data(contentsOf: executable)) == record.fixtureDigest else {
            throw RuntimeFailure.status(.conflict)
        }
        if record.request.scenario == .startupFailure { exit(42) }
        let store = try ContentStore(root: content)
        let lease = try store.acquireLease(gameID: record.preview.specification.gameId,
                                           generation: record.preview.generation)
        defer { try? store.releaseLease(lease) }
        let nodeURL = directory.appendingPathComponent(name + ".json")
        try PrivateRecords.write(FixtureNode(name: name, state: "RUNNING", lease: lease), to: nodeURL)
        let child = try startChild(name: name, executable: executable, directory: directory, content: content)
        let started = DispatchTime.now().uptimeNanoseconds
        var timedOut = false
        while true {
            var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&input, 1, 25)
            if ready > 0 {
                var byte: UInt8 = 0
                let count = read(STDIN_FILENO, &byte, 1)
                if count <= 0 || byte == 83 { break }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            if record.request.scenario == .normal && elapsed >= 0.5 { break }
            if elapsed >= 20 {
                timedOut = true
                break
            }
        }
        var escalated = false
        if let child {
            escalated = try finish(child, force: record.request.scenario == .ignoreTermination)
        }
        let state = timedOut ? "EXITED_WATCHDOG" : (escalated ? "EXITED_ESCALATED" : "EXITED")
        let final = FixtureNode(name: name, state: state, lease: lease)
        try PrivateRecords.write(final, to: nodeURL)
        return timedOut ? 43 : 0
    }

    private struct Child {
        let process: Process
        let control: Pipe
        let identity: LeaseProcessIdentity
    }

    private static func startChild(name: String, executable: URL, directory: URL, content: URL) throws -> Child? {
        guard name != "grandchild" else { return nil }
        let process = Process()
        let control = Pipe()
        process.executableURL = executable
        process.arguments = [name == "agent" ? "child" : "grandchild", directory.path, content.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = control
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard let identity = NativeProcessIdentity.current(process.processIdentifier) else {
            try? control.fileHandleForWriting.close()
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
            throw RuntimeFailure.status(.failed)
        }
        return Child(process: process, control: control, identity: identity)
    }

    private static func finish(_ child: Child, force: Bool) throws -> Bool {
        if !force { try child.control.fileHandleForWriting.close() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        if force, child.process.isRunning, NativeProcessIdentity.isLive(child.identity) {
            kill(child.process.processIdentifier, SIGTERM)
        }
        while child.process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
        var escalated = false
        if child.process.isRunning, NativeProcessIdentity.isLive(child.identity) {
            kill(child.process.processIdentifier, SIGKILL)
            escalated = true
        }
        try? child.control.fileHandleForWriting.close()
        let killDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while child.process.isRunning && DispatchTime.now().uptimeNanoseconds < killDeadline { usleep(10_000) }
        guard !child.process.isRunning else { throw RuntimeFailure.status(.failed) }
        return escalated
    }
}
