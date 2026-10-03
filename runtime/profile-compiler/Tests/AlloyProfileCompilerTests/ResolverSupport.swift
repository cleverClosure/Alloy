// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

func replacing(_ object: [String: Any], path: [String], value: Any?) throws -> [String: Any] {
    var result = object
    let key = try #require(path.first)
    if path.count == 1 {
        result[key] = value
    } else {
        let child = try #require(result[key] as? [String: Any])
        result[key] = try replacing(child, path: Array(path.dropFirst()), value: value)
    }
    return result
}

func compilerProfile(_ patches: [String: Any] = [:]) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(
        with: fixtureData(.gameProfile, "valid/minimal.json")
    ) as? [String: Any])
    object = try replacing(object, path: ["runtime", "generation"], value: "rtg_minimal_fixture_0")
    for path in patches.keys.sorted() {
        let value = patches[path] is NSNull ? nil : patches[path]
        object = try replacing(object, path: path.components(separatedBy: "."), value: value)
    }
    return try JSONSerialization.data(withJSONObject: object)
}

func candidate(
    profile: Data, ring: ReleaseRing = .stable, metadataEdit: (inout CandidateMetadata) throws -> Void = { _ in }
) throws -> ProfileCandidate {
    let document = try GameProfileValidator.validate(profile)
    var metadata = CandidateMetadata(
        profileDigest: CanonicalJSON.digest(try CanonicalJSON.encode(profile)), releaseRing: ring,
        approvedCertification: document.certification.level
    )
    try metadataEdit(&metadata)
    return try ProfileCandidate(
        profile: signedFixture(profile),
        manifest: signedFixture(fixtureData(.runtimeManifest, "valid/minimal.json"), type: .runtimeManifest),
        metadata: signedFixture(CanonicalJSON.encode(metadata), type: .releaseMetadata),
        mode: testVerificationMode(), now: fixtureNow
    )
}

func selectionInput() -> SelectionInput {
    SelectionInput(
        gameId: "game_min_001", storefront: .standalone, appId: "0",
        gameBuild: BuildIdentity(id: "gb_fixture", version: "1.0.0", manifestId: "manifest-1"),
        host: HostCapabilities(
            architecture: "arm64", macOS: "15.1", macOSBuild: "24B1", gpuFamilies: ["apple8"], memoryGiB: 16
        ),
        client: ClientEligibility(
            id: "client-fixture", version: "1.0.0", allowedRings: [.development, .stable, .canary]
        ),
        now: fixtureNow
    )
}

func decodePolicies(_ value: Any) throws -> [ProcessPolicy] {
    try JSONDecoder().decode([ProcessPolicy].self, from: JSONSerialization.data(withJSONObject: value))
}
