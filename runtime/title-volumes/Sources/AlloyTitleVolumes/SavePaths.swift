// Author: Timur Isaev

import Foundation

public struct SavePathBinding: Codable, Equatable, Sendable {
    public let guestPath: String
    public let relativePath: String
    public init(guestPath: String, relativePath: String) {
        self.guestPath = guestPath
        self.relativePath = relativePath
    }
}

public struct SavePathDeclaration: Codable, Equatable, Sendable {
    public let profileID: String
    public let revision: Int
    public let bindings: [SavePathBinding]
    public init(profileID: String, revision: Int, bindings: [SavePathBinding]) {
        self.profileID = profileID
        self.revision = revision
        self.bindings = bindings
    }
}

public struct DiscoveredSave: Codable, Equatable, Sendable {
    public let relativePath: String
    public let inventory: TreeInventory
}

extension TitleVolumeStore {
    /// The caller authenticates the declaring profile. Bindings are broker instructions, never host paths.
    public func declareSavePaths(gameID: String, declaration: SavePathDeclaration) throws {
        try identifier(declaration.profileID)
        guard declaration.revision > 0, !declaration.bindings.isEmpty, declaration.bindings.count <= 128 else {
            throw VolumeError.invalidPolicy
        }
        var guests = Set<String>()
        var targets = Set<String>()
        for binding in declaration.bindings {
            _ = try relativeComponents(binding.relativePath)
            let guest = binding.guestPath.replacingOccurrences(of: "\\", with: "/")
            guard guest.count > 3, ["C:/", "G:/", "S:/"].contains(String(guest.prefix(3))),
                  guests.insert(guest.lowercased()).inserted,
                  targets.insert(binding.relativePath.lowercased()).inserted else { throw VolumeError.unsafePath }
            _ = try relativeComponents(String(guest.dropFirst(3)))
        }
        for paths in [guests, targets] {
            for path in paths {
                guard !paths.contains(where: { $0 != path && $0.hasPrefix(path + "/") }) else {
                    throw VolumeError.unsafePath
                }
            }
        }
        try locked {
            _ = try titleRecord(gameID, in: loadRegistry())
            let directory = try metadata.child("save-paths", create: true)
            try directory.write(gameID + ".json", data: checked(declaration))
        }
    }

    public func savePaths(gameID: String) throws -> SavePathDeclaration? {
        try locked {
            _ = try titleRecord(gameID, in: loadRegistry())
            guard try metadata.information("save-paths") != nil else { return nil }
            let directory = try metadata.child("save-paths")
            guard try directory.information(gameID + ".json") != nil else { return nil }
            return try decodeChecked(SavePathDeclaration.self, directory.read(gameID + ".json"))
        }
    }

    /// Later monitored-first-run code supplies candidates; this interface never scans outside the title's save root.
    public func discoverSaves(gameID: String, candidates: [String]) throws -> [DiscoveredSave] {
        guard candidates.count <= 128 else { throw VolumeError.invalidPolicy }
        for candidate in candidates { _ = try relativeComponents(candidate) }
        return try locked {
            let volume = try resolve(gameID, .saves, nil, in: loadRegistry())
            let inventory = try directory(volume).inventory(limit: volume.quota)
            return candidates.compactMap { path in
                let matches = inventory.entries.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
                return matches.isEmpty ? nil : DiscoveredSave(
                    relativePath: path, inventory: TreeInventory(entries: matches))
            }
        }
    }
}
