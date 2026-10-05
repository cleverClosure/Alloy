// Author: Timur Isaev

import Foundation

enum V2Validation {
    static func source(_ data: Data) throws -> V2Source {
        guard data.count <= V2Format.maxBytes * 2,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolicySnapshotV2Error.source
        }
        try keys(object, required: ["schemaVersion", "defaultPolicy", "processPolicies"])
        guard let fallback = object["defaultPolicy"] as? [String: Any],
              let processes = object["processPolicies"] as? [[String: Any]] else {
            throw PolicySnapshotV2Error.source
        }
        try policyKeys(fallback)
        for process in processes {
            try keys(process, required: ["imageSHA256", "policy"])
            guard let policy = process["policy"] as? [String: Any] else { throw PolicySnapshotV2Error.source }
            try policyKeys(policy)
        }
        var result: V2Source
        do { result = try JSONDecoder().decode(V2Source.self, from: data) } catch { throw PolicySnapshotV2Error.source }
        guard result.schemaVersion == 2, result.processPolicies.count < V2Format.maxEntries else {
            throw PolicySnapshotV2Error.source
        }
        result.defaultPolicy = try policy(result.defaultPolicy)
        for index in result.processPolicies.indices {
            let digest = result.processPolicies[index].imageSHA256.lowercased()
            guard digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  digest != String(repeating: "0", count: 64) else { throw PolicySnapshotV2Error.invalidField }
            result.processPolicies[index].imageSHA256 = digest
            result.processPolicies[index].policy = try policy(result.processPolicies[index].policy)
        }
        result.processPolicies.sort { $0.imageSHA256 < $1.imageSHA256 }
        guard Set(result.processPolicies.map(\.imageSHA256)).count == result.processPolicies.count else {
            throw PolicySnapshotV2Error.noncanonical
        }
        return result
    }

    static func policy(_ input: V2Policy) throws -> V2Policy {
        var value = input
        try identifier(value.id, limit: 64)
        guard (value.graphicsProvider == nil) == (value.providerDirectory == nil) else {
            throw PolicySnapshotV2Error.invalidField
        }
        if let graphics = value.graphicsProvider { try identifier(graphics, limit: 64) }
        if let directory = value.providerDirectory { try path(directory) }
        if let directory = value.workingDirectory { try path(directory) }
        value.environment = try environment(value.environment)
        value.dllRoutes = try routes(value.dllRoutes)
        return value
    }

    private static func environment(_ values: [String: String]?) throws -> [String: String]? {
        guard let values else { return nil }
        guard values.count <= V2Format.maxEnvironment else { throw PolicySnapshotV2Error.invalidField }
        var result: [String: String] = [:]
        for (key, text) in values {
            try environmentKey(key)
            try ascii(text, limit: 256)
            guard result.updateValue(text, forKey: key.uppercased()) == nil else {
                throw PolicySnapshotV2Error.noncanonical
            }
        }
        return result
    }

    private static func routes(_ values: [V2Route]?) throws -> [V2Route]? {
        guard var routes = values else { return nil }
        guard routes.count <= V2Format.maxRoutes else { throw PolicySnapshotV2Error.invalidField }
        for index in routes.indices {
            var name = routes[index].module.lowercased()
            if name.hasSuffix(".dll") { name.removeLast(4) }
            try identifier(name, limit: 32)
            guard !["ntdll", "kernel32", "kernelbase", "libarm64ecfex"].contains(name),
                  !name.hasSuffix(".dll"), !name.hasSuffix(".") else {
                throw PolicySnapshotV2Error.invalidField
            }
            routes[index].module = name
        }
        routes.sort { $0.module < $1.module }
        guard Set(routes.map(\.module)).count == routes.count else { throw PolicySnapshotV2Error.noncanonical }
        return routes
    }

    static func ascii(_ value: String, limit: Int) throws {
        guard value.utf8.count < limit, value.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw PolicySnapshotV2Error.invalidField
        }
    }

    static func identifier(_ value: String, limit: Int) throws {
        try ascii(value, limit: limit)
        guard !value.isEmpty, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }) else { throw PolicySnapshotV2Error.invalidField }
    }

    static func path(_ value: String) throws {
        try ascii(value, limit: 512)
        let bytes = Array(value.utf8)
        guard bytes.count >= 3, (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]),
              bytes[1] == 58, bytes[2] == 92 || bytes[2] == 47,
              !value.contains(where: { ";*?\"<>|".contains($0) }),
              !value.dropFirst(2).contains(":"),
              !value.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains(where: {
                  $0 == "." || $0 == ".." || $0.hasSuffix(".") || $0.hasSuffix(" ")
              }) else { throw PolicySnapshotV2Error.invalidField }
    }

    static func environmentKey(_ key: String) throws {
        try identifier(key, limit: 64)
        let upper = key.uppercased()
        guard !upper.hasPrefix("ALLOY_"), !upper.hasPrefix("WINE"), !upper.hasPrefix("DYLD_"),
              !upper.hasPrefix("LD_"), !upper.hasPrefix("FEX"),
              !["PATH", "HOME", "TMPDIR", "SYSTEMROOT", "SYSTEMDRIVE", "COMSPEC"].contains(upper),
              upper.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw PolicySnapshotV2Error.invalidField
        }
    }

    private static func policyKeys(_ object: [String: Any]) throws {
        try keys(object, required: ["id"], optional: ["graphicsProvider", "providerDirectory", "cpuProvider",
                                                  "environment", "workingDirectory", "dllRoutes"])
        if let routes = object["dllRoutes"] {
            guard let entries = routes as? [[String: Any]] else { throw PolicySnapshotV2Error.source }
            for entry in entries { try keys(entry, required: ["module", "loadOrder"]) }
        }
    }

    private static func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)),
              !object.values.contains(where: { $0 is NSNull }) else { throw PolicySnapshotV2Error.source }
    }
}
