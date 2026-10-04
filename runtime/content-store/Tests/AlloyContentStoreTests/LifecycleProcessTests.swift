// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private func lifecycleProbe(_ command: String, root: URL, fault: String? = nil) throws -> Int32 {
    let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = package.appendingPathComponent(".build/debug/alloy-content-store-fault-probe")
    process.arguments = [command, root.path]
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "ALLOY_FAULT_AFTER")
    if let fault { environment["ALLOY_FAULT_AFTER"] = fault }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(15)
    while process.isRunning, Date() < deadline { usleep(10_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus != 0, process.terminationStatus != 97 {
        Issue.record("lifecycle probe failed: \(String(bytes: data, encoding: .utf8) ?? "non-UTF8 output")")
    }
    return process.terminationStatus
}

private func removeLifecycleFixture(_ root: URL) {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { chmod(url.path, S_IRWXU) }
    }
    try? FileManager.default.removeItem(at: root)
}

@Suite("lifecycle process-death recovery", .serialized)
struct LifecycleProcessTests {
    @Test("abrupt exits recover every activation boundary without rotating rollback",
          arguments: ContentStore.faultPoints)
    func activation(point: String) throws {
        try runProof(kind: "update", point: point)
    }

    @Test("abrupt exits recover every repair boundary including unsealed directory state",
          arguments: ContentStore.repairFaultPoints)
    func repair(point: String) throws {
        try runProof(kind: "repair", point: point)
    }

    @Test("abrupt exits recover every uninstall boundary while preserving saves",
          arguments: ContentStore.uninstallFaultPoints)
    func uninstall(point: String) throws {
        try runProof(kind: "uninstall", point: point)
    }

    private func runProof(kind: String, point: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-lifecycle-death-\(UUID())")
        defer { removeLifecycleFixture(root) }
        #expect(try lifecycleProbe("lifecycle-bootstrap", root: root) == 0)
        if kind == "repair" {
            #expect(try lifecycleProbe("lifecycle-corrupt", root: root) == 0)
        }
        #expect(try lifecycleProbe("lifecycle-\(kind)", root: root, fault: point) == 97)
        #expect(try lifecycleProbe("lifecycle-verify-\(kind)", root: root) == 0)
    }
}
