// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

@Suite("Host selectors")
struct HostTests {
    @Test func realMacMatchAndImpossibleHost() throws {
        let host = try HostCapabilities.current()
        #expect(host.memoryGiB == Int(ProcessInfo.processInfo.physicalMemory / (1 << 30)))
        #expect(!host.macOSBuild.isEmpty)
        var selector: [String: Any] = [
            "architecture": "arm64", "macos": ["min": host.macOS, "allowedBuilds": [host.macOSBuild]]
        ]
        // CI can report less than the schema's 8 GiB minimum. Test memory matching with fixed hosts below.
        // Headless CI can have no Metal device; do not invent a GPU family.
        if !host.gpuFamilies.isEmpty { selector["gpuFamilies"] = host.gpuFamilies }
        let matching = try JSONDecoder().decode(
            HostSelector.self, from: JSONSerialization.data(withJSONObject: selector)
        )
        #expect(try host.matches(matching) == (host.architecture == "arm64"))
        selector["macos"] = ["min": "99.0"]
        let impossible = try JSONDecoder().decode(
            HostSelector.self, from: JSONSerialization.data(withJSONObject: selector)
        )
        #expect(try !host.matches(impossible))
        print("Real host selector oracle: \(host.macOS) (\(host.macOSBuild)), "
            + "\(host.gpuFamilies), \(host.memoryGiB) GiB")
    }

    @Test(arguments: [7, 8, 32])
    func memoryClassesMatchExactly(memoryGiB: Int) throws {
        let host = HostCapabilities(
            architecture: "arm64", macOS: "15.1", macOSBuild: "24B1", gpuFamilies: [], memoryGiB: memoryGiB
        )
        for requiredMemory in [8, 32] {
            let selector = try JSONDecoder().decode(
                HostSelector.self,
                from: Data("""
                {"architecture":"arm64","macos":{},"memoryClassesGiB":[\(requiredMemory)]}
                """.utf8)
            )
            #expect(try host.matches(selector) == (memoryGiB == requiredMemory))
        }
    }

    @Test func normalizedIdentityAndVersionBoundaries() throws {
        let host = HostCapabilities(
            architecture: "arm64", macOS: "15.1", macOSBuild: "24B1", gpuFamilies: ["apple9", "apple8"], memoryGiB: 32
        )
        var reordered = host
        reordered.macOS = "15.1.0"
        reordered.gpuFamilies = ["apple8", "apple9", "apple9"]
        #expect(try host.localClassId() == reordered.localClassId())
        #expect(try host.localClassId().hasPrefix("local-unregistered:"))
        reordered.macOSBuild = "24B2"
        #expect(try host.localClassId() != reordered.localClassId())
        for (text, matches) in [
            (#"{"architecture":"arm64","macos":{"min":"15.1","maxExclusive":"15.2"}}"#, true),
            (#"{"architecture":"arm64","macos":{"maxExclusive":"15.1"}}"#, false),
            (#"{"architecture":"arm64","macos":{"allowedBuilds":["different"]}}"#, false),
            (#"{"architecture":"arm64","macos":{},"gpuFamilies":["apple99"]}"#, false),
            (#"{"architecture":"arm64","macos":{},"memoryClassesGiB":[128]}"#, false)
        ] {
            let selector = try JSONDecoder().decode(HostSelector.self, from: Data(text.utf8))
            #expect(try host.matches(selector) == matches)
        }
        #expect(try SemanticVersion("15.10") > SemanticVersion("15.9"))
        #expect(throws: (any Error).self) { try SemanticVersion("15.beta") }
    }
}
