// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

enum PipelineMutation: String, CaseIterable {
    case signature, unsigned, envelopeExpiry, profileSchema, manifestSchema, runtimeGeneration
    case host, build, conflict, workaroundOwner, certificationExpiry, maskCeiling, competitiveScope, secretEnvironment
}

struct PipelineRandom {
    var state: UInt64 = 0x101_600D_CAFE
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

func modifyEnvelope(
    _ envelope: Data, type: PayloadType, _ edit: (inout [String: Any]) throws -> Void
) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: envelopePayload(envelope)) as? [String: Any])
    try edit(&object)
    return try signedFixture(JSONSerialization.data(withJSONObject: object), type: type)
}

/// Co-mutates the whole valid tuple and rebinds its signed evidence. Mutations
/// preserve the chosen fixture's build selectors, scopes, and provider graph.
func validPipelineVariant(index: Int, random: inout PipelineRandom) throws -> LaunchCompilationInput {
    var input = try launchFixture(index.isMultiple(of: 2) ? "minimal" : "example")
    try editLaunchProfile(&input, ["revision": 100 + index])
    let version = "1.\(random.next() % 100).\(index)"
    input.candidates[0].manifest = try modifyEnvelope(input.candidates[0].manifest, type: .runtimeManifest) { root in
        var components = try #require(root["components"] as? [[String: Any]])
        let position = try #require(components.firstIndex { $0["name"] as? String == "native-arm64ec" })
        components[position]["version"] = version
        components[position]["digest"] = CanonicalJSON.digest(Data("fuzz-component-\(index)-\(version)".utf8))
        root["components"] = components
    }
    input.selection.host.macOS = "15.\(random.next() % 20).\(random.next() % 10)"
    input.selection.host.memoryGiB = [16, 24, 32, 64][Int(random.next() % 4)]
    input.selection.gameBuild.id = "gb_fuzz_\(index)"
    if random.next().isMultiple(of: 2) { input.processes.reverse() }
    let manifestDigest = try CanonicalJSON.digest(envelopePayload(input.candidates[0].manifest))
    let buildDigest = try input.selection.gameBuild.digest()
    let hostClassId = try input.selection.host.localClassId()
    let buildId = input.selection.gameBuild.id
    try editEvidence(&input) {
        $0.manifestDigest = manifestDigest
        $0.gameBuildDigest = buildDigest
        $0.hostClassId = hostClassId
        for index in $0.workarounds.indices { $0.workarounds[index].gameBuild = buildId }
    }
    return input
}

func invalidPipelineVariant(
    _ clean: LaunchCompilationInput, mutation: PipelineMutation
) throws -> LaunchCompilationInput {
    var input = clean
    switch mutation {
    case .signature, .unsigned, .envelopeExpiry, .profileSchema, .manifestSchema, .runtimeGeneration:
        try invalidateEnvelope(&input, mutation: mutation)
    case .host: input.selection.host.architecture = "x64"
    case .build:
        input.selection.gameBuild.version = "unapproved-build"
        input.selection.gameBuild.manifestId = "unapproved-manifest"
        input.selection.gameBuild.files = []
    case .conflict:
        let original = input.candidates[0]
        var other = input
        let profile = try GameProfileValidator.validate(envelopePayload(original.profile))
        let changedProvider = profile.runtime.defaultGraphicsProvider == .dxmt ? "moltenvk" : "dxmt"
        try editLaunchProfile(&other, ["runtime.defaultGraphicsProvider": changedProvider])
        input.candidates = [original, other.candidates[0]]
    case .workaroundOwner: try editEvidence(&input) { $0.workarounds[0].owner = "" }
    case .certificationExpiry: try editEvidence(&input) { $0.certificationExpiresAt = "2020-01-01T00:00:00Z" }
    case .maskCeiling: try editEvidence(&input) { $0.masks[0].limits["fixture.slots"] = 5 }
    case .competitiveScope: try editLaunchProfile(&input, ["certification.level": "competitive-certified"])
    case .secretEnvironment:
        let root = try #require(JSONSerialization.jsonObject(with: envelopePayload(input.candidates[0].profile))
            as? [String: Any])
        var policies = try #require(root["processPolicies"] as? [[String: Any]])
        var execution = try #require(policies[0]["execution"] as? [String: Any])
        execution["environment"] = ["ALLOY_DISABLE_VERIFICATION": "1"]
        policies[0]["execution"] = execution
        try editLaunchProfile(&input, ["processPolicies": policies])
    }
    return input
}

private func invalidateEnvelope(_ input: inout LaunchCompilationInput, mutation: PipelineMutation) throws {
    switch mutation {
    case .signature:
        var object = try #require(JSONSerialization.jsonObject(with: input.candidates[0].profile) as? [String: Any])
        object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        input.candidates[0].profile = try JSONSerialization.data(withJSONObject: object)
    case .unsigned:
        let original = try JSONDecoder().decode(TestEnvelope.self, from: input.candidates[0].profile)
        input.candidates[0].profile = try CanonicalJSON.encode(TestEnvelope(claims: original.claims))
    case .envelopeExpiry:
        input.candidates[0].manifest = try signedFixture(
            envelopePayload(input.candidates[0].manifest), type: .runtimeManifest, expiry: "2020-01-01T00:00:00Z"
        )
    case .profileSchema:
        input.candidates[0].profile = try modifyEnvelope(input.candidates[0].profile, type: .gameProfile) {
            $0["unrecognizedRequiredCapability"] = true
        }
    case .manifestSchema:
        input.candidates[0].manifest = try modifyEnvelope(input.candidates[0].manifest, type: .runtimeManifest) {
            $0.removeValue(forKey: "components")
        }
    case .runtimeGeneration:
        input.candidates[0].manifest = try modifyEnvelope(input.candidates[0].manifest, type: .runtimeManifest) {
            $0["generationId"] = "rtg_wrong_fixture_000"
        }
    default: throw FuzzAuditFailure.invalidOutput
    }
}

enum FuzzAuditFailure: Error, Equatable { case falseAccept, invalidOutput }

func auditPipelineOutcome(shouldReject: Bool, output: CompiledLaunch?) throws {
    if shouldReject, output != nil { throw FuzzAuditFailure.falseAccept }
    if !shouldReject {
        guard let output, !output.specification.productionEligible, !output.specification.runtimeReady,
              output.specification.hostClassId.hasPrefix("local-unregistered:"),
              output.specification.policyCompiler.snapshotDigest == CanonicalJSON.digest(output.snapshot.bytes),
              output.specification.notYetLowered.contains(where: { $0.field == "networkPolicy" }) else {
            throw FuzzAuditFailure.invalidOutput
        }
    }
}

func auditAgainstInputs(_ output: CompiledLaunch, input: LaunchCompilationInput) throws {
    let source = input.candidates[0]
    let profileBytes = try envelopePayload(source.profile)
    let profile = try GameProfileValidator.validate(profileBytes)
    let manifest = try RuntimeManifestValidator.validate(envelopePayload(source.manifest))
    let expectedComponents = Dictionary(uniqueKeysWithValues: manifest.components.map { ($0.name, $0.digest) })
    let specification = output.specification
    guard specification.gameId == input.selection.gameId, specification.gameBuildId == input.selection.gameBuild.id,
          specification.launcherBuildId == input.selection.launcherBuild?.id,
          specification.profile.id == profile.profileId, specification.profile.revision == profile.revision,
          specification.profile.payloadDigest == CanonicalJSON.digest(profileBytes),
          specification.runtimeGenerationId == manifest.generationId,
          specification.componentDigests == expectedComponents,
          specification.hostClassId == (try input.selection.host.localClassId()),
          specification.certification.level == profile.certification.level,
          specification.certification.matrixDigest == profile.certification.matrixDigest else {
        throw FuzzAuditFailure.invalidOutput
    }
}
