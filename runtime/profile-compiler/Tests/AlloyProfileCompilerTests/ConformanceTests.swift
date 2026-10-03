// Author: Tim Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

/// One invalid fixture and the exact `ValidationFailure` it must produce.
/// Equality on `ValidationFailure` compares every associated value, so this
/// is "accept/reject AND the specific reason" in one assertion, not just
/// "something was thrown".
struct InvalidCase: Sendable, CustomStringConvertible {
    let fixture: String
    let expected: ValidationFailure
    var description: String { fixture }
}

// MARK: - Game profile

/// Loaded once at suite-discovery time; a missing or unreadable fixture
/// directory fails every test in the suite immediately and loudly rather
/// than quietly running zero parameterized cases.
let validGameProfileFixtureNames = fixtureNamesOrFail(.gameProfile, bucket: "valid")
let validRuntimeManifestFixtureNames = fixtureNamesOrFail(.runtimeManifest, bucket: "valid")

private func fixtureNamesOrFail(_ kind: FixtureKind, bucket: String) -> [String] {
    guard let names = try? fixtureNames(kind, bucket: bucket) else {
        fatalError("could not list \(kind.rawValue)/\(bucket) fixtures")
    }
    return names
}

@Suite("Game profile conformance")
struct GameProfileConformanceTests {
    @Test("every fixture under GameProfile/valid/ parses", arguments: validGameProfileFixtureNames)
    func validFixtureParses(name: String) throws {
        let data = try fixtureData(.gameProfile, "valid/\(name)")
        _ = try GameProfileValidator.validate(data)
    }

    @Test("the published example-game-profile.yaml, converted to JSON, decodes its known fields")
    func exampleFixtureDecodesKnownFields() throws {
        let data = try fixtureData(.gameProfile, "valid/example-game-profile.json")
        let profile = try GameProfileValidator.validate(data)

        #expect(profile.profileId == "example.steam.123456.macos-arm64")
        #expect(profile.revision == 42)
        #expect(profile.game.storefronts.map(\.appId) == ["123456"])
        #expect(profile.runtime.cpuProvider == .fexArm64ec)
        #expect(profile.processPolicies.count == 2)
        #expect(profile.certification.level == .certified)
    }

    @Test("the minimal fixture carries only the schema's required fields")
    func minimalFixtureHasNoOptionalFields() throws {
        let data = try fixtureData(.gameProfile, "valid/minimal.json")
        let profile = try GameProfileValidator.validate(data)

        #expect(profile.supersedes == nil)
        #expect(profile.filesystem == nil)
        #expect(profile.registry == nil)
        #expect(profile.dependencies == nil)
        #expect(profile.healthChecks == nil)
        #expect(profile.telemetry == nil)
        #expect(profile.game.publisher == nil)
        #expect(profile.selectors.launcherBuild == nil)
        #expect(profile.processPolicies.count == 1)
        #expect(profile.processPolicies[0].services == nil)
    }

    @Test("the maximal fixture carries every optional field the schema defines")
    func maximalFixtureHasEveryOptionalField() throws {
        let data = try fixtureData(.gameProfile, "valid/maximal.json")
        let profile = try GameProfileValidator.validate(data)

        #expect(profile.supersedes != nil)
        #expect(profile.filesystem?.driveMappings?.count == 7)
        #expect(profile.registry?.sets?.count == 2)
        #expect(profile.dependencies?.count == 2)
        #expect(profile.healthChecks?.count == 8)
        #expect(profile.telemetry != nil)
        #expect(profile.game.publisher != nil)
        #expect(profile.selectors.launcherBuild != nil)
        #expect(profile.selectors.host.macos?.allowedBuilds != nil)
        let launcher = try #require(profile.processPolicies.first)
        #expect(launcher.services != nil)
        #expect(launcher.execution.dllOverrides?.count == 2)
        #expect(launcher.execution.environment != nil)
        #expect(profile.certification.knownLimitations != nil)
        #expect(profile.certification.expiresAt != nil)
    }

    @Test("every invalid fixture is rejected for its one named reason", arguments: gameProfileInvalidCases)
    func invalidFixtureIsRejectedForItsReason(testCase: InvalidCase) throws {
        let data = try fixtureData(.gameProfile, "invalid/\(testCase.fixture).json")
        #expect(throws: testCase.expected) {
            _ = try GameProfileValidator.validate(data)
        }
    }

    @Test("the invalid-fixture table matches the invalid/ directory exactly, in both directions")
    func invalidTableMatchesDirectory() throws {
        let onDisk = Set(
            try fixtureNames(.gameProfile, bucket: "invalid").map { $0.replacingOccurrences(of: ".json", with: "") }
        )
        let tabled = Set(gameProfileInvalidCases.map(\.fixture))
        #expect(onDisk == tabled)
    }
}

private let gameProfileInvalidCases: [InvalidCase] = [
    InvalidCase(fixture: "missing-schema-version", expected: .missingRequiredKey(path: "$", key: "schemaVersion")),
    InvalidCase(fixture: "unknown-top-level-key", expected: .unknownKey(path: "$", key: "bogusField")),
    InvalidCase(
        fixture: "wrong-schema-version-const",
        expected: .constMismatch(path: "$.schemaVersion", expected: "1.0", actual: "2.0")
    ),
    InvalidCase(
        fixture: "profile-id-pattern",
        expected: .patternMismatch(path: "$.profileId", pattern: SchemaPattern.profileId, actual: "AB")
    ),
    InvalidCase(
        fixture: "revision-below-minimum",
        expected: .belowMinimum(path: "$.revision", minimum: 1, actual: 0)
    ),
    InvalidCase(fixture: "revision-wrong-type", expected: .wrongType(path: "$.revision", expected: "integer")),
    InvalidCase(
        fixture: "empty-storefronts",
        expected: .tooFewItems(path: "$.game.storefronts", minimum: 1, actual: 0)
    ),
    InvalidCase(
        fixture: "storefront-missing-appid",
        expected: .missingRequiredKey(path: "$.game.storefronts[0]", key: "appId")
    ),
    InvalidCase(
        fixture: "storefront-bad-kind-enum",
        expected: .enumMismatch(
            path: "$.game.storefronts[0].kind",
            allowed: StorefrontKind.allCases.map(\.rawValue).sorted(),
            actual: "nintendo"
        )
    ),
    InvalidCase(
        fixture: "build-selector-no-selector-present",
        expected: .noSelectorPresent(path: "$.selectors.gameBuild", oneOf: ["version", "manifestId", "requiredFiles"])
    ),
    InvalidCase(
        fixture: "host-architecture-const",
        expected: .constMismatch(path: "$.selectors.host.architecture", expected: "arm64", actual: "x86_64")
    ),
    InvalidCase(
        fixture: "gpu-families-duplicate",
        expected: .duplicateItems(path: "$.selectors.host.gpuFamilies")
    ),
    InvalidCase(
        fixture: "memory-class-below-minimum",
        expected: .belowMinimum(path: "$.selectors.host.memoryClassesGiB[0]", minimum: 8, actual: 4)
    ),
    InvalidCase(fixture: "layers-empty", expected: .tooFewItems(path: "$.runtime.layers", minimum: 1, actual: 0)),
    InvalidCase(
        fixture: "layer-digest-pattern",
        expected: .patternMismatch(
            path: "$.runtime.layers[0].digest",
            pattern: SchemaPattern.digestWithAlgorithm,
            actual: "not-a-digest"
        )
    ),
    InvalidCase(
        fixture: "cpu-provider-bad-enum",
        expected: .enumMismatch(
            path: "$.runtime.cpuProvider",
            allowed: CPUProvider.allCases.map(\.rawValue).sorted(),
            actual: "amd64-native"
        )
    ),
    InvalidCase(
        fixture: "process-policies-empty",
        expected: .tooFewItems(path: "$.processPolicies", minimum: 1, actual: 0)
    ),
    InvalidCase(
        fixture: "process-policy-priority-above-maximum",
        expected: .aboveMaximum(path: "$.processPolicies[0].priority", maximum: 100_000, actual: 200_000)
    ),
    InvalidCase(
        fixture: "process-match-empty",
        expected: .tooFewProperties(path: "$.processPolicies[0].match", minimum: 1, actual: 0)
    ),
    InvalidCase(
        fixture: "process-match-unknown-key",
        expected: .unknownKey(path: "$.processPolicies[0].match", key: "unexpectedField")
    ),
    InvalidCase(
        fixture: "process-execution-bad-dll-override-enum",
        expected: .enumMismatch(
            path: "$.processPolicies[0].execution.dllOverrides.d3d9",
            allowed: DLLLoadOrder.allCases.map(\.rawValue).sorted(),
            actual: "bogus-order"
        )
    ),
    InvalidCase(
        fixture: "drive-mapping-letter-pattern",
        expected: .patternMismatch(
            path: "$.filesystem.driveMappings[0].letter",
            pattern: SchemaPattern.driveLetter,
            actual: "c"
        )
    ),
    InvalidCase(
        fixture: "drive-mapping-bad-access-enum",
        expected: .enumMismatch(
            path: "$.filesystem.driveMappings[0].access",
            allowed: DriveAccess.allCases.map(\.rawValue).sorted(),
            actual: "read"
        )
    ),
    InvalidCase(
        fixture: "registry-mutation-missing-value",
        expected: .missingRequiredKey(path: "$.registry.sets[0]", key: "value")
    ),
    InvalidCase(
        fixture: "dependency-bad-source-enum",
        expected: .enumMismatch(
            path: "$.dependencies[0].source",
            allowed: DependencySource.allCases.map(\.rawValue).sorted(),
            actual: "torrent"
        )
    ),
    InvalidCase(
        fixture: "health-check-deadline-below-minimum",
        expected: .belowMinimum(path: "$.healthChecks[0].deadlineSeconds", minimum: 1, actual: 0)
    ),
    InvalidCase(
        fixture: "telemetry-sampling-above-maximum",
        expected: .aboveMaximum(path: "$.telemetry.sampling", maximum: 1, actual: 1.5)
    ),
    InvalidCase(
        fixture: "certification-missing-matrix-digest",
        expected: .missingRequiredKey(path: "$.certification", key: "matrixDigest")
    ),
    InvalidCase(
        fixture: "certification-tested-at-bad-format",
        expected: .formatMismatch(path: "$.certification.testedAt", format: "date-time", actual: "not-a-date")
    ),
    InvalidCase(
        fixture: "certification-matrix-digest-pattern",
        expected: .patternMismatch(
            path: "$.certification.matrixDigest",
            pattern: SchemaPattern.digestWithAlgorithm,
            actual: "sha256:xyz"
        )
    ),
    InvalidCase(
        fixture: "certification-level-bad-enum",
        expected: .enumMismatch(
            path: "$.certification.level",
            allowed: CertificationLevel.allCases.map(\.rawValue).sorted(),
            actual: "gold"
        )
    ),
    InvalidCase(fixture: "root-not-object", expected: .notAnObject(path: "$"))
]

// MARK: - Runtime manifest

@Suite("Runtime manifest conformance")
struct RuntimeManifestConformanceTests {
    @Test("every fixture under RuntimeManifest/valid/ parses", arguments: validRuntimeManifestFixtureNames)
    func validFixtureParses(name: String) throws {
        let data = try fixtureData(.runtimeManifest, "valid/\(name)")
        _ = try RuntimeManifestValidator.validate(data)
    }

    @Test("the minimal fixture carries only the schema's required fields")
    func minimalFixtureHasNoOptionalFields() throws {
        let data = try fixtureData(.runtimeManifest, "valid/minimal.json")
        let manifest = try RuntimeManifestValidator.validate(data)

        #expect(manifest.activation == nil)
        #expect(manifest.components.count == 1)
        #expect(manifest.components[0].licenseId == nil)
        #expect(manifest.hostRequirements.metalFeatureSets == nil)
    }

    @Test("the maximal fixture carries every optional field the schema defines")
    func maximalFixtureHasEveryOptionalField() throws {
        let data = try fixtureData(.runtimeManifest, "valid/maximal.json")
        let manifest = try RuntimeManifestValidator.validate(data)

        #expect(manifest.activation?.releaseRing == .canary)
        #expect(manifest.hostRequirements.metalFeatureSets != nil)
        #expect(manifest.hostRequirements.requiredEntitlements != nil)
        #expect(manifest.provenance.reproducible == true)
        let wine = try #require(manifest.components.first)
        #expect(wine.licenseId != nil)
        #expect(wine.sbomDigest != nil)
        #expect(wine.symbolsDigest != nil)
    }

    @Test("every invalid fixture is rejected for its one named reason", arguments: runtimeManifestInvalidCases)
    func invalidFixtureIsRejectedForItsReason(testCase: InvalidCase) throws {
        let data = try fixtureData(.runtimeManifest, "invalid/\(testCase.fixture).json")
        #expect(throws: testCase.expected) {
            _ = try RuntimeManifestValidator.validate(data)
        }
    }

    @Test("the invalid-fixture table matches the invalid/ directory exactly, in both directions")
    func invalidTableMatchesDirectory() throws {
        let onDisk = Set(
            try fixtureNames(.runtimeManifest, bucket: "invalid").map { $0.replacingOccurrences(of: ".json", with: "") }
        )
        let tabled = Set(runtimeManifestInvalidCases.map(\.fixture))
        #expect(onDisk == tabled)
    }
}

private let runtimeManifestInvalidCases: [InvalidCase] = [
    InvalidCase(
        fixture: "rm-missing-generation-id",
        expected: .missingRequiredKey(path: "$", key: "generationId")
    ),
    InvalidCase(fixture: "rm-unknown-top-level-key", expected: .unknownKey(path: "$", key: "bogusField")),
    InvalidCase(
        fixture: "rm-generation-id-pattern",
        expected: .patternMismatch(path: "$.generationId", pattern: SchemaPattern.generationId, actual: "bad-id")
    ),
    InvalidCase(
        fixture: "rm-schema-version-const",
        expected: .constMismatch(path: "$.schemaVersion", expected: "1.0", actual: "1.1")
    ),
    InvalidCase(
        fixture: "rm-created-at-bad-format",
        expected: .formatMismatch(path: "$.createdAt", format: "date-time", actual: "yesterday")
    ),
    InvalidCase(
        fixture: "rm-components-empty",
        expected: .tooFewItems(path: "$.components", minimum: 1, actual: 0)
    ),
    InvalidCase(
        fixture: "rm-component-missing-size",
        expected: .missingRequiredKey(path: "$.components[0]", key: "size")
    ),
    InvalidCase(
        fixture: "rm-component-digest-pattern",
        expected: .patternMismatch(
            path: "$.components[0].digest",
            pattern: SchemaPattern.digestWithAlgorithm,
            actual: "sha256:zz"
        )
    ),
    InvalidCase(
        fixture: "rm-component-size-below-minimum",
        expected: .belowMinimum(path: "$.components[0].size", minimum: 0, actual: -1)
    ),
    InvalidCase(
        fixture: "rm-component-size-wrong-type",
        expected: .wrongType(path: "$.components[0].size", expected: "integer")
    ),
    InvalidCase(
        fixture: "rm-host-architecture-const",
        expected: .constMismatch(path: "$.hostRequirements.architecture", expected: "arm64", actual: "x64")
    ),
    InvalidCase(
        fixture: "rm-provenance-missing-attestation",
        expected: .missingRequiredKey(path: "$.provenance", key: "attestationDigest")
    ),
    InvalidCase(
        fixture: "rm-activation-bad-release-ring-enum",
        expected: .enumMismatch(
            path: "$.activation.releaseRing",
            allowed: ReleaseRing.allCases.map(\.rawValue).sorted(),
            actual: "beta"
        )
    ),
    InvalidCase(
        fixture: "rm-activation-health-window-below-minimum",
        expected: .belowMinimum(path: "$.activation.healthWindowSessions", minimum: 1, actual: 0)
    ),
    InvalidCase(fixture: "rm-root-not-object", expected: .notAnObject(path: "$"))
]
