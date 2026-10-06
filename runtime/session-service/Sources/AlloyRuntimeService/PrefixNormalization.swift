// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import Foundation

/// Fresh synthetic template metadata only; never applied to a user's existing prefix.
enum PrefixNormalization {
    static func apply(_ prefix: URL, seed: String) throws {
        for name in ["system.reg", "user.reg", "userdef.reg"] {
            let url = prefix.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let bytes = try Data(contentsOf: url)
            guard bytes.count < 32 << 20, var value = String(data: bytes, encoding: .utf8),
                  value.hasPrefix("WINE REGISTRY Version 2\n"),
                  !value.contains("\"PendingFileRenameOperations\"") else {
                throw RuntimeFailure.status(.conflict)
            }
            value = value.replacingOccurrences(of: "(?m)^#time=[a-fA-F0-9]+$", with: "#time=0",
                                                options: .regularExpression)
            value = value.replacingOccurrences(of: "(?m)^(\\[.*\\]) [0-9]+$", with: "$1 0",
                                                options: .regularExpression)
            for key in ["MachineGuid", "MachineId", "VideoID"] {
                value = try normalizeIdentity(value, key: key, seed: seed)
            }
            try Data(value.utf8).write(to: url)
        }
    }

    private static func normalizeIdentity(_ value: String, key: String, seed: String) throws -> String {
        let expression = try NSRegularExpression(pattern: "\"" + key + "\"=\"\\{?([0-9a-fA-F-]{36})\\}?\"")
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let found = Range(match.range(at: 1), in: value) else { return value }
        let hex = Array(ContentStore.digest(Data((seed + ":" + key).utf8)).dropFirst(7).prefix(32))
        let guid = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]),
                    String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
        return value.replacingOccurrences(of: String(value[found]), with: guid, options: .caseInsensitive)
    }
}
