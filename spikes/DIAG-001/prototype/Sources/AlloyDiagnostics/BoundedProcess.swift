// Author: Timur Isaev

import Darwin
import Foundation

public enum CaptureError: Error, Equatable {
  case invalidConfiguration
  case timeout(String)
  case toolFailure(String)
  case missingEvidence(String)
}

struct CapturedProcess {
  let status: Int32
  let output: String
  let elapsedSeconds: Double
}

struct ProcessIdentity: Hashable {
  let pid: pid_t
  let startedSeconds: UInt64
  let startedMicroseconds: UInt64

  static func live(_ pid: pid_t) -> ProcessIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_status != SZOMB else { return nil }
    return ProcessIdentity(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
  }

  var isLive: Bool { Self.live(pid) == self }
}

// Observes cooperative synthetic children, including LLDB's separate-session
// debugserver/inferior. This bounded polling census is not a process sandbox:
// a hostile child could fork and reparent between observations.
final class OwnedProcessFamily {
  private let root: ProcessIdentity?
  private var identities = Set<ProcessIdentity>()
  private let maximum = 128

  var hasRootIdentity: Bool { root != nil }

  init(_ process: Process, identityLookup: (pid_t) -> ProcessIdentity? = ProcessIdentity.live) {
    root = identityLookup(process.processIdentifier)
    if let root { identities.insert(root) }
  }

  func refresh() throws {
    var queue = Array(identities)
    var visited = Set<ProcessIdentity>()
    while let identity = queue.popLast() {
      guard visited.insert(identity).inserted, identity.isLive else { continue }
      var pids = [pid_t](repeating: 0, count: maximum)
      let count = pids.withUnsafeMutableBytes {
        proc_listchildpids(identity.pid, $0.baseAddress, Int32($0.count))
      }
      guard count >= 0 else {
        if !identity.isLive { continue }
        throw CaptureError.toolFailure("capture-descendant-query")
      }
      guard count < maximum else {
        throw CaptureError.toolFailure("capture-descendant-limit")
      }
      for pid in pids.prefix(Int(count)) {
        guard let child = ProcessIdentity.live(pid) else { continue }
        guard identities.contains(child) || identities.count < maximum else {
          throw CaptureError.toolFailure("capture-descendant-limit")
        }
        if identities.insert(child).inserted { queue.append(child) }
      }
    }
  }

  func stop(_ process: Process) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + BoundedProcess.cleanupSeconds
    // Capture the latest children before killing the debugger that owns them.
    try? refresh()
    while true {
      let live = identities.filter(\.isLive)
      for identity in live where identity != root {
        if identity.isLive { kill(identity.pid, SIGKILL) }
      }
      if let root, root.isLive { kill(root.pid, SIGKILL) }
      // If the initial kernel identity query failed, capture never begins.
      // Foundation still owns this unreaped direct child; use its running
      // state only for this immediate launch-failure cleanup fallback.
      if root == nil, process.isRunning { kill(process.processIdentifier, SIGKILL) }
      if !process.isRunning && identities.allSatisfy({ !$0.isLive }) {
        process.waitUntilExit()
        return true
      }
      if ProcessInfo.processInfo.systemUptime >= deadline { return false }
      Thread.sleep(forTimeInterval: 0.005)
    }
  }
}

private struct PipeCapture {
  private var data = Data()
  private(set) var eof = false

  mutating func readAvailable(_ descriptor: Int32) throws {
    var chunk = [UInt8](repeating: 0, count: 4096)
    // Bound work per poll so a continuous producer cannot starve the timer.
    for _ in 0..<16 where !eof {
      let count = Darwin.read(descriptor, &chunk, chunk.count)
      if count > 0 {
        guard data.count + count <= BoundedProcess.outputLimit else {
          throw CaptureError.toolFailure("capture-output-limit")
        }
        data.append(contentsOf: chunk.prefix(count))
      } else if count == 0 {
        eof = true
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        break
      } else {
        throw CaptureError.toolFailure("capture-output-read")
      }
    }
  }

  func text() throws -> String {
    guard let output = String(data: data, encoding: .utf8) else {
      throw CaptureError.toolFailure("capture-invalid-utf8")
    }
    return output
  }
}

enum BoundedProcess {
  static let cleanupSeconds = 0.5
  static let outputLimit = 1_048_576

  static func withProcess<T>(
    _ process: Process,
    identityLookup: (pid_t) -> ProcessIdentity? = ProcessIdentity.live,
    body: (OwnedProcessFamily) throws -> T
  ) throws -> T {
    try process.run()
    let family = OwnedProcessFamily(process, identityLookup: identityLookup)
    let outcome: Result<T, Error>
    if !family.hasRootIdentity && process.isRunning {
      outcome = .failure(CaptureError.toolFailure("capture-identity-unavailable"))
    } else {
      outcome = Result { try body(family) }
    }
    guard family.stop(process) else { throw CaptureError.toolFailure("capture-cleanup-deadline") }
    return try outcome.get()
  }

  static func execute(_ executable: URL, arguments: [String], timeout: TimeInterval) throws -> CapturedProcess {
    guard timeout.isFinite, timeout > 0, timeout <= 20 else { throw CaptureError.invalidConfiguration }
    let start = ProcessInfo.processInfo.systemUptime
    let deadline = start + timeout
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    environment["TERM"] = "dumb"
    environment["SWIFT_BACKTRACE"] = "enable=no"
    process.environment = environment
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let descriptor = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw CaptureError.toolFailure("capture-pipe-configuration")
    }
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    let captured: (Int32, String) = try withProcess(process) { family in
      let output = try drain(
        process, family: family, descriptor: descriptor, deadline: deadline,
        timeoutLabel: executable.lastPathComponent
      )
      return (process.terminationStatus, output)
    }
    return CapturedProcess(
      status: captured.0,
      output: captured.1,
      elapsedSeconds: ProcessInfo.processInfo.systemUptime - start
    )
  }

  private static func drain(
    _ process: Process, family: OwnedProcessFamily, descriptor: Int32,
    deadline: TimeInterval, timeoutLabel: String
  ) throws -> String {
    var pipe = PipeCapture()
    while true {
      try family.refresh()
      try pipe.readAvailable(descriptor)
      if !process.isRunning && pipe.eof {
        process.waitUntilExit()
        return try pipe.text()
      }
      if ProcessInfo.processInfo.systemUptime >= deadline {
        throw CaptureError.timeout(process.isRunning ? timeoutLabel : "capture-pipe")
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
  }
}
