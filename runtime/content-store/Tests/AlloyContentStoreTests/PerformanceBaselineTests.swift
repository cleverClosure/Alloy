// Author: Timur Isaev

import Foundation
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ALLOY_PERF_OUTPUT"] != nil))
struct PerformanceBaselineTests {
    @Test("bounded content-store performance samples retain exact correctness controls")
    func collectSamples() throws {
        let environment = ProcessInfo.processInfo.environment
        let output = try #require(environment["ALLOY_PERF_OUTPUT"])
        let iterations = Int(environment["ALLOY_PERF_ITERATIONS"] ?? "3") ?? 3
        try #require((1...3).contains(iterations))
        let selected = environment["ALLOY_PERF_CASE"]
        var samples: [PerformanceSample] = []
        for iteration in 0..<iterations {
            for count in [10, 100] where selected == nil || selected == "gc-\(count)" {
                samples.append(try garbageCollectionPerformance(count: count, iteration: iteration))
            }
            for count in [10, 100, 1_000] where selected == nil || selected == "catalog-\(count)" {
                samples.append(try catalogPerformance(count: count, iteration: iteration))
            }
            for resume in [false, true] {
                let id = resume ? "transport-resume" : "transport-fresh"
                if selected == nil || selected == id {
                    samples.append(try transportPerformance(resume: resume, iteration: iteration))
                }
            }
        }
        try #require(!samples.isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("PERF_SAMPLES count=\(samples.count) iterations=\(iterations)")
    }
}
