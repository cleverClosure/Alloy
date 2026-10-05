// Author: Timur Isaev
import Darwin
import Foundation

extension NativeCapture {
  /// Borrows an already-owned native process. Caller proves ownership; this
  /// primitive rechecks the exact kernel identity and never signals that process.
  public static func sampleOwned(
    processID: Int32, startedSeconds: UInt64, startedMicroseconds: UInt64,
    correlation: CorrelationID, timeoutSeconds: TimeInterval = 5
  ) throws -> NativeCaptureReport {
    guard timeoutSeconds >= 2, timeoutSeconds <= 10 else { throw CaptureError.invalidConfiguration }
    let identity = ProcessIdentity(pid: processID, startedSeconds: startedSeconds,
                                   startedMicroseconds: startedMicroseconds)
    guard identity.isLive else { throw CaptureError.missingEvidence("owned-process-identity") }
    let started = ProcessInfo.processInfo.systemUptime
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let output = scratch.appendingPathComponent("sample.txt")
    guard FileManager.default.createFile(atPath: output.path, contents: Data(),
                                          attributes: [.posixPermissions: 0o600]) else {
      throw CaptureError.toolFailure("sample-scratch")
    }
    let result = try BoundedProcess.execute(
      URL(fileURLWithPath: "/usr/bin/sample"),
      arguments: [String(processID), "1", "1", "-mayDie", "-file", output.path], timeout: timeoutSeconds)
    guard result.status == 0, identity.isLive else { throw CaptureError.missingEvidence("owned-sample-incomplete") }
    let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 1_048_576 else { throw CaptureError.toolFailure("sample-output-limit") }
    let text = try String(contentsOf: output, encoding: .utf8)
    return NativeCaptureReport(kind: .hang, correlation: correlation, tool: "macOS sample",
                               reason: "sampled-owned-native-process", symbolicatedText: text,
                               elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
  }
}
