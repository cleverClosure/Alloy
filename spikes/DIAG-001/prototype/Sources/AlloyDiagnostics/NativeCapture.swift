// Author: Timur Isaev

import Foundation

public enum SyntheticSubjectMode: String, Codable, Sendable {
  case clean
  case crash
  case hang
  case fast
  case readyFailure = "ready-failure"
}

public struct NativeCaptureReport: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case crash
    case hang
  }

  public let kind: Kind
  public let correlation: CorrelationID
  public let tool: String
  public let reason: String
  public let symbolicatedText: String
  public let elapsedSeconds: Double
}

public struct NativeCapture {
  public let executable: URL
  public let timeoutSeconds: TimeInterval

  public init(executable: URL, timeoutSeconds: TimeInterval = 10) throws {
    guard executable.isFileURL, timeoutSeconds.isFinite,
          timeoutSeconds >= 0.1, timeoutSeconds <= 20,
          FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw CaptureError.invalidConfiguration
    }
    self.executable = executable
    self.timeoutSeconds = timeoutSeconds
  }

  public func crash(mode: SyntheticSubjectMode, correlation: CorrelationID) throws -> NativeCaptureReport? {
    guard mode == .crash || mode == .clean else { throw CaptureError.invalidConfiguration }
    let result = try BoundedProcess.execute(
      URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: [
        "lldb", "--batch", "--no-lldbinit", "--no-use-colors",
        "-o", "run", "-k", "thread backtrace all", "-k", "process kill",
        "--", executable.path, mode.rawValue
      ],
      timeout: timeoutSeconds
    )
    guard result.status == 0 else { throw CaptureError.toolFailure("lldb") }
    guard result.output.contains("stop reason =") else {
      guard result.output.contains("exited with status = 0") else {
        throw CaptureError.missingEvidence("lldb-exit-or-stop")
      }
      return nil
    }
    guard result.output.contains("seededNativeCrash()"),
          result.output.contains("DIAG_SEEDED_NATIVE_CRASH"),
          result.output.contains("frame #") else {
      throw CaptureError.missingEvidence("symbolicated-crash-site")
    }
    return NativeCaptureReport(
      kind: .crash, correlation: correlation, tool: "Xcode LLDB",
      reason: "fatal-error-at-seededNativeCrash", symbolicatedText: result.output,
      elapsedSeconds: result.elapsedSeconds
    )
  }

  public func hang(mode: SyntheticSubjectMode, correlation: CorrelationID) throws -> NativeCaptureReport? {
    guard mode == .hang || mode == .fast || mode == .readyFailure else { throw CaptureError.invalidConfiguration }
    let started = ProcessInfo.processInfo.systemUptime
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let ready = scratch.appendingPathComponent("ready")
    let child = Process()
    child.executableURL = executable
    child.arguments = [mode.rawValue, ready.path]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    let captured: String? = try BoundedProcess.withProcess(child) { family in
      guard try awaitReadiness(child, family: family, ready: ready, deadline: started + timeoutSeconds) else {
        return nil
      }
      let snapshot = scratch.appendingPathComponent("sample.txt")
      let remaining = timeoutSeconds - (ProcessInfo.processInfo.systemUptime - started)
      guard remaining > 1 else { throw CaptureError.timeout("hang-snapshot") }
      let sampled = try BoundedProcess.execute(
        URL(fileURLWithPath: "/usr/bin/sample"),
        arguments: [String(child.processIdentifier), "1", "1", "-mayDie", "-file", snapshot.path],
        timeout: remaining
      )
      guard sampled.status == 0 else { throw CaptureError.toolFailure("sample") }
      let size = try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 1_048_576 else { throw CaptureError.toolFailure("sample-output-limit") }
      let stack = try String(contentsOf: snapshot, encoding: .utf8)
      guard stack.contains("seededNativeDeadlock"), stack.contains("semaphore_wait") else {
        throw CaptureError.missingEvidence("symbolicated-deadlock-site")
      }
      return stack
    }
    guard let stack = captured else { return nil }
    return NativeCaptureReport(
      kind: .hang, correlation: correlation, tool: "macOS sample",
      reason: "blocked-at-seededNativeDeadlock", symbolicatedText: stack,
      elapsedSeconds: ProcessInfo.processInfo.systemUptime - started
    )
  }

  private func awaitReadiness(
    _ process: Process, family: OwnedProcessFamily, ready: URL, deadline: Double
  ) throws -> Bool {
    while process.isRunning {
      try family.refresh()
      if FileManager.default.fileExists(atPath: ready.path) {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw CaptureError.timeout("subject-readiness") }
        Thread.sleep(forTimeInterval: min(0.05, remaining))
        if !process.isRunning { break }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          throw CaptureError.timeout("subject-readiness")
        }
        return true
      }
      if ProcessInfo.processInfo.systemUptime >= deadline { throw CaptureError.timeout("subject-readiness") }
      Thread.sleep(forTimeInterval: 0.005)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CaptureError.toolFailure("subject-exit") }
    return false
  }
}
