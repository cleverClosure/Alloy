// Author: Timur Isaev

import Darwin
import Foundation

@inline(never)
func seededNativeCrash() {
  fatalError("DIAG_SEEDED_NATIVE_CRASH")
}

@inline(never)
func seededNativeDeadlock(ready: String) throws {
  let gate = DispatchSemaphore(value: 0)
  try Data("ready\n".utf8).write(to: URL(fileURLWithPath: ready))
  gate.wait()
}

func heartbeat(_ path: String) throws -> Never {
  let url = URL(fileURLWithPath: path)
  var count = 0
  while true {
    try Data("\(getpid()) \(count)\n".utf8).write(to: url, options: .atomic)
    count += 1
    Thread.sleep(forTimeInterval: 0.01)
  }
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "crash":
  seededNativeCrash()
case "hang":
  guard arguments.count == 3 else { fatalError("missing synthetic readiness path") }
  try seededNativeDeadlock(ready: arguments[2])
case "clean", "fast":
  print("DIAG_CLEAN_EXIT")
case "ready-failure":
  guard arguments.count == 3 else { exit(64) }
  try Data("ready\n".utf8).write(to: URL(fileURLWithPath: arguments[2]))
  Thread.sleep(forTimeInterval: 0.02)
  exit(23)
case "heartbeat":
  guard arguments.count == 3 else { exit(64) }
  try heartbeat(arguments[2])
case "pipe-descendant":
  guard arguments.count == 3 else { exit(64) }
  let child = Process()
  child.executableURL = URL(fileURLWithPath: arguments[0])
  child.arguments = ["heartbeat", arguments[2]]
  try child.run()
  // The cooperative parent stays observable long enough for the capture
  // monitor to discover its child, then exits while that child retains stdout.
  Thread.sleep(forTimeInterval: 0.15)
case "flood":
  try FileHandle.standardOutput.write(contentsOf: Data(repeating: 65, count: 1_048_577))
default:
  fatalError("unknown synthetic subject mode")
}
