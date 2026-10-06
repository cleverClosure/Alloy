// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

@Suite("Complete local LaunchSpecification")
struct LaunchCompilerTests {
    @Test(arguments: ["minimal", "example"])
    func stableBytesAndExportReresolution(_ name: String) throws {
        let input = try launchFixture(name)
        let golden = try LaunchCompiler.compile(input)
        let expectedDigests = try JSONDecoder().decode(
            [String: String].self, from: extraFixture("Launch/golden-digests.json")
        )
        #expect(CanonicalJSON.digest(golden.canonicalJSON) == expectedDigests[name],
                "golden \(name): \(CanonicalJSON.digest(golden.canonicalJSON))")
        try auditAgainstInputs(golden, input: input)
        #expect(golden.specification.hostClassId.hasPrefix("local-unregistered:"))
        #expect(!golden.specification.productionEligible)
        #expect(!golden.specification.runtimeReady)
        #expect(golden.specification.policyCompiler.snapshotDigest == golden.snapshot.digest)
        #expect(golden.specification.notYetLowered.contains { $0.field == "filesystem.authorization" })
        if name == "example" {
            #expect(golden.specification.notYetLowered.contains { $0.field == "healthChecks" })
        }
        for index in 0..<10 {
            var reordered = input
            if index.isMultiple(of: 2) { reordered.processes.reverse() }
            let compiled = try LaunchCompiler.compile(reordered)
            #expect(compiled.canonicalJSON == golden.canonicalJSON)
            #expect(compiled.snapshot.bytes == golden.snapshot.bytes)
            let decoded = try LaunchCompiler.verifyExport(compiled.canonicalJSON, input: input)
            #expect(decoded == golden.specification)
            #expect(decoded.componentDigests == golden.specification.componentDigests)
        }
        var object = try #require(JSONSerialization.jsonObject(with: golden.canonicalJSON) as? [String: Any])
        object["gameBuildId"] = "different"
        let changed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CompilerFailure.rejected("export does not reproduce the same launch specification")) {
            try LaunchCompiler.verifyExport(changed, input: input)
        }
    }

    @Test func requiredSemanticNegativePairs() throws {
        let clean = try launchFixture()
        let mutations: [(inout LaunchEvidence) -> Void] = [
            { $0.workarounds[0].owner = "" }, { $0.certificationExpiresAt = "2020-01-01T00:00:00Z" },
            { $0.masks[0].limits["fixture.slots"] = 5 }, { $0.workarounds[0].testEvidence = [] },
            { $0.workarounds[0].gameBuild = "different" }, { $0.workarounds[0].expiresAt = "2020-01-01T00:00:00Z" },
            { $0.hostClassId = "local-unregistered:wrong" }, { $0.gameBuildDigest = "sha256:wrong" },
            { $0.lifecycle = "revoked" }, { $0.lifecycle = "superseded" }, { $0.lifecycle = "expired" },
            { $0.lifecycle = "rejected" }, { $0.lifecycle = "quarantined" }, { $0.fixtureCeilingsOnly = false },
            { $0.providers.removeValue(forKey: "metal12") },
            { $0.processDigests["game"] = String(repeating: "b", count: 64) }
        ]
        for mutation in mutations {
            _ = try LaunchCompiler.compile(clean)
            var broken = clean
            try editEvidence(&broken, mutation)
            #expect(throws: (any Error).self) { try LaunchCompiler.compile(broken) }
        }
        var competitive = clean
        try editLaunchProfile(&competitive, ["certification.level": "competitive-certified"])
        #expect(throws: CompilerFailure.rejected("competitive certification requires scoped vendor approval")) {
            try LaunchCompiler.compile(competitive)
        }
        try addVendorApproval(&competitive)
        _ = try LaunchCompiler.compile(competitive)
        var wrongScope = competitive
        try editEvidence(&wrongScope) { $0.vendorApproval?.gameBuildDigest = "wrong" }
        #expect(throws: (any Error).self) { try LaunchCompiler.compile(wrongScope) }
        wrongScope = competitive
        wrongScope.vendorKeys = [:]
        #expect(throws: (any Error).self) { try LaunchCompiler.compile(wrongScope) }
        wrongScope = competitive
        try editEvidence(&wrongScope) {
            $0.vendorApproval?.signature = Data(repeating: 0, count: 64).base64EncodedString()
        }
        #expect(throws: CompilerFailure.rejected("invalid vendor scope signature")) {
            try LaunchCompiler.compile(wrongScope)
        }
    }

    @Test func masksAreImmutableAndEpochsIncludePolicyChanges() throws {
        let input = try launchFixture()
        let evidence = try LaunchEvidence.decode(envelopePayload(input.evidenceEnvelope))
        var registry = try FeatureMaskRegistry(ceilings: evidence.ceilings, fixtureOnly: true)
        var mask = try #require(evidence.masks.first)
        try registry.register(mask)
        try registry.register(mask)
        mask.limits["fixture.slots"] = 3
        #expect(throws: CompilerFailure.rejected("feature mask identity is immutable")) { try registry.register(mask) }
        let original = try LaunchCompiler.compile(input)
        var updated = input
        try editLaunchProfile(&updated, ["revision": 2])
        let changed = try LaunchCompiler.compile(updated)
        #expect(original.specification.cacheEpochs != changed.specification.cacheEpochs)
        #expect(original.specification.launchSpecId != changed.specification.launchSpecId)
    }
}
