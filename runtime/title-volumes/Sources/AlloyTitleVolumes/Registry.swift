// Author: Timur Isaev

import Darwin
import Foundation

extension TitleVolumeStore {
    func locked<T>(_ body: () throws -> T) throws -> T {
        let handle = try lockFile(metadata, "registry.lock")
        defer { flock(handle, LOCK_UN); close(handle) }
        guard flock(handle, LOCK_EX) == 0 else { throw VolumeError.systemCall("registry lock", errno) }
        return try body()
    }

    func lockFile(_ directory: Directory, _ name: String) throws -> Int32 {
        let handle = openat(directory.descriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        var info = stat()
        guard handle >= 0, fstat(handle, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_dev == directory.device else {
            if handle >= 0 { close(handle) }
            throw VolumeError.unsafeFile
        }
        return handle
    }

    func titleRecord(_ gameID: String, in registry: Registry) throws -> TitleRecord {
        try identifier(gameID)
        guard let title = registry.titles.first(where: { $0.gameID == gameID }) else {
            throw VolumeError.unknownTitle
        }
        return title
    }

    func resolve(_ gameID: String, _ kind: VolumeKind, _ generation: String?,
                 in registry: Registry) throws -> VolumeRecord {
        let title = try titleRecord(gameID, in: registry)
        guard let record = title.volumes.first(where: { $0.kind == kind && $0.generation == generation }) else {
            throw VolumeError.unknownVolume
        }
        return record
    }

    func loadRegistry() throws -> Registry {
        let registry: Registry
        do { registry = try decodeChecked(Registry.self, metadata.read("registry.json")) } catch {
            throw VolumeError.corruptRegistry
        }
        guard registry.schemaVersion == 1, Set(registry.titles.map(\.gameID)).count == registry.titles.count else {
            throw VolumeError.corruptRegistry
        }
        for title in registry.titles {
            try identifier(title.gameID)
            try title.quotas.validate()
            guard title.volumes.filter({ $0.kind == .saves }).count == 1,
                  title.volumes.filter({ $0.kind == .settings }).count == 1,
                  Set(title.volumes.map(\.id)).count == title.volumes.count else { throw VolumeError.corruptRegistry }
            for volume in title.volumes {
                let path: String
                let quota: Int64
                switch volume.kind {
                case .saves, .settings:
                    guard volume.generation == nil, volume.expiresAt == nil else { throw VolumeError.corruptRegistry }
                    path = volume.kind.rawValue
                    quota = volume.kind == .saves ? title.quotas.saves : title.quotas.settings
                case .cache, .scratch:
                    guard let generation = volume.generation else { throw VolumeError.corruptRegistry }
                    try identifier(generation)
                    path = "\(volume.kind == .cache ? "caches" : "sessions")/\(generation)"
                    quota = volume.kind == .cache ? title.quotas.cache : title.quotas.scratch
                }
                let expected = record(title.gameID, volume.kind, path: path, generation: volume.generation,
                                      quota: quota, policy: volume.backupPolicy, expiresAt: volume.expiresAt)
                guard expected == volume else { throw VolumeError.corruptRegistry }
            }
        }
        return registry
    }

    func saveRegistry(_ registry: inout Registry) throws {
        guard registry.revision < UInt64.max else { throw VolumeError.corruptRegistry }
        registry.revision += 1
        let data = try checked(registry)
        guard data.count <= 8 << 20 else { throw VolumeError.quotaExceeded }
        try metadata.write("registry.json", data: data)
    }
}
