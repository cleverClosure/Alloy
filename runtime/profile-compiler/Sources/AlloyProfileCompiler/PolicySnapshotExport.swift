// Author: Timur Isaev

import AlloyPolicySnapshot
import Foundation

public struct SnapshotPolicy: Sendable {
    public let id: String
    public let providerDirectory: String
    public let resolved: ResolvedProcessPolicy

    public init(id: String, providerDirectory: String, resolved: ResolvedProcessPolicy) {
        self.id = id
        self.providerDirectory = providerDirectory
        self.resolved = resolved
    }
}

public struct SnapshotProcess: Sendable {
    public let imageSHA256: String
    public let policy: SnapshotPolicy

    public init(imageSHA256: String, policy: SnapshotPolicy) {
        self.imageSHA256 = imageSHA256
        self.policy = policy
    }
}

public struct SnapshotCoverageGap: Codable, Equatable, Sendable {
    public let policyId: String
    public let field: String
    public let reason: String
}

public struct PolicySnapshotExport: Sendable {
    public let bytes: Data
    public let digest: String
    public let source: Data
    public let inspection: PolicySnapshotInspection
    public let notYetLowered: [SnapshotCoverageGap]

    /// A v1 projection does not enforce the complete resolved policy.
    public var runtimeReady: Bool { notYetLowered.isEmpty }
}

public enum PolicySnapshotExporter {
    public static func export(
        defaultPolicy: SnapshotPolicy, processes: [SnapshotProcess]
    ) throws -> PolicySnapshotExport {
        let policies = [defaultPolicy] + processes.map(\.policy)
        for policy in policies {
            let components = policy.providerDirectory.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
            guard !components.contains("..") else { throw CompilerFailure.rejected("provider path traversal") }
        }
        let source = WireSource(
            schemaVersion: 1, defaultPolicy: wirePolicy(defaultPolicy),
            processPolicies: processes.map { WireProcess(imageSHA256: $0.imageSHA256, policy: wirePolicy($0.policy)) }
        )
        let sourceBytes = try CanonicalJSON.encode(source)
        let bytes = try PolicySnapshotCompiler.compile(source: sourceBytes)
        let gaps = policies.flatMap(coverage).sorted {
            ($0.policyId, $0.field) < ($1.policyId, $1.field)
        }
        return PolicySnapshotExport(
            bytes: bytes, digest: CanonicalJSON.digest(bytes), source: sourceBytes,
            inspection: try PolicySnapshotCompiler.inspect(snapshot: bytes), notYetLowered: gaps
        )
    }

    private static func wirePolicy(_ policy: SnapshotPolicy) -> WirePolicy {
        var routes = policy.resolved.dllOverrides.map { WireRoute(module: $0.key, loadOrder: $0.value) }
        if routes.isEmpty {
            // The v1 library requires a nonempty route table. This inert disabled
            // slot is an explicit diagnostic projection, reported in coverage below.
            routes = [WireRoute(module: "__alloy_empty_route__", loadOrder: "disabled")]
        }
        return WirePolicy(
            id: policy.id, graphicsProvider: policy.resolved.graphicsProvider,
            providerDirectory: policy.providerDirectory, dllRoutes: routes.sorted { $0.module < $1.module }
        )
    }

    private static func coverage(_ policy: SnapshotPolicy) -> [SnapshotCoverageGap] {
        let resolved = policy.resolved
        var fields = ["cpuProvider", "syncProvider", "networkPolicy", "debugPolicy"]
        if resolved.featureMask != nil { fields.append("featureMask") }
        if !resolved.environment.isEmpty { fields.append("environment") }
        if resolved.workingDirectory != nil { fields.append("workingDirectory") }
        if !resolved.services.isEmpty { fields.append("services") }
        var gaps = fields.map {
            SnapshotCoverageGap(policyId: policy.id, field: $0, reason: "not representable in Wine snapshot v1")
        }
        if resolved.dllOverrides.isEmpty {
            gaps.append(SnapshotCoverageGap(
                policyId: policy.id, field: "dllOverrides.empty",
                reason: "v1 requires one route; diagnostic projection uses a disabled __alloy_empty_route__ slot"
            ))
        }
        return gaps
    }
}

private struct WireSource: Encodable {
    let schemaVersion: Int
    let defaultPolicy: WirePolicy
    let processPolicies: [WireProcess]
}

private struct WireProcess: Encodable {
    let imageSHA256: String
    let policy: WirePolicy
}

private struct WirePolicy: Encodable {
    let id: String
    let graphicsProvider: String
    let providerDirectory: String
    let dllRoutes: [WireRoute]
}

private struct WireRoute: Encodable {
    let module: String
    let loadOrder: String
}
