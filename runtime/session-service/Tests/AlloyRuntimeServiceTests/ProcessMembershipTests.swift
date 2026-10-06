// Author: Timur Isaev

import AlloyRuntimeAPI
import Foundation
import Testing
@testable import AlloyRuntimeService

private final class MembershipTestBundle: NSObject {}

@Test func kernelProcessMembershipRejectsUnrelatedProcesses() throws {
    let process = Process()
    // macOS hides the environment of protected system executables such as
    // /bin/sleep. Our fixed first-party agent waits on its control pipe before
    // it reads any session records or starts another process.
    let executable = Bundle(for: MembershipTestBundle.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("alloy-session-agent")
    let prefix = URL(fileURLWithPath: "/private/tmp/alloy-membership-fixture")
    let control = Pipe()
    process.executableURL = executable
    process.arguments = [prefix.path]
    process.environment = ["WINEPREFIX": prefix.path]
    process.standardInput = control
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        try? control.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    let identity = WineProcessMembership.observe(process.processIdentifier, executable: executable, prefix: prefix)
    #expect(identity == NativeProcessIdentity.current(process.processIdentifier))
    #expect(identity != nil)
    #expect(WineProcessMembership.observe(process.processIdentifier,
        executable: URL(fileURLWithPath: "/bin/sh"), prefix: prefix) == nil)
    #expect(WineProcessMembership.observe(process.processIdentifier,
        executable: executable, prefix: URL(fileURLWithPath: "/private/tmp/different-prefix")) == nil)
}

@Test func processMembershipReadsEnvironmentAfterWineArgumentPadding() {
    let executable = URL(fileURLWithPath: "/private/tmp/alloy-membership-fixture/loader/wine")
    let prefix = URL(fileURLWithPath: "/private/tmp/alloy-membership-fixture/prefix")
    func procargs(arguments: String, environment: String) -> [UInt8] {
        var argc: Int32 = 2
        let header = withUnsafeBytes(of: &argc) { Array($0) }
        return header + Array((executable.path + "\0\0\0" + arguments + environment).utf8)
    }
    let padded = procargs(arguments: "G:\\game.exe\0" + String(repeating: "\0", count: 128),
                          environment: "WINEPREFIX=" + prefix.path + "\0\0")
    #expect(WineProcessMembership.matchesProcargs(padded, count: padded.count,
        executable: executable, prefix: prefix))
    #expect(!WineProcessMembership.matchesProcargs(padded, count: padded.count,
        executable: executable, prefix: prefix.appendingPathComponent("unrelated")))
    #expect(!WineProcessMembership.matchesProcargs(padded, count: padded.count,
        executable: executable.appendingPathExtension("unrelated"), prefix: prefix))
    let argumentOnly = procargs(arguments: "wine\0WINEPREFIX=" + prefix.path + "\0",
                               environment: "LANG=C\0\0")
    #expect(!WineProcessMembership.matchesProcargs(argumentOnly, count: argumentOnly.count,
        executable: executable, prefix: prefix))
    let missing = procargs(arguments: "G:\\game.exe\0" + String(repeating: "\0", count: 128),
                           environment: "")
    #expect(!WineProcessMembership.matchesProcargs(missing, count: missing.count,
        executable: executable, prefix: prefix))
    #expect(!WineProcessMembership.matchesProcargs(padded, count: padded.count - 2,
        executable: executable, prefix: prefix))
}
