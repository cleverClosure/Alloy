// Author: Timur Isaev

import Darwin
import Foundation

extension TitleVolumeStore {
    /// Explicitly adopts content-store's older save-only layout; never follows links or changes save bytes.
    public func adoptLegacySaves(gameID: String, quotas: VolumeQuotas = VolumeQuotas(),
                                 backupPolicy: BackupPolicy = BackupPolicy()) throws -> [VolumeRecord] {
        try identifier(gameID)
        try quotas.validate()
        try locked {
            let registry = try loadRegistry()
            if registry.titles.contains(where: { $0.gameID == gameID }) { return }
            try quiet(gameID) {
                let title = try volumes.child(gameID, privateMode: false)
                guard try title.names() == ["saves"], noExtendedACL(title.descriptor) else {
                    throw VolumeError.unsafePath
                }
                let saves = try title.child("saves", privateMode: false)
                var budget = 10_000
                try saves.restrictLegacyTree(depth: 0, budget: &budget)
                guard fchmod(title.descriptor, 0o700) == 0 else { throw VolumeError.systemCall("adopt title", errno) }
                try title.sync()
                _ = try saves.inventory(limit: quotas.saves)
            }
        }
        return try createTitle(gameID: gameID, quotas: quotas, backupPolicy: backupPolicy)
    }
}

extension Directory {
    func restrictLegacyTree(depth: Int, budget: inout Int) throws {
        guard depth < 32, noExtendedACL(descriptor) else { throw VolumeError.unsafePath }
        for name in try names() {
            _ = try relativeComponents(name)
            budget -= 1
            guard budget >= 0, let info = try information(name) else { throw VolumeError.quotaExceeded }
            if info.st_mode & S_IFMT == S_IFDIR {
                try child(name, privateMode: false).restrictLegacyTree(depth: depth + 1, budget: &budget)
            } else {
                let handle = try file(name, privateMode: false)
                defer { close(handle) }
                guard fchmod(handle, 0o600) == 0, fsync(handle) == 0 else {
                    throw VolumeError.systemCall("adopt save permissions", errno)
                }
            }
        }
        guard fchmod(descriptor, 0o700) == 0 else { throw VolumeError.systemCall("adopt save directory", errno) }
        try sync()
    }
}
