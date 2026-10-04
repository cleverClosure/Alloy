// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

@Suite("Launch security boundaries")
struct LaunchSecurityTests {
    @Test func explicitDevelopmentModeHasACompletePositivePath() throws {
        var input = try launchFixture()
        try editLaunchProfile(&input, ["certification.level": "experimental"])
        var manifest = try #require(JSONSerialization.jsonObject(with: envelopePayload(input.candidates[0].manifest))
            as? [String: Any])
        manifest = try replacing(manifest, path: ["activation", "releaseRing"], value: "development")
        input.candidates[0].manifest = try signedFixture(
            JSONSerialization.data(withJSONObject: manifest), type: .runtimeManifest
        )
        var metadata = try JSONDecoder().decode(
            CandidateMetadata.self, from: envelopePayload(input.candidates[0].metadata)
        )
        metadata.releaseRing = .development
        input.candidates[0].metadata = try signedFixture(CanonicalJSON.encode(metadata), type: .releaseMetadata)
        let manifestDigest = try CanonicalJSON.digest(envelopePayload(input.candidates[0].manifest))
        let metadataDigest = try CanonicalJSON.digest(envelopePayload(input.candidates[0].metadata))
        try editEvidence(&input) {
            $0.lifecycle = "draft"
            $0.manifestDigest = manifestDigest
            $0.metadataDigest = metadataDigest
        }
        func unsigned(_ data: Data) throws -> Data {
            let envelope = try JSONDecoder().decode(TestEnvelope.self, from: data)
            return try CanonicalJSON.encode(TestEnvelope(claims: envelope.claims))
        }
        input.candidates[0] = try CandidateEnvelopes(
            profile: unsigned(input.candidates[0].profile), manifest: unsigned(input.candidates[0].manifest),
            metadata: unsigned(input.candidates[0].metadata)
        )
        input.evidenceEnvelope = try unsigned(input.evidenceEnvelope)
        input.verificationMode = .development
        let result = try LaunchCompiler.compile(input)
        #expect(result.specification.verification == "unsigned-development")
        #expect(result.specification.certification.level == .experimental)
        #expect(!result.specification.productionEligible)
    }

    @Test func grantsRequireGamePurposeAndAccess() throws {
        var clean = try launchFixture()
        try editLaunchProfile(&clean, ["filesystem.driveMappings": [
            ["letter": "U", "target": "user-grant", "access": "read-write", "grantId": "grant_fixture"]
        ]])
        clean.grants = [LocalGrant(
            id: "grant_fixture", gameId: clean.selection.gameId, purpose: "saves", access: .readWrite
        )]
        #expect(try LaunchCompiler.compile(clean).specification.grants == ["grant_fixture"])
        let changes: [(inout LaunchCompilationInput) -> Void] = [
            { $0.grants = [] }, { $0.grants[0].gameId = "different" }, { $0.grants[0].purpose = "host-root" },
            { $0.grants[0].access = .readOnly }, { $0.grants[0].id = "/private/home" },
            { $0.volumes["saves"] = "/private/home" }, { $0.availableRuntimeGenerations = [] }
        ]
        for change in changes {
            _ = try LaunchCompiler.compile(clean)
            var broken = clean
            change(&broken)
            #expect(throws: (any Error).self) { try LaunchCompiler.compile(broken) }
        }
    }

    @Test func rootAccessArtifactBypassAndPublicSecretsReject() throws {
        let clean = try launchFixture()
        let patches: [[String: Any]] = [
            ["filesystem.denyHostRoot": false],
            ["filesystem.driveMappings": [["letter": "Z", "target": "game", "access": "read-only"]]],
            ["filesystem.driveMappings": [["letter": "R", "target": "runtime", "access": "read-write"]]],
            ["registry": ["sets": [["key": "HKLM\\Software\\Alloy", "name": "DisableVerification",
                                   "type": "REG_DWORD", "value": 1]]]],
            ["registry": ["sets": [["key": "HKCU\\Software\\Game", "name": "AccessToken",
                                   "type": "REG_SZ", "value": "private-value"]]]]
        ]
        for patch in patches {
            var broken = clean
            try editLaunchProfile(&broken, patch)
            #expect(throws: (any Error).self) { try LaunchCompiler.compile(broken) }
            _ = try LaunchCompiler.compile(clean)
        }
        var object = try #require(JSONSerialization.jsonObject(with: envelopePayload(clean.candidates[0].profile))
            as? [String: Any])
        var policies = try #require(object["processPolicies"] as? [[String: Any]])
        for environment in [["ALLOY_VERIFY": "0"], ["DYLD_INSERT_LIBRARIES": "/tmp/inject"], ["TOKEN": "secret"]] {
            var execution = try #require(policies[0]["execution"] as? [String: Any])
            execution["environment"] = environment
            policies[0]["execution"] = execution
            object["processPolicies"] = policies
            var broken = clean
            try editLaunchProfile(&broken, ["processPolicies": policies])
            #expect(throws: (any Error).self) { try LaunchCompiler.compile(broken) }
        }
    }

    @Test func unsignedStableClaimsAndUnknownEvidenceKeysReject() throws {
        let clean = try launchFixture()
        var unsigned = clean
        unsigned.verificationMode = .development
        func untrusted(_ envelope: Data) throws -> Data {
            let original = try JSONDecoder().decode(TestEnvelope.self, from: envelope)
            return try CanonicalJSON.encode(TestEnvelope(claims: original.claims))
        }
        unsigned.candidates[0] = try CandidateEnvelopes(
            profile: untrusted(clean.candidates[0].profile), manifest: untrusted(clean.candidates[0].manifest),
            metadata: untrusted(clean.candidates[0].metadata)
        )
        unsigned.evidenceEnvelope = try untrusted(clean.evidenceEnvelope)
        #expect(throws: CompilerFailure.rejected("unsigned changes cannot claim stable or certified status")) {
            try LaunchCompiler.compile(unsigned)
        }
        var object = try #require(JSONSerialization.jsonObject(with: envelopePayload(clean.evidenceEnvelope))
            as? [String: Any])
        object["disableArtifactVerification"] = true
        var unknown = clean
        unknown.evidenceEnvelope = try signedFixture(
            JSONSerialization.data(withJSONObject: object), type: .launchEvidence
        )
        #expect(throws: (any Error).self) { try LaunchCompiler.compile(unknown) }
        object.removeValue(forKey: "disableArtifactVerification")
        var records = try #require(object["workarounds"] as? [[String: Any]])
        records[0].removeValue(forKey: "owner")
        object["workarounds"] = records
        unknown.evidenceEnvelope = try signedFixture(
            JSONSerialization.data(withJSONObject: object), type: .launchEvidence
        )
        #expect(throws: (any Error).self) { try LaunchCompiler.compile(unknown) }
        _ = try LaunchCompiler.compile(clean)
    }
}
