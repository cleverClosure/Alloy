// Author: Timur Isaev

import CryptoKit
import Foundation
import Testing
@testable import AlloyProfileCompiler

func launchFixture(_ name: String = "minimal") throws -> LaunchCompilationInput {
    let profileData = try name == "example" ? fixtureData(.gameProfile, "valid/example-game-profile.json")
        : extraFixture("Launch/profile.json")
    let profile = try GameProfileValidator.validate(profileData)
    let manifestData = try extraFixture("Launch/\(name)-manifest.json")
    let manifest = try RuntimeManifestValidator.validate(manifestData)
    let metadata = CandidateMetadata(
        profileDigest: CanonicalJSON.digest(try CanonicalJSON.encode(profileData)), releaseRing: .stable,
        approvedCertification: profile.certification.level
    )
    let envelopes = try CandidateEnvelopes(
        profile: signedFixture(profileData), manifest: signedFixture(manifestData, type: .runtimeManifest),
        metadata: signedFixture(CanonicalJSON.encode(metadata), type: .releaseMetadata)
    )
    var selection = selectionInput()
    selection.gameId = profile.game.canonicalId
    selection.storefront = profile.game.storefronts[0].kind
    selection.appId = profile.game.storefronts[0].appId
    selection.branch = profile.game.storefronts[0].branch
    let build = profile.selectors.gameBuild
    selection.gameBuild = BuildIdentity(
        id: "gb_fixture_\(name)", version: build.version, manifestId: build.manifestId,
        files: (build.requiredFiles ?? []).map {
            ObservedFile(path: $0.path, sha256: $0.sha256, size: $0.size, peTimestamp: $0.peTimestamp)
        }
    )
    if let launcher = profile.selectors.launcherBuild {
        selection.launcherBuild = BuildIdentity(
            id: "lb_fixture", version: launcher.version, manifestId: launcher.manifestId
        )
    }
    let processes = profile.processPolicies.map { policy in
        ProcessIdentity(
            path: policy.id == "launcher" ? "Launcher.exe" : "Game/Binaries/Win64/Game.exe",
            sha256: policy.match.sha256 ?? String(repeating: "b", count: 64),
            parentPolicyId: policy.match.parentPolicyId
        )
    }
    let evidence = try launchEvidence(
        profile: profile, manifest: manifest, envelopes: envelopes, selection: selection, processes: processes
    )
    return try LaunchCompilationInput(
        candidates: [envelopes], selection: selection,
        evidenceEnvelope: signedFixture(CanonicalJSON.encode(evidence), type: .launchEvidence),
        verificationMode: testVerificationMode(), processes: processes,
        volumes: Dictionary(uniqueKeysWithValues: ["runtime", "game", "saves", "settings", "cache", "temp"].map {
            ($0, "fixture-volume-\($0)")
        }), availableRuntimeGenerations: ["rtg_previous_fixture_0"]
    )
}

private func launchEvidence(
    profile: GameProfileDocument, manifest: RuntimeManifestDocument, envelopes: CandidateEnvelopes,
    selection: SelectionInput, processes: [ProcessIdentity]
) throws -> LaunchEvidence {
    let workarounds = profile.processPolicies.map {
        WorkaroundRecord(
            id: "wa_\($0.id)", owner: "Timur Isaev", reason: "Synthetic validation fixture",
            gameBuild: selection.gameBuild.id, processPolicy: $0.id, introducedInProfileRevision: 1,
            testEvidence: [profile.certification.matrixDigest], expiresAt: "2030-01-01T00:00:00Z",
            removalCondition: "Remove with the synthetic fixture", userVisibleRisk: false,
            performanceRisk: "Fixture only"
        )
    }
    let providers = Dictionary(uniqueKeysWithValues: manifest.components.map {
        ($0.name, ProviderBinding(component: $0.name, directory: "R:\\providers\\\($0.name)"))
    })
    let masks = profile.processPolicies.compactMap { policy -> FeatureMask? in
        guard let identifier = policy.execution.featureMask else { return nil }
        return FeatureMask(
            id: identifier,
            provider: policy.execution.graphicsProvider?.rawValue ?? profile.runtime.defaultGraphicsProvider.rawValue,
            features: ["fixture.capability"], limits: ["fixture.slots": 2], workaroundIds: ["wa_\(policy.id)"]
        )
    }
    let ceilings = Array(Set(masks.map(\.provider))).sorted().map {
        FeatureCeiling(provider: $0, features: ["fixture.capability"], limits: ["fixture.slots": 4])
    }
    return try LaunchEvidence(
        profileDigest: CanonicalJSON.digest(envelopePayload(envelopes.profile)),
        manifestDigest: CanonicalJSON.digest(envelopePayload(envelopes.manifest)),
        metadataDigest: CanonicalJSON.digest(envelopePayload(envelopes.metadata)),
        gameBuildDigest: selection.gameBuild.digest(), launcherBuildDigest: selection.launcherBuild?.digest(),
        hostClassId: selection.host.localClassId(), matrixDigest: profile.certification.matrixDigest,
        lifecycle: "stable", certificationExpiresAt: profile.certification.expiresAt ?? "2030-01-01T00:00:00Z",
        fixtureCeilingsOnly: true, ceilings: ceilings, masks: masks, workarounds: workarounds, vendorApproval: nil,
        providers: providers,
        processDigests: Dictionary(uniqueKeysWithValues: zip(profile.processPolicies, processes).map {
            ($0.id, $1.sha256!)
        }), approvedDependencyDigests: (profile.dependencies ?? []).compactMap(\.digest)
    )
}

func envelopePayload(_ data: Data) throws -> Data {
    let envelope = try JSONDecoder().decode(TestEnvelope.self, from: data)
    return try #require(Data(base64Encoded: envelope.claims.payload))
}

func editEvidence(_ input: inout LaunchCompilationInput, _ edit: (inout LaunchEvidence) throws -> Void) throws {
    var evidence = try LaunchEvidence.decode(envelopePayload(input.evidenceEnvelope))
    try edit(&evidence)
    input.evidenceEnvelope = try signedFixture(CanonicalJSON.encode(evidence), type: .launchEvidence)
}

func editLaunchProfile(_ input: inout LaunchCompilationInput, _ patches: [String: Any]) throws {
    var object = try #require(JSONSerialization.jsonObject(with: envelopePayload(input.candidates[0].profile))
        as? [String: Any])
    for path in patches.keys.sorted() {
        object = try replacing(object, path: path.components(separatedBy: "."), value: patches[path])
    }
    let bytes = try JSONSerialization.data(withJSONObject: object)
    input.candidates[0].profile = try signedFixture(bytes)
    var metadata = try JSONDecoder().decode(CandidateMetadata.self, from: envelopePayload(input.candidates[0].metadata))
    metadata.profileDigest = try CanonicalJSON.digest(CanonicalJSON.encode(bytes))
    metadata.approvedCertification = try GameProfileValidator.validate(bytes).certification.level
    input.candidates[0].metadata = try signedFixture(CanonicalJSON.encode(metadata), type: .releaseMetadata)
    let metadataDigest = try CanonicalJSON.digest(envelopePayload(input.candidates[0].metadata))
    try editEvidence(&input) {
        $0.profileDigest = metadata.profileDigest
        $0.metadataDigest = metadataDigest
    }
}

func addVendorApproval(_ input: inout LaunchCompilationInput) throws {
    let key = try JSONDecoder().decode(TestKey.self, from: extraFixture("TEST-ONLY-vendor-key.json"))
    input.vendorKeys = [key.keyId: key.publicKey]
    try editEvidence(&input) { evidence in
        var approval = VendorApproval(
            vendorId: "fixture-vendor", gameBuildDigest: evidence.gameBuildDigest, hostClassId: evidence.hostClassId,
            profileDigest: evidence.profileDigest, matrixDigest: evidence.matrixDigest,
            expiresAt: "2030-01-01T00:00:00Z", scope: "competitive-certified", keyId: key.keyId, signature: ""
        )
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: key.privateKey)
        approval.signature = try signer.signature(for: CanonicalJSON.encode(approval.claims)).base64EncodedString()
        evidence.vendorApproval = approval
    }
}
