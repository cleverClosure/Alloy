// Author: Timur Isaev

import AlloyRuntimeService
import Darwin
import Foundation

umask(0o077)
signal(SIGPIPE, SIG_IGN)
guard CommandLine.arguments.count == 2 else { exit(64) }
exit(WineAgent.run(directory: URL(fileURLWithPath: CommandLine.arguments[1]),
                   executable: URL(fileURLWithPath: CommandLine.arguments[0])))
