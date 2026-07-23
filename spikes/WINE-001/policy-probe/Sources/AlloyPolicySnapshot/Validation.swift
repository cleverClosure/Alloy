// Author: Timur Isaev

import Foundation

enum PolicySnapshotError: Error, CustomStringConvertible {
    case invalid(String)
    case unsupportedVersion(Int)

    var description: String {
        switch self {
        case let .invalid(message):
            "invalid policy snapshot: \(message)"
        case let .unsupportedVersion(version):
            "unsupported policy source version \(version)"
        }
    }
}

enum SourceValidator {
    private static let rootKeys: Set<String> = [
        "schemaVersion",
        "defaultPolicy",
        "processPolicies"
    ]
    private static let processKeys: Set<String> = ["imageSHA256", "policy"]
    private static let policyKeys: Set<String> = [
        "id",
        "graphicsProvider",
        "providerDirectory",
        "dllRoutes"
    ]
    private static let routeKeys: Set<String> = ["module", "loadOrder"]

    static func validateKeys(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw PolicySnapshotError.invalid("source root must be an object")
        }
        try requireKeys(root, expected: rootKeys, at: "$")
        guard let defaultPolicy = root["defaultPolicy"] as? [String: Any] else {
            throw PolicySnapshotError.invalid("$.defaultPolicy must be an object")
        }
        try validatePolicy(defaultPolicy, at: "$.defaultPolicy")
        guard let processes = root["processPolicies"] as? [Any] else {
            throw PolicySnapshotError.invalid("$.processPolicies must be an array")
        }
        for (index, value) in processes.enumerated() {
            guard let process = value as? [String: Any] else {
                throw PolicySnapshotError.invalid("$.processPolicies[\(index)] must be an object")
            }
            try requireKeys(process, expected: processKeys, at: "$.processPolicies[\(index)]")
            guard let policy = process["policy"] as? [String: Any] else {
                throw PolicySnapshotError.invalid(
                    "$.processPolicies[\(index)].policy must be an object"
                )
            }
            try validatePolicy(policy, at: "$.processPolicies[\(index)].policy")
        }
    }

    private static func validatePolicy(_ policy: [String: Any], at path: String) throws {
        try requireKeys(policy, expected: policyKeys, at: path)
        guard let routes = policy["dllRoutes"] as? [Any] else {
            throw PolicySnapshotError.invalid("\(path).dllRoutes must be an array")
        }
        for (index, value) in routes.enumerated() {
            guard let route = value as? [String: Any] else {
                throw PolicySnapshotError.invalid("\(path).dllRoutes[\(index)] must be an object")
            }
            try requireKeys(route, expected: routeKeys, at: "\(path).dllRoutes[\(index)]")
        }
    }

    private static func requireKeys(
        _ object: [String: Any],
        expected: Set<String>,
        at path: String
    ) throws {
        let actual = Set(object.keys)
        guard actual == expected else {
            let missing = expected.subtracting(actual).sorted().joined(separator: ",")
            let unknown = actual.subtracting(expected).sorted().joined(separator: ",")
            throw PolicySnapshotError.invalid(
                "\(path) keys differ; missing=[\(missing)] unknown=[\(unknown)]"
            )
        }
    }
}

enum SemanticValidator {
    static func normalize(_ source: PolicySource) throws -> NormalizedPolicySource {
        guard source.schemaVersion == 1 else {
            throw PolicySnapshotError.unsupportedVersion(source.schemaVersion)
        }
        guard source.processPolicies.count <= SnapshotFormat.maximumProcessPolicies else {
            throw PolicySnapshotError.invalid("too many process policies")
        }

        let defaultPolicy = try normalizePolicy(source.defaultPolicy, at: "defaultPolicy")
        var processes = try source.processPolicies.enumerated().map { index, process in
            let digest = try normalizeDigest(process.imageSHA256)
            return NormalizedProcessPolicy(
                imageSHA256: digest,
                policy: try normalizePolicy(process.policy, at: "processPolicies[\(index)].policy")
            )
        }
        processes.sort { $0.imageSHA256 < $1.imageSHA256 }
        for index in processes.indices.dropFirst() {
            guard processes[index - 1].imageSHA256 != processes[index].imageSHA256 else {
                throw PolicySnapshotError.invalid(
                    "duplicate executable digest \(processes[index].imageSHA256)"
                )
            }
        }
        return NormalizedPolicySource(
            schemaVersion: 1,
            defaultPolicy: defaultPolicy,
            processPolicies: processes
        )
    }

    private static func normalizePolicy(
        _ policy: PolicyDefinition,
        at path: String
    ) throws -> NormalizedPolicy {
        try validateASCIIIdentifier(policy.id, maximum: SnapshotFormat.policyIDSize - 1, at: "\(path).id")
        try validateASCIIIdentifier(
            policy.graphicsProvider,
            maximum: SnapshotFormat.graphicsProviderSize - 1,
            at: "\(path).graphicsProvider"
        )
        try validateProviderPath(policy.providerDirectory, at: "\(path).providerDirectory")
        guard !policy.dllRoutes.isEmpty, policy.dllRoutes.count <= SnapshotFormat.maximumRoutes else {
            throw PolicySnapshotError.invalid(
                "\(path).dllRoutes must contain 1...\(SnapshotFormat.maximumRoutes) entries"
            )
        }

        var routes = try policy.dllRoutes.enumerated().map { index, route in
            NormalizedDLLRoute(
                module: try normalizeModule(route.module, at: "\(path).dllRoutes[\(index)].module"),
                loadOrder: route.loadOrder
            )
        }
        routes.sort { $0.module < $1.module }
        for index in routes.indices.dropFirst() {
            guard routes[index - 1].module != routes[index].module else {
                throw PolicySnapshotError.invalid("\(path) contains duplicate DLL route \(routes[index].module)")
            }
        }
        return NormalizedPolicy(
            id: policy.id,
            graphicsProvider: policy.graphicsProvider,
            providerDirectory: policy.providerDirectory,
            dllRoutes: routes
        )
    }

    private static func normalizeDigest(_ value: String) throws -> String {
        let digest = value.lowercased()
        guard digest.utf8.count == SnapshotFormat.digestSize,
              digest.allSatisfy({ $0.isHexDigit }),
              digest.contains(where: { $0 != "0" }) else {
            throw PolicySnapshotError.invalid("imageSHA256 must be a nonzero 64-digit hexadecimal digest")
        }
        return digest
    }

    private static func normalizeModule(_ value: String, at path: String) throws -> String {
        var module = value.lowercased()
        if module.hasSuffix(".dll") {
            module.removeLast(4)
        }
        try validateASCIIIdentifier(module, maximum: SnapshotFormat.moduleSize - 1, at: path)
        guard !module.contains(where: { "/\\:;".contains($0) }) else {
            throw PolicySnapshotError.invalid("\(path) must be a DLL basename")
        }
        return module
    }

    private static func validateProviderPath(_ value: String, at path: String) throws {
        guard value.utf8.count >= 3,
              value.utf8.count < SnapshotFormat.providerPathSize,
              value.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
              value.first?.isLetter == true,
              value.dropFirst().first == ":",
              value.dropFirst(2).first.map({ $0 == "\\" || $0 == "/" }) == true,
              !value.contains(";") else {
            throw PolicySnapshotError.invalid(
                "\(path) must be an absolute ASCII Windows path without semicolons"
            )
        }
    }

    private static func validateASCIIIdentifier(
        _ value: String,
        maximum: Int,
        at path: String
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximum,
              value.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39) ||
                      (byte >= 0x41 && byte <= 0x5a) ||
                      (byte >= 0x61 && byte <= 0x7a) ||
                      byte == 0x2d ||
                      byte == 0x2e ||
                      byte == 0x5f
              }) else {
            throw PolicySnapshotError.invalid("\(path) must be a bounded ASCII identifier")
        }
    }
}
