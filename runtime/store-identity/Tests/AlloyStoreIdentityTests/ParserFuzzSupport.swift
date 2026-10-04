// Author: Timur Isaev

import Foundation

struct ParserFuzzSettings {
    let seed: UInt64
    let iterations: Int
    let deadline: ContinuousClock.Instant

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let seed = UInt64(environment["ALLOY_FUZZ_SEED"] ?? "1060001"),
              let iterations = Int(environment["ALLOY_FUZZ_ITERATIONS"] ?? "128"),
              (1...1_000).contains(iterations) else {
            throw ParserFuzzError.invalidConfiguration
        }
        self.seed = seed
        self.iterations = iterations
        deadline = ContinuousClock.now.advanced(by: .seconds(20))
    }

    func checkDeadline() throws {
        guard ContinuousClock.now < deadline else { throw ParserFuzzError.timeBudgetExceeded }
    }
}
enum ParserFuzzError: Error {
    case invalidConfiguration
    case timeBudgetExceeded
}

struct ParserFuzzRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    mutating func mutate(_ original: Data) -> Data {
        var bytes = Array(original.prefix(4_096))
        switch next() % 4 {
        case 0:
            if !bytes.isEmpty { bytes[Int(next() % UInt64(bytes.count))] ^= UInt8(1 + next() % 255) }
        case 1:
            if !bytes.isEmpty { bytes.removeSubrange(Int(next() % UInt64(bytes.count))..<bytes.count) }
        case 2:
            let offset = Int(next() % UInt64(bytes.count + 1))
            bytes.insert(UInt8(next() % 256), at: offset)
        default:
            bytes = (0..<Int(next() % 256)).map { _ in UInt8(next() % 256) }
        }
        return Data(bytes)
    }
}
