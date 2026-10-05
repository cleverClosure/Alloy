// Author: Timur Isaev

import CryptoKit
import Foundation
import Testing
@testable import AlloyPolicySnapshot

struct V2Tests {
    private func source(_ policy: [String: Any] = ["id": "default"]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "defaultPolicy": policy, "processPolicies": []
        ])
    }

    @Test func presenceAndCanonicalEncoding() throws {
        let policy: [String: Any] = [
            "id": "default", "graphicsProvider": "dxmt", "providerDirectory": "C:\\providers\\dxmt",
            "cpuProvider": "fex-arm64ec", "environment": ["lang": "C", "TZ": "UTC"],
            "workingDirectory": "C:\\game", "dllRoutes": [
                ["module": "Zeta.DLL", "loadOrder": "disabled"], ["module": "alpha", "loadOrder": "native"]
            ]
        ]
        let bytes = try PolicySnapshotV2.compile(source: source(policy))
        #expect(bytes.count == 7568)
        let output = try PolicySnapshotV2.inspect(snapshot: bytes, expectedDigest: PolicySnapshotCompiler.sha256(bytes))
        #expect(output.version == 2)
        #expect(output.entries[0].cpuProvider == .fexArm64ec)
        #expect(output.entries[0].environment == ["LANG": "C", "TZ": "UTC"])
        #expect(output.entries[0].dllRoutes?.map(\.module) == ["alpha", "zeta"])
        var normalized = policy
        normalized["environment"] = ["TZ": "UTC", "LANG": "C"]
        normalized["dllRoutes"] = [["module": "alpha", "loadOrder": "native"],
                                   ["module": "zeta", "loadOrder": "disabled"]]
        #expect(try PolicySnapshotV2.compile(source: source(normalized)) == bytes)
        let absent = try PolicySnapshotV2.inspect(snapshot: PolicySnapshotV2.compile(source: source()))
        #expect(absent.entries[0].environment == nil)
        let empty = try PolicySnapshotV2.inspect(snapshot: PolicySnapshotV2.compile(source: source([
            "id": "default", "environment": [:], "dllRoutes": []
        ])))
        #expect(empty.entries[0].environment == [:])
        #expect(empty.entries[0].dllRoutes == [])
        #expect(empty != absent)
    }

    @Test func sourceRejectsAmbiguityAndInjection() throws {
        for extras: [String: Any] in [
            ["cpuProvider": "rosetta-x64-bootstrap"], ["environment": ["PATH": "evil"]],
            ["environment": ["ALLOY_POLICY_SNAPSHOT_FD": "7"]], ["environment": ["a": "1", "A": "2"]],
            ["environment": ["KEY": "nul\0suffix"]], ["workingDirectory": "C:\\safe\\..\\escape"],
            ["workingDirectory": "C:\\safe.\\escape"], ["workingDirectory": "C:\\safe;C:\\evil"],
            ["graphicsProvider": "dxmt"], ["unknown": 1], ["cpuProvider": NSNull()],
            ["dllRoutes": [["module": "ntdll", "loadOrder": "disabled"]]],
            ["environment": ["KEY": String(repeating: "x", count: 256)]]
        ] {
            var policy: [String: Any] = ["id": "default"]
            policy.merge(extras) { _, new in new }
            #expect(throws: (any Error).self) { try PolicySnapshotV2.compile(source: source(policy)) }
        }
    }

    @Test func everyByteMutationFailsIntegrity() throws {
        let bytes = try PolicySnapshotV2.compile(source: source())
        for index in bytes.indices {
            var changed = bytes
            changed[index] ^= 1
            #expect(throws: (any Error).self) { try PolicySnapshotV2.inspect(snapshot: changed) }
        }
        #expect(throws: PolicySnapshotV2Error.expectedDigest) {
            try PolicySnapshotV2.inspect(snapshot: bytes, expectedDigest: String(repeating: "0", count: 64))
        }
        #expect(throws: PolicySnapshotV2Error.legacyVersion) {
            try PolicySnapshotV2.inspect(snapshot: Data("ALLOYP01".utf8))
        }
    }

    @Test func checksumCannotConcealNoncanonicalFields() throws {
        let bytes = try PolicySnapshotV2.compile(source: source())
        // Counts, flags, absent values, padding, default digest and unused slots.
        for offset in [12, 16, 20, 24, 28, 96, 96 + 40, 96 + 96, 96 + 672,
                       96 + 676, 96 + 680, 96 + 684, 96 + 688, 96 + 1200, 96 + 2352] {
            var changed = bytes
            changed[offset] ^= 128
            changed.replaceSubrange(32..<64, with: Data(SHA256.hash(data: changed.dropFirst(96))))
            changed.replaceSubrange(64..<96, with: Data(repeating: 0, count: 32))
            let checksum = Data(SHA256.hash(data: changed))
            changed.replaceSubrange(64..<96, with: checksum)
            #expect(throws: (any Error).self) { try PolicySnapshotV2.inspect(snapshot: changed) }
        }
    }
}
