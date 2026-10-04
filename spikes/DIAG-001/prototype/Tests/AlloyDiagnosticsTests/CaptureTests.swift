// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyDiagnostics

@Suite("Synthetic native capture", .serialized)
struct CaptureTests {
  private func correlation() throws -> CorrelationID {
    let fixture = try #require(Bundle.module.url(
      forResource: "event-v1", withExtension: "json", subdirectory: "Fixtures"
    ))
    return try JSONDecoder().decode(StructuredEvent.self, from: Data(contentsOf: fixture)).correlation
  }

  private func capture() throws -> NativeCapture {
    let package = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try NativeCapture(executable: package.appendingPathComponent(".build/debug/AlloyDiagnosticsSubject"))
  }

  private func temporaryDirectory() throws -> URL {
    let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    return result
  }

  private func assertHeartbeatStopped(_ path: URL) throws {
    let before = try Data(contentsOf: path)
    let fields = try #require(String(data: before, encoding: .utf8)).split(separator: " ")
    let first = try #require(fields.first)
    let last = try #require(fields.last)
    let pid = try #require(Int32(first))
    let count = try #require(Int(last.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(count > 0)
    #expect(ProcessIdentity.live(pid) == nil)
    Thread.sleep(forTimeInterval: 0.1)
    #expect(try Data(contentsOf: path) == before)
  }

  @Test("An actual crash is symbolicated and clean exit has no report")
  func crashAndClean() throws {
    let identity = try correlation()
    let subject = try capture()
    let crash = try #require(try subject.crash(mode: .crash, correlation: identity))
    #expect(crash.kind == .crash)
    #expect(crash.correlation == identity)
    #expect(crash.symbolicatedText.contains("seededNativeCrash()"))
    #expect(crash.symbolicatedText.contains("DIAG_SEEDED_NATIVE_CRASH"))
    #expect(crash.symbolicatedText.contains("main.swift:"))
    #expect(crash.symbolicatedText.contains("stop reason ="))
    #expect(crash.symbolicatedText.contains("killed"))
    #expect(crash.elapsedSeconds > 0 && crash.elapsedSeconds < 10)
    #expect(try subject.crash(mode: .clean, correlation: identity) == nil)
  }

  @Test("A blocked native thread is sampled and fast exit has no snapshot")
  func hangAndFast() throws {
    let identity = try correlation()
    let subject = try capture()
    let hang = try #require(try subject.hang(mode: .hang, correlation: identity))
    #expect(hang.kind == .hang)
    #expect(hang.correlation == identity)
    #expect(hang.symbolicatedText.contains("seededNativeDeadlock"))
    #expect(hang.symbolicatedText.contains("semaphore_wait"))
    #expect(hang.elapsedSeconds > 0 && hang.elapsedSeconds < 10)
    #expect(try subject.hang(mode: .fast, correlation: identity) == nil)
  }

  @Test("Tool timeout is bounded and invalid setup is rejected")
  func timeoutAndSetup() throws {
    let started = ProcessInfo.processInfo.systemUptime
    #expect(throws: CaptureError.timeout("sleep")) {
      try BoundedProcess.execute(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
    }
    #expect(ProcessInfo.processInfo.systemUptime - started < 0.1 + BoundedProcess.cleanupSeconds + 0.5)
    #expect(throws: CaptureError.invalidConfiguration) {
      try NativeCapture(executable: URL(fileURLWithPath: "/does-not-exist"))
    }
  }

  @Test("A ready subject exiting nonzero is never a clean fast control")
  func readyFailure() throws {
    let subject = try capture()
    let identity = try correlation()
    #expect(throws: CaptureError.toolFailure("subject-exit")) {
      try subject.hang(mode: .readyFailure, correlation: identity)
    }
  }

  @Test("A real output flood fires the byte cap")
  func outputLimit() throws {
    let subject = try capture()
    let started = ProcessInfo.processInfo.systemUptime
    #expect(throws: CaptureError.toolFailure("capture-output-limit")) {
      try BoundedProcess.execute(subject.executable, arguments: ["flood"], timeout: 2)
    }
    #expect(ProcessInfo.processInfo.systemUptime - started < 2 + BoundedProcess.cleanupSeconds)
  }

  @Test("Unavailable initial process identity fails closed and reaps the direct child")
  func missingProcessIdentity() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["10"]
    #expect(throws: CaptureError.toolFailure("capture-identity-unavailable")) {
      try BoundedProcess.withProcess(child, identityLookup: { _ in nil }, body: { _ in
        Issue.record("capture body must not run without the initial process identity")
      })
    }
    #expect(!child.isRunning)
    #expect(ProcessIdentity.live(child.processIdentifier) == nil)
  }

  @Test("An inherited pipe uses the original deadline and its descendant is removed")
  func inheritedPipe() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let heartbeat = directory.appendingPathComponent("heartbeat")
    let subject = try capture()
    let started = ProcessInfo.processInfo.systemUptime
    #expect(throws: CaptureError.timeout("capture-pipe")) {
      try BoundedProcess.execute(subject.executable, arguments: ["pipe-descendant", heartbeat.path], timeout: 0.5)
    }
    #expect(ProcessInfo.processInfo.systemUptime - started < 0.5 + BoundedProcess.cleanupSeconds + 0.5)
    try assertHeartbeatStopped(heartbeat)
  }

  @Test("LLDB timeout removes its separately grouped hanging inferior")
  func debuggerTimeoutCleanup() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let heartbeat = directory.appendingPathComponent("heartbeat")
    let subject = try capture()
    let started = ProcessInfo.processInfo.systemUptime
    #expect(throws: CaptureError.timeout("xcrun")) {
      try BoundedProcess.execute(
        URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: [
          "lldb", "--batch", "--no-lldbinit", "--no-use-colors", "-o", "run", "--",
          subject.executable.path, "heartbeat", heartbeat.path
        ],
        timeout: 3
      )
    }
    #expect(ProcessInfo.processInfo.systemUptime - started < 3 + BoundedProcess.cleanupSeconds + 0.5)
    try assertHeartbeatStopped(heartbeat)
  }
}
