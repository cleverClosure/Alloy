// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@Suite("Opt-in parser runner timeout control")
struct ParserFuzzTimeoutControlTests {
    @Test("the production Swift runner must stop a stuck test process")
    func deliberateHang() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ALLOY_FUZZ_CONTROL"] == "runner-hang" else { return }
        let path = try #require(environment["ALLOY_FUZZ_HEARTBEAT"])
        let destination = URL(fileURLWithPath: path)
        var counter: UInt64 = 0
        while true {
            counter += 1
            let heartbeat = "\(getpid()) \(counter)\n"
            try Data(heartbeat.utf8).write(to: destination, options: .atomic)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
