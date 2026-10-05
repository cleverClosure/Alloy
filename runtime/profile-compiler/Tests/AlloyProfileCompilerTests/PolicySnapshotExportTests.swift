// Author: Timur Isaev

import AlloyPolicySnapshot
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
    @Test func preservesLegacyOracleAndExportsV2() throws {
        let (fallback, processes) = try oraclePolicies()
        let encoded = try #require(String(data: extraFixture("WineOracle/recorded-snapshot.base64"), encoding: .utf8))
        let recorded = try #require(Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(CanonicalJSON.digest(recorded) ==
            "sha256:39adf17b81e5b35dd7120d66ebe17bae58007ed506fbb51e866e9e209ac700f5")
        #expect(try PolicySnapshotCompiler.compile(source: extraFixture("WineOracle/source.json")) == recorded)
        let exported = try PolicySnapshotExporter.export(defaultPolicy: fallback, processes: processes)
        #expect(exported.inspection.version == 2)
        #expect(exported.bytes.count == 96 + 7472 * 3)
        #expect(exported.inspection.entries[0].policyID == "unknown-restricted")
        #expect(exported.inspection.entries.allSatisfy { $0.cpuProvider == .nativeArm64ec })
        #expect(!exported.runtimeReady)
        for index in 0..<10 {
            let ordered = index.isMultiple(of: 2) ? processes : processes.reversed()
            let repeated = try PolicySnapshotExporter.export(defaultPolicy: fallback, processes: ordered)
            #expect(repeated.bytes == exported.bytes)
        }
        #expect(throws: PolicySnapshotV2Error.legacyVersion) { try PolicySnapshotV2.inspect(snapshot: recorded) }
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
        #expect(fields == ["featureMask", "networkPolicy", "services", "debugPolicy"])
        let entry = try #require(result.inspection.entries.last)
        #expect(entry.environment == ["LANG": "en_US"])
        #expect(entry.workingDirectory == "C:\\game")
        #expect(entry.cpuProvider == .nativeArm64ec)
        #expect(!result.runtimeReady)
        let clean = try PolicySnapshotExporter.export(defaultPolicy: fallback, processes: [selected])
        #expect(!clean.notYetLowered.contains { $0.field == "featureMask" || $0.field == "environment" })
    }

    @Test func emptyRoutesAndUnrepresentableIdentity() throws {
        let (fallback, processes) = try oraclePolicies()
        var empty = fallback.resolved
        empty.dllOverrides = [:]
        let emptyPolicy = SnapshotPolicy(
            id: fallback.id, providerDirectory: fallback.providerDirectory, resolved: empty
        )
        let result = try PolicySnapshotExporter.export(defaultPolicy: emptyPolicy, processes: [])
        #expect(!result.notYetLowered.contains { $0.field == "dllOverrides.empty" })
        #expect(result.inspection.entries[0].dllRoutes == [])
        #expect(throws: (any Error).self) {
            try PolicySnapshotExporter.export(defaultPolicy: fallback, processes: processes + processes)
        }
        let traversal = SnapshotPolicy(id: fallback.id, providerDirectory: "C:\\safe\\..\\unsafe", resolved: empty)
        #expect(throws: (any Error).self) {
            try PolicySnapshotExporter.export(defaultPolicy: traversal, processes: [])
        }
        empty.dllOverrides = Dictionary(uniqueKeysWithValues: (0..<33).map { ("module\($0)", "disabled") })
        let tooMany = SnapshotPolicy(id: fallback.id, providerDirectory: fallback.providerDirectory, resolved: empty)
        #expect(throws: (any Error).self) {
            try PolicySnapshotExporter.export(defaultPolicy: tooMany, processes: [])
        }
    }

    @Test func onlyLoweredFieldsAreReadyAndUnsupportedValuesStayVisible() throws {
        let profile = try GameProfileValidator.validate(compilerProfile(["processPolicies": [[
            "id": "ready", "priority": 100, "match": ["sha256": String(repeating: "a", count: 64)],
            "execution": ["cpuProvider": "fex-arm64ec", "graphicsProvider": "dxmt",
                          "syncProvider": "conservative", "networkPolicy": "allow", "debugPolicy": "off",
                          "environment": ["LANG": "en_US"], "workingDirectory": "C:\\game"]
        ]]]))
        let resolved = try ProcessResolver.resolve(profile.processPolicies, runtime: profile.runtime,
            process: ProcessIdentity(path: "C:\\game.exe", sha256: String(repeating: "a", count: 64)))
        func export(_ value: ResolvedProcessPolicy) throws -> PolicySnapshotExport {
            try PolicySnapshotExporter.export(defaultPolicy: SnapshotPolicy(
                id: "ready", providerDirectory: "R:\\dxmt", resolved: value), processes: [])
        }
        let ready = try export(resolved)
        #expect(ready.runtimeReady)
        #expect(ready.notYetLowered.isEmpty)
        #expect(ready.inspection.entries[0].cpuProvider == .fexArm64ec)
        let mutations: [(String, (inout ResolvedProcessPolicy) -> Void)] = [
            ("cpuProvider", { $0.cpuProvider = "rosetta-x64-bootstrap" }),
            ("syncProvider", { $0.syncProvider = "wait-address" }),
            ("networkPolicy", { $0.networkPolicy = "deny" }),
            ("networkPolicy", { $0.networkPolicy = "publisher-only" }),
            ("debugPolicy", { $0.debugPolicy = "crash-only" }),
            ("debugPolicy", { $0.debugPolicy = "capture" }),
            ("featureMask", { $0.featureMask = "required-mask" }),
            ("services", { $0.services = ["audio": "required-audio"] })
        ]
        for (field, mutate) in mutations {
            var value = resolved
            mutate(&value)
            let result = try export(value)
            #expect(!result.runtimeReady)
            #expect(result.notYetLowered.map(\.field) == [field])
        }
    }

}
