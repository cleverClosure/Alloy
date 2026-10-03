// Author: Timur Isaev

import Foundation

public struct ResolvedProcessPolicy: Codable, Equatable, Sendable {
    public var ruleIds: [String]
    public var cpuProvider: String
    public var graphicsProvider: String
    public var syncProvider: String
    public var featureMask: String?
    public var dllOverrides: [String: String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var networkPolicy: String
    public var debugPolicy: String
    public var services: [String: String]

    static func conservativeDefault(_ runtime: RuntimeConfiguration) -> Self {
        Self(
            ruleIds: [], cpuProvider: runtime.cpuProvider.rawValue,
            graphicsProvider: runtime.defaultGraphicsProvider.rawValue, syncProvider: "conservative",
            featureMask: nil, dllOverrides: [:], environment: [:], workingDirectory: nil,
            networkPolicy: "deny", debugPolicy: "crash-only", services: [:]
        )
    }
}

public enum ProcessResolver {
    public static func resolve(
        _ policies: [ProcessPolicy], runtime: RuntimeConfiguration, process: ProcessIdentity,
        parent: ResolvedProcessPolicy? = nil
    ) throws -> ResolvedProcessPolicy {
        guard Set(policies.map(\.id)).count == policies.count, policies.allSatisfy({ !$0.id.isEmpty }) else {
            throw CompilerFailure.rejected("duplicate or empty process rule ID")
        }
        // Validate regexes even when another match dimension would make the rule inapplicable.
        for policy in policies {
            if let pattern = policy.match.commandLineRegex { _ = try ProcessMatcher.safeExpression(pattern) }
            _ = try normalizedOverrides(policy.execution.dllOverrides ?? [:])
        }
        let matching = try policies.filter { try ProcessMatcher.matches($0.match, process: process) }
        guard !matching.isEmpty else { return .conservativeDefault(runtime) }
        let digestRank = matching.map { $0.match.sha256 == nil ? 0 : 1 }.max()!
        let byDigest = matching.filter { ($0.match.sha256 == nil ? 0 : 1) == digestRank }
        let parentRank = byDigest.map { relationshipRank($0.match) }.max()!
        let byParent = byDigest.filter { relationshipRank($0.match) == parentRank }
        let priority = byParent.map(\.priority).max()!
        let finalists = byParent.filter { $0.priority == priority }
        var resolved = try finalists.map { try materialize($0, runtime: runtime, process: process, parent: parent) }
        // Compose denials from every applicable rule, including lower-priority ones.
        for index in resolved.indices { composeRestrictions(matching, into: &resolved[index]) }
        guard var winner = resolved.first, resolved.allSatisfy({ $0 == winner }) else {
            throw CompilerFailure.rejected("process-policy-conflict")
        }
        winner.ruleIds = finalists.map(\.id).sorted()
        return winner
    }

    private static func materialize(
        _ policy: ProcessPolicy, runtime: RuntimeConfiguration, process: ProcessIdentity,
        parent: ResolvedProcessPolicy?
    ) throws -> ResolvedProcessPolicy {
        let execution = policy.execution
        var result = ResolvedProcessPolicy.conservativeDefault(runtime)
        let validParent = parent.flatMap { value in
            process.parentPolicyId.map { value.ruleIds.contains($0) } == true ? value : nil
        }
        func provider(_ value: String?, fallback: String, inherited: String?) throws -> String {
            guard let value else { return fallback }
            guard value == "inherit" else { return value }
            guard let inherited else {
                throw CompilerFailure.rejected("explicit inheritance requires a resolved parent")
            }
            return inherited
        }
        result.cpuProvider = try provider(
            execution.cpuProvider?.rawValue, fallback: result.cpuProvider, inherited: validParent?.cpuProvider
        )
        result.graphicsProvider = try provider(
            execution.graphicsProvider?.rawValue, fallback: result.graphicsProvider,
            inherited: validParent?.graphicsProvider
        )
        result.syncProvider = try provider(
            execution.syncProvider?.rawValue, fallback: result.syncProvider, inherited: validParent?.syncProvider
        )
        result.networkPolicy = try provider(
            execution.networkPolicy?.rawValue, fallback: result.networkPolicy, inherited: validParent?.networkPolicy
        )
        result.featureMask = execution.featureMask
        result.dllOverrides = try normalizedOverrides(execution.dllOverrides ?? [:])
        result.environment = execution.environment ?? [:]
        result.workingDirectory = execution.workingDirectory
        result.debugPolicy = execution.debugPolicy?.rawValue ?? result.debugPolicy
        if let services = policy.services {
            result.services = [
                "audio": services.audio, "input": services.input, "media": services.media,
                "presentation": services.presentation, "storage": services.storage
            ].compactMapValues { $0 }
        }
        return result
    }

    private static func normalizedOverrides(_ values: [String: DLLLoadOrder]) throws -> [String: String] {
        var result: [String: String] = [:]
        for (name, order) in values {
            let normalized = dllName(name)
            guard !normalized.isEmpty, !normalized.contains(where: { "/\\:".contains($0) }),
                  result.updateValue(order.rawValue, forKey: normalized) == nil else {
                throw CompilerFailure.rejected("ambiguous DLL override")
            }
        }
        return result
    }

    private static func composeRestrictions(_ policies: [ProcessPolicy], into result: inout ResolvedProcessPolicy) {
        if policies.contains(where: { $0.execution.networkPolicy == .deny }) {
            result.networkPolicy = "deny"
        } else if policies.contains(where: { $0.execution.networkPolicy == .publisherOnly }),
                  result.networkPolicy == "allow" {
            result.networkPolicy = "publisher-only"
        }
        for policy in policies {
            for (name, order) in policy.execution.dllOverrides ?? [:] where order == .disabled {
                let key = dllName(name)
                result.dllOverrides[key] = "disabled"
            }
        }
    }

    private static func dllName(_ name: String) -> String {
        name.lowercased().hasSuffix(".dll") ? String(name.dropLast(4)).lowercased() : name.lowercased()
    }

    private static func relationshipRank(_ match: ProcessMatch) -> Int {
        match.parentPolicyId != nil && (match.sha256 != nil || match.pathGlob != nil) ? 1 : 0
    }
}
