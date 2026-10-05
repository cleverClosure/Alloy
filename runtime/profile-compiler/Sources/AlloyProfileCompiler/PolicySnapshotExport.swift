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
    public let inspection: PolicySnapshotV2Inspection
    public let notYetLowered: [SnapshotCoverageGap]

    /// Readiness is conditional on complete v2 field coverage; production trust is separate.
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
            schemaVersion: 2, defaultPolicy: wirePolicy(defaultPolicy),
            processPolicies: processes.map { WireProcess(imageSHA256: $0.imageSHA256, policy: wirePolicy($0.policy)) }
        )
        let sourceBytes = try CanonicalJSON.encode(source)
        let bytes = try PolicySnapshotV2.compile(source: sourceBytes)
        let gaps = policies.flatMap(coverage).sorted {
            ($0.policyId, $0.field) < ($1.policyId, $1.field)
        }
        return PolicySnapshotExport(
            bytes: bytes, digest: CanonicalJSON.digest(bytes), source: sourceBytes,
            inspection: try PolicySnapshotV2.inspect(snapshot: bytes), notYetLowered: gaps
        )
    }

    private static func wirePolicy(_ policy: SnapshotPolicy) -> WirePolicy {
        let resolved = policy.resolved
        let cpu = SnapshotCPUProvider(rawValue: resolved.cpuProvider)
        return WirePolicy(
            id: policy.id, graphicsProvider: resolved.graphicsProvider,
            providerDirectory: policy.providerDirectory, cpuProvider: cpu,
            environment: resolved.environment.isEmpty ? nil : resolved.environment,
            workingDirectory: resolved.workingDirectory,
            dllRoutes: resolved.dllOverrides.map { WireRoute(module: $0.key, loadOrder: $0.value) }
                .sorted { $0.module < $1.module }
        )
    }

    private static func coverage(_ policy: SnapshotPolicy) -> [SnapshotCoverageGap] {
        let resolved = policy.resolved
        var fields: [String] = []
        if SnapshotCPUProvider(rawValue: resolved.cpuProvider) == nil { fields.append("cpuProvider") }
        // These neutral modes request no additional service or restriction. They
        // preserve the pinned Darwin runtime's stock synchronization, networking
        // and lack of optional Alloy diagnostics. Restrictive/capture modes are
        // never silently collapsed into these neutral values.
        if resolved.syncProvider != "conservative" { fields.append("syncProvider") }
        if resolved.networkPolicy != "allow" { fields.append("networkPolicy") }
        if resolved.debugPolicy != "off" { fields.append("debugPolicy") }
        if resolved.featureMask != nil { fields.append("featureMask") }
        if !resolved.services.isEmpty { fields.append("services") }
        return fields.map {
            SnapshotCoverageGap(policyId: policy.id, field: $0, reason: "requires enforcement beyond Wine snapshot v2")
        }
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
    let cpuProvider: SnapshotCPUProvider?
    let environment: [String: String]?
    let workingDirectory: String?
    let dllRoutes: [WireRoute]
}

private struct WireRoute: Encodable {
    let module: String
    let loadOrder: String
}
