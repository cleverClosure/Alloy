// Author: Timur Isaev

import AlloyRuntimeService
import Darwin
import Foundation

umask(0o077)
signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments
let executable = URL(fileURLWithPath: arguments[0])
if arguments.count == 3, arguments[1] == "--server" {
    exit(WineServerGate.run(directory: URL(fileURLWithPath: arguments[2]), executable: executable))
}
guard arguments.count == 2 else { exit(64) }
exit(WineAgent.run(directory: URL(fileURLWithPath: arguments[1]), executable: executable))
