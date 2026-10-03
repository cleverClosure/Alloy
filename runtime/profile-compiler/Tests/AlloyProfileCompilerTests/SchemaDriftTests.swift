// Author: Tim Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

/// Every one of these tests reads the live schema file and compares it
/// against the Swift validator's own declared shape — never the other way
/// around. A schema edit that adds, removes, or renames a property, a
/// required field, or an enum value turns the matching assertion red here,
/// which is the whole point: the validator must never silently fall behind
/// the schema it claims to enforce.
private func assertObjectShape<K>(
    _ node: SchemaNode?,
    keys: K.Type,
    required: Set<K>,
    sourceLocation: SourceLocation = #_sourceLocation
) where K: CodingKey & CaseIterable & RawRepresentable, K.RawValue == String {
    guard let node else {
        Issue.record("schema node not found", sourceLocation: sourceLocation)
        return
    }
    let swiftProperties = Set(K.allCases.map(\.rawValue))
    #expect(
        node.properties == swiftProperties, "declared properties differ from the schema", sourceLocation: sourceLocation
    )
    let swiftRequired = Set(required.map(\.rawValue))
    #expect(node.required == swiftRequired, "required keys differ from the schema", sourceLocation: sourceLocation)
}

private func assertEnum<E>(
    _ values: [String]?,
    matches type: E.Type,
    sourceLocation: SourceLocation = #_sourceLocation
) where E: RawRepresentable & CaseIterable, E.RawValue == String {
    guard let values else {
        Issue.record("schema node has no enum/const values", sourceLocation: sourceLocation)
        return
    }
    #expect(Set(values) == Set(E.allCases.map(\.rawValue)), sourceLocation: sourceLocation)
}

private func assertConst(
    _ node: SchemaNode?,
    equals expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(node?.raw["const"] as? String == expected, sourceLocation: sourceLocation)
}

@Suite("Game profile schema drift")
struct GameProfileSchemaDriftTests {
    private static let schema = gameProfileSchema

    @Test
    func rootShape() {
        assertObjectShape(
            Self.schema, keys: GameProfileDocument.CodingKeys.self, required: GameProfileDocument.requiredKeys
        )
        assertConst(Self.schema.property("schemaVersion"), equals: "1.0")
    }

    @Test
    func gameShape() {
        let game = Self.schema.property("game")
        assertObjectShape(game, keys: GameInfo.CodingKeys.self, required: [.canonicalId, .displayName, .storefronts])
        let storefront = game?.property("storefronts")?.items()
        assertObjectShape(storefront, keys: Storefront.CodingKeys.self, required: [.kind, .appId])
        assertEnum(storefront?.property("kind")?.enumValues(), matches: StorefrontKind.self)
    }

    @Test
    func selectorsShape() {
        let selectors = Self.schema.property("selectors")
        assertObjectShape(selectors, keys: ProfileSelectors.CodingKeys.self, required: [.gameBuild, .host])

        for key in ["gameBuild", "launcherBuild"] {
            let buildSelector = selectors?.property(key)
            assertObjectShape(buildSelector, keys: BuildSelector.CodingKeys.self, required: [])
            let requiredFile = buildSelector?.property("requiredFiles")?.items()
            assertObjectShape(requiredFile, keys: RequiredFile.CodingKeys.self, required: [.path, .sha256])
        }

        let host = selectors?.property("host")
        assertObjectShape(host, keys: HostSelector.CodingKeys.self, required: [.architecture, .macos])
        assertConst(host?.property("architecture"), equals: "arm64")
        assertObjectShape(host?.property("macos"), keys: MacOSRange.CodingKeys.self, required: [])
    }

    @Test
    func runtimeShape() {
        let runtime = Self.schema.property("runtime")
        assertObjectShape(
            runtime, keys: RuntimeConfiguration.CodingKeys.self, required: RuntimeConfiguration.requiredKeys
        )
        let layer = runtime?.property("layers")?.items()
        assertObjectShape(layer, keys: LayerSpec.CodingKeys.self, required: [.role, .digest])
        assertEnum(layer?.property("role")?.enumValues(), matches: ProfileLayerRole.self)
        assertEnum(runtime?.property("cpuProvider")?.enumValues(), matches: CPUProvider.self)
        assertEnum(runtime?.property("defaultGraphicsProvider")?.enumValues(), matches: GraphicsProvider.self)
        assertEnum(runtime?.property("syncProvider")?.enumValues(), matches: SyncProvider.self)
        assertEnum(runtime?.property("timezoneMode")?.enumValues(), matches: TimezoneMode.self)
    }

    @Test
    func processPolicyShape() {
        let policy = Self.schema.property("processPolicies")?.items()
        assertObjectShape(policy, keys: ProcessPolicy.CodingKeys.self, required: ProcessPolicy.requiredKeys)

        let match = policy?.property("match")
        assertObjectShape(match, keys: ProcessMatch.CodingKeys.self, required: [])
        assertEnum(match?.property("peMachine")?.enumValues(), matches: PEMachine.self)

        let execution = policy?.property("execution")
        assertObjectShape(execution, keys: ProcessExecution.CodingKeys.self, required: [])
        assertEnum(execution?.property("cpuProvider")?.enumValues(), matches: ExecutionCPUProvider.self)
        assertEnum(execution?.property("graphicsProvider")?.enumValues(), matches: ExecutionGraphicsProvider.self)
        assertEnum(execution?.property("syncProvider")?.enumValues(), matches: ExecutionSyncProvider.self)
        assertEnum(execution?.property("dllOverrides")?.additionalPropertiesEnumValues(), matches: DLLLoadOrder.self)
        assertEnum(execution?.property("networkPolicy")?.enumValues(), matches: ProcessNetworkPolicy.self)
        assertEnum(execution?.property("debugPolicy")?.enumValues(), matches: ProcessDebugPolicy.self)

        let services = policy?.property("services")
        assertObjectShape(services, keys: ProcessServices.CodingKeys.self, required: [])
    }

    @Test
    func filesystemAndRegistryShape() {
        let filesystem = Self.schema.property("filesystem")
        assertObjectShape(filesystem, keys: FilesystemPolicy.CodingKeys.self, required: [])
        let mapping = filesystem?.property("driveMappings")?.items()
        assertObjectShape(mapping, keys: DriveMapping.CodingKeys.self, required: DriveMapping.requiredKeys)
        assertEnum(mapping?.property("target")?.enumValues(), matches: DriveTarget.self)
        assertEnum(mapping?.property("access")?.enumValues(), matches: DriveAccess.self)
        assertEnum(filesystem?.property("caseMode")?.enumValues(), matches: FilesystemCaseMode.self)

        let registry = Self.schema.property("registry")
        assertObjectShape(registry, keys: RegistryPolicy.CodingKeys.self, required: [])
        let mutation = registry?.property("sets")?.items()
        assertObjectShape(mutation, keys: RegistryMutation.CodingKeys.self, required: RegistryMutation.requiredKeys)
        assertEnum(mutation?.property("type")?.enumValues(), matches: RegistryValueType.self)
    }

    @Test
    func dependenciesAndHealthChecksShape() {
        let dependency = Self.schema.property("dependencies")?.items()
        assertObjectShape(dependency, keys: Dependency.CodingKeys.self, required: Dependency.requiredKeys)
        assertEnum(dependency?.property("source")?.enumValues(), matches: DependencySource.self)
        assertEnum(dependency?.property("installMode")?.enumValues(), matches: DependencyInstallMode.self)

        let healthCheck = Self.schema.property("healthChecks")?.items()
        assertObjectShape(healthCheck, keys: HealthCheck.CodingKeys.self, required: HealthCheck.requiredKeys)
        assertEnum(healthCheck?.property("kind")?.enumValues(), matches: HealthCheckKind.self)
        assertEnum(healthCheck?.property("severity")?.enumValues(), matches: HealthCheckSeverity.self)
    }

    @Test
    func telemetryAndCertificationShape() {
        let telemetry = Self.schema.property("telemetry")
        assertObjectShape(telemetry, keys: TelemetryPolicy.CodingKeys.self, required: [])
        assertEnum(telemetry?.property("defaultLevel")?.enumValues(), matches: TelemetryLevel.self)

        let certification = Self.schema.property("certification")
        assertObjectShape(
            certification, keys: CertificationRecord.CodingKeys.self, required: CertificationRecord.requiredKeys
        )
        assertEnum(certification?.property("level")?.enumValues(), matches: CertificationLevel.self)
    }
}

@Suite("Runtime manifest schema drift")
struct RuntimeManifestSchemaDriftTests {
    private static let schema = runtimeManifestSchema

    @Test
    func rootShape() {
        assertObjectShape(
            Self.schema, keys: RuntimeManifestDocument.CodingKeys.self, required: RuntimeManifestDocument.requiredKeys
        )
        assertConst(Self.schema.property("schemaVersion"), equals: "1.0")
    }

    @Test
    func componentsShape() {
        let component = Self.schema.property("components")?.items()
        assertObjectShape(component, keys: RuntimeComponent.CodingKeys.self, required: RuntimeComponent.requiredKeys)
    }

    @Test
    func hostRequirementsShape() {
        let host = Self.schema.property("hostRequirements")
        assertObjectShape(
            host, keys: RuntimeHostRequirements.CodingKeys.self, required: RuntimeHostRequirements.requiredKeys
        )
        assertConst(host?.property("architecture"), equals: "arm64")
    }

    @Test
    func provenanceShape() {
        let provenance = Self.schema.property("provenance")
        assertObjectShape(provenance, keys: RuntimeProvenance.CodingKeys.self, required: RuntimeProvenance.requiredKeys)
    }

    @Test
    func activationShape() {
        let activation = Self.schema.property("activation")
        assertObjectShape(activation, keys: RuntimeActivation.CodingKeys.self, required: [])
        assertEnum(activation?.property("releaseRing")?.enumValues(), matches: ReleaseRing.self)
    }
}
