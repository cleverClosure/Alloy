// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

struct OracleSource: Decodable {
    struct Route: Decodable {
        let module: String
        let loadOrder: String
    }
    struct Policy: Decodable {
        let id: String
        let graphicsProvider: String
        let providerDirectory: String
        let dllRoutes: [Route]
    }
    struct Process: Decodable {
        let imageSHA256: String
        let policy: Policy
    }
    let defaultPolicy: Policy
    let processPolicies: [Process]
}

func oraclePolicies() throws -> (SnapshotPolicy, [SnapshotProcess]) {
    let source = try JSONDecoder().decode(OracleSource.self, from: extraFixture("WineOracle/source.json"))
    let policies: [[String: Any]] = source.processPolicies.map { process in
        ["id": process.policy.id, "priority": 100, "match": ["sha256": process.imageSHA256],
         "execution": ["graphicsProvider": process.policy.graphicsProvider, "dllOverrides":
            Dictionary(uniqueKeysWithValues: process.policy.dllRoutes.map { ($0.module, $0.loadOrder) })]]
    }
    let profile = try GameProfileValidator.validate(compilerProfile(["processPolicies": policies]))
    let processes = try source.processPolicies.map { process in
        let resolved = try ProcessResolver.resolve(
            profile.processPolicies, runtime: profile.runtime,
            process: ProcessIdentity(path: process.policy.id + ".exe", sha256: process.imageSHA256)
        )
        return SnapshotProcess(imageSHA256: process.imageSHA256, policy: SnapshotPolicy(
            id: process.policy.id, providerDirectory: process.policy.providerDirectory, resolved: resolved
        ))
    }
    // The preserved WINE-001 default is a synthetic restricted marker provider,
    // outside the real graphics-provider enum. Reproduce that explicit oracle input.
    var fallback = ResolvedProcessPolicy.conservativeDefault(profile.runtime)
    fallback.graphicsProvider = source.defaultPolicy.graphicsProvider
    fallback.dllOverrides = ["alloygraphics": "native"]
    return (SnapshotPolicy(
        id: source.defaultPolicy.id, providerDirectory: source.defaultPolicy.providerDirectory, resolved: fallback
    ), processes)
}

@Suite("WINE-001 snapshot export")
struct PolicySnapshotExportTests {
    @Test func matchesRecordedExternalOracleExactly() throws {
        let (fallback, processes) = try oraclePolicies()
        let encoded = try #require(String(data: extraFixture("WineOracle/recorded-snapshot.base64"), encoding: .utf8))
        let recorded = try #require(Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)))
        let expected = "sha256:39adf17b81e5b35dd7120d66ebe17bae58007ed506fbb51e866e9e209ac700f5"
        #expect(CanonicalJSON.digest(recorded) == expected)
        for index in 0..<10 {
            let ordered = index.isMultiple(of: 2) ? processes : processes.reversed()
            let exported = try PolicySnapshotExporter.export(defaultPolicy: fallback, processes: ordered)
            #expect(exported.bytes == recorded)
            #expect(exported.digest == expected)
            #expect(exported.bytes.count == 2968)
            #expect(exported.inspection.version == 1)
            #expect(exported.inspection.sourceDigest ==
                "0ed8c8a6225e2c269ebe16d902bc1b590448cfe05efb8946994dcd69a9536348")
            #expect(!exported.runtimeReady)
        }
    }

    @Test func unsupportedFieldsAreExplicitAndNeverDisappear() throws {
        let (fallback, processes) = try oraclePolicies()
        let selected = try #require(processes.first)
        var resolved = selected.policy.resolved
        resolved.featureMask = "synthetic-mask"
        resolved.environment = ["LANG": "en_US"]
        resolved.workingDirectory = "C:\\game"
        resolved.services = ["audio": "synthetic-audio"]
        let policy = SnapshotPolicy(
            id: selected.policy.id, providerDirectory: selected.policy.providerDirectory, resolved: resolved
        )
        let result = try PolicySnapshotExporter.export(defaultPolicy: fallback, processes: [
            SnapshotProcess(imageSHA256: selected.imageSHA256, policy: policy)
        ])
        let fields = Set(result.notYetLowered.filter { $0.policyId == policy.id }.map(\.field))
        #expect(fields == ["cpuProvider", "syncProvider", "featureMask", "environment", "networkPolicy",
                           "workingDirectory", "services", "debugPolicy"])
        #expect(!result.runtimeReady)
        let clean = try PolicySnapshotExporter.export(defaultPolicy: fallback, processes: [selected])
        #expect(!clean.notYetLowered.contains { $0.field == "featureMask" || $0.field == "environment" })
    }

    @Test func emptyRouteProjectionAndUnrepresentableIdentity() throws {
        let (fallback, processes) = try oraclePolicies()
        var empty = fallback.resolved
        empty.dllOverrides = [:]
        let emptyPolicy = SnapshotPolicy(
            id: fallback.id, providerDirectory: fallback.providerDirectory, resolved: empty
        )
        let result = try PolicySnapshotExporter.export(defaultPolicy: emptyPolicy, processes: [])
        #expect(result.notYetLowered.contains { $0.field == "dllOverrides.empty" })
        #expect(result.inspection.entries[0].dllRoutes[0].module == "__alloy_empty_route__")
        #expect(result.inspection.entries[0].dllRoutes[0].loadOrder == "disabled")
        #expect(throws: (any Error).self) {
            try PolicySnapshotExporter.export(defaultPolicy: fallback, processes: processes + processes)
        }
        let traversal = SnapshotPolicy(id: fallback.id, providerDirectory: "C:\\safe\\..\\unsafe", resolved: empty)
        #expect(throws: (any Error).self) {
            try PolicySnapshotExporter.export(defaultPolicy: traversal, processes: [])
        }
        empty.dllOverrides = Dictionary(uniqueKeysWithValues: (0..<9).map { ("module\($0)", "disabled") })
        let tooMany = SnapshotPolicy(id: fallback.id, providerDirectory: fallback.providerDirectory, resolved: empty)
        #expect(throws: (any Error).self) {
            try PolicySnapshotExporter.export(defaultPolicy: tooMany, processes: [])
        }
    }
}
