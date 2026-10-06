// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation
import Testing
@testable import AlloyRuntimeService

@Test func payloadMustMatchItsPEMachineAndCannotBeANativeExecutable() throws {
    var bytes = Data(repeating: 0, count: 256)
    bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[0x3c] = 128
    bytes[128] = 0x50; bytes[129] = 0x45
    bytes[132] = 0x64; bytes[133] = 0x86; bytes[150] = 2
    func hash(_ value: Data) -> String { String(ContentStore.digest(value).dropFirst(7)) }
    try GuestImage.verify(bytes, machine: .x64, digest: hash(bytes))
    #expect(throws: RuntimeFailure.status(.payloadIntegrity)) {
        try GuestImage.verify(bytes, machine: .arm64, digest: hash(bytes))
    }
    bytes[151] = 0x20
    #expect(throws: RuntimeFailure.status(.payloadIntegrity)) {
        try GuestImage.verify(bytes, machine: .x64, digest: hash(bytes))
    }
    let native = try Data(contentsOf: URL(fileURLWithPath: "/bin/sh"))
    #expect(throws: RuntimeFailure.status(.payloadIntegrity)) {
        try GuestImage.verify(native, machine: .arm64, digest: hash(native))
    }
}

@Test func policyDescriptorIsReadOnlyUnlinkedAndInherited() throws {
    let root = URL(fileURLWithPath: "/private/tmp/policy-" + UUID().uuidString)
    try privateDirectory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("known snapshot bytes".utf8)
    let digest = ContentStore.digest(bytes)
    let policy = try PolicyDescriptor(bytes: bytes, expectedDigest: digest, directory: root)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    #expect(fcntl(policy.descriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
    let written = bytes.withUnsafeBytes { Darwin.write(policy.descriptor, $0.baseAddress, $0.count) }
    #expect(written == -1)
    let environment = policy.environment(["PATH": "/usr/bin:/bin"])
    #expect(environment["ALLOY_POLICY_REQUIRED"] == "1")
    #expect(environment["ALLOY_POLICY_SNAPSHOT_SHA256"] == String(digest.dropFirst(7)))
    let logURL = root.appendingPathComponent("observed")
    let log = open(logURL.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
    guard log >= 0 else { throw RuntimeFailure.status(.failed) }
    defer { close(log) }
    let child = try SpawnedWine.start(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "sleep 0.1; /bin/cat /dev/fd/198"],
        environment: ["PATH": "/usr/bin:/bin"], policy: policy, log: log)
    var code: Int32?
    let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    while code == nil && DispatchTime.now().uptimeNanoseconds < deadline { code = child.pollExit(); usleep(10_000) }
    if code == nil, NativeProcessIdentity.isLive(child.identity) { kill(child.processID, SIGKILL) }
    #expect(code == 0)
    #expect(try Data(contentsOf: logURL) == bytes)
    #expect(!NativeProcessIdentity.mayStillBeLive(child.identity))
    #expect(throws: RuntimeFailure.status(.policyIntegrity)) {
        try PolicyDescriptor(bytes: bytes + Data([0]), expectedDigest: digest, directory: root)
    }
}
