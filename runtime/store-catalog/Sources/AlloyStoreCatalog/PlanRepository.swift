// Author: Timur Isaev
import Darwin
import Foundation

struct PlanRepository {
    let root: URL

    func save<T: Encodable>(_ plan: T, identifier: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try StoreCatalog.encode(plan)
        let target = try path(identifier)
        if FileManager.default.fileExists(atPath: target.path) {
            guard try Data(contentsOf: target) == bytes else { throw InstallationError.corruptPlan(identifier) }
            return
        }
        try bytes.write(to: target, options: .atomic)
        for url in [target, root] {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw OperationError.fileSystem("open plan for sync", errno) }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw OperationError.fileSystem("sync plan", errno) }
        }
    }

    func read<T: Decodable>(_ type: T.Type, identifier: String) throws -> T {
        let target = try path(identifier)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw InstallationError.unknownPlan(identifier)
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: target))
    }

    private func path(_ identifier: String) throws -> URL {
        guard identifier.hasPrefix("plan-"), identifier.count == 69,
              identifier.dropFirst(5).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw InstallationError.unknownPlan(identifier)
        }
        return root.appendingPathComponent(identifier + ".json")
    }
}
