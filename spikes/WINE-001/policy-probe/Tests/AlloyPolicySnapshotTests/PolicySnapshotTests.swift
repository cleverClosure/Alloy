// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyPolicySnapshot

struct PolicySnapshotTests {
    @Test
    func deterministicAcrossSemanticOrdering() throws {
        let first = try PolicySnapshotCompiler.compile(
            source: source(processesReversed: false, routesReversed: false)
        )
        let second = try PolicySnapshotCompiler.compile(
            source: source(processesReversed: true, routesReversed: true)
        )

        #expect(first == second)
        #expect(first.count == SnapshotFormat.headerSize + 3 * SnapshotFormat.entrySize)
        #expect(
            PolicySnapshotCompiler.sha256(first) ==
                PolicySnapshotCompiler.sha256(second)
        )
    }

    @Test
    func binaryLayoutRoundTrips() throws {
        let snapshot = try PolicySnapshotCompiler.compile(source: source())
        let inspection = try PolicySnapshotCompiler.inspect(snapshot: snapshot)

        #expect(inspection.version == 1)
        #expect(inspection.entries.count == 3)
        #expect(inspection.entries[0].defaultPolicy)
        #expect(inspection.entries[0].policyID == "unknown-restricted")
        #expect(inspection.entries[1].imageSHA256 == String(repeating: "1", count: 64))
        #expect(inspection.entries[1].dllRoutes.map(\.module) == ["alloygraphics", "dxgi"])
        #expect(inspection.entries[2].graphicsProvider == "metal12")
    }

    @Test
    func unknownKeysFailClosed() throws {
        var text = try #require(String(bytes: source(), encoding: .utf8))
        text = text.replacingOccurrences(
            of: "\"schemaVersion\": 1",
            with: "\"schemaVersion\": 1, \"typo\": true"
        )

        #expect(throws: PolicySnapshotError.self) {
            try PolicySnapshotCompiler.compile(source: Data(text.utf8))
        }
    }

    @Test
    func duplicateDigestFailsClosed() throws {
        var text = try #require(String(bytes: source(), encoding: .utf8))
        text = text.replacingOccurrences(
            of: String(repeating: "2", count: 64),
            with: String(repeating: "1", count: 64)
        )

        #expect(throws: PolicySnapshotError.self) {
            try PolicySnapshotCompiler.compile(source: Data(text.utf8))
        }
    }

    @Test
    func pathInjectionFailsClosed() throws {
        var text = try #require(String(bytes: source(), encoding: .utf8))
        text = text.replacingOccurrences(
            of: "Z:\\\\providers\\\\dxmt",
            with: "Z:\\\\providers\\\\dxmt;C:\\\\untrusted"
        )

        #expect(throws: PolicySnapshotError.self) {
            try PolicySnapshotCompiler.compile(source: Data(text.utf8))
        }
    }

    private func source(
        processesReversed: Bool = false,
        routesReversed: Bool = false
    ) -> Data {
        let firstRoutes = routesReversed
            ? """
              {"module": "dxgi.dll", "loadOrder": "native"},
              {"module": "AlloyGraphics.dll", "loadOrder": "native"}
              """
            : """
              {"module": "AlloyGraphics.dll", "loadOrder": "native"},
              {"module": "dxgi.dll", "loadOrder": "native"}
              """
        let launcher = """
          {
            "imageSHA256": "\(String(repeating: "1", count: 64))",
            "policy": {
              "id": "launcher",
              "graphicsProvider": "dxmt",
              "providerDirectory": "Z:\\\\providers\\\\dxmt",
              "dllRoutes": [\(firstRoutes)]
            }
          }
        """
        let game = """
          {
            "imageSHA256": "\(String(repeating: "2", count: 64))",
            "policy": {
              "id": "game",
              "graphicsProvider": "metal12",
              "providerDirectory": "Z:\\\\providers\\\\metal12",
              "dllRoutes": [
                {"module": "alloygraphics", "loadOrder": "native"}
              ]
            }
          }
        """
        let processes = processesReversed ? "\(game),\(launcher)" : "\(launcher),\(game)"
        return Data(
            """
            {
              "schemaVersion": 1,
              "defaultPolicy": {
                "id": "unknown-restricted",
                "graphicsProvider": "restricted",
                "providerDirectory": "Z:\\\\providers\\\\restricted",
                "dllRoutes": [
                  {"module": "alloygraphics", "loadOrder": "native"}
                ]
              },
              "processPolicies": [\(processes)]
            }
            """.utf8
        )
    }
}
