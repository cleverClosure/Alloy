// Author: Timur Isaev

import Darwin
import Foundation

public final class TitleVolumeStore: @unchecked Sendable {
    let root: Directory
    let metadata: Directory
    let volumes: Directory

    public init(root url: URL) throws {
        root = try Directory.root(url)
        let sharedMetadata = try root.child("metadata", create: true, privateMode: false)
        let fresh = try sharedMetadata.information("title-volumes") == nil
        metadata = try sharedMetadata.child("title-volumes", create: true)
        volumes = try root.child("volumes", create: true, privateMode: false)
        try locked {
            if fresh, try metadata.information("registry.json") == nil {
                try metadata.write("registry.json", data: checked(Registry()), exclusive: true)
            }
            _ = try loadRegistry()
            _ = try metadata.child("leases", create: true)
        }
    }

    public func createTitle(gameID: String, quotas: VolumeQuotas = VolumeQuotas(),
                            backupPolicy: BackupPolicy = BackupPolicy()) throws -> [VolumeRecord] {
        try identifier(gameID)
        try quotas.validate()
        if let interval = backupPolicy.periodicIntervalSeconds, interval < 60 {
            throw VolumeError.invalidPolicy
        }
        return try locked {
            var registry = try loadRegistry()
            if let existing = registry.titles.first(where: { $0.gameID == gameID }) {
                guard existing.quotas == quotas,
                      existing.volumes.first(where: { $0.kind == .saves })?.backupPolicy == backupPolicy else {
                    throw VolumeError.conflict
                }
                return existing.volumes
            }
            let title = try volumes.child(gameID, create: true)
            for name in ["saves", "settings", "caches", "sessions", "payload"] {
                _ = try title.child(name, create: true)
            }
            let records = [
                record(gameID, .saves, path: "saves", quota: quotas.saves, policy: backupPolicy),
                record(gameID, .settings, path: "settings", quota: quotas.settings)
            ]
            registry.titles.append(TitleRecord(gameID: gameID, quotas: quotas, volumes: records))
            try saveRegistry(&registry)
            return records
        }
    }

    public func records(gameID: String) throws -> [VolumeRecord] {
        try locked { try titleRecord(gameID, in: loadRegistry()).volumes }
    }

    public func createCache(gameID: String, epoch: String) throws -> VolumeRecord {
        try identifier(epoch)
        return try createScoped(gameID: gameID, kind: .cache, generation: epoch, expiresAt: nil)
    }

    public func createScratch(gameID: String, sessionID: String, now: Int64,
                              lifetimeSeconds: Int64 = 86400) throws -> VolumeRecord {
        try identifier(sessionID)
        guard now >= 0, lifetimeSeconds > 0, lifetimeSeconds <= 30 * 86400,
              now <= Int64.max - lifetimeSeconds else { throw VolumeError.invalidPolicy }
        return try createScoped(gameID: gameID, kind: .scratch, generation: sessionID,
                                expiresAt: now + lifetimeSeconds)
    }

    public func inventory(gameID: String, kind: VolumeKind, generation: String? = nil) throws -> TreeInventory {
        try locked {
            let record = try resolve(gameID, kind, generation, in: loadRegistry())
            return try directory(record).inventory(limit: record.quota)
        }
    }

    public func write(gameID: String, kind: VolumeKind, generation: String? = nil,
                      path: String, data: Data) throws {
        guard kind != .settings else { throw VolumeError.invalidPolicy }
        let components = try relativeComponents(path)
        try locked {
            let record = try resolve(gameID, kind, generation, in: loadRegistry())
            let target = try directory(record)
            let tree = try target.inventory(limit: record.quota)
            let previous = tree.entries.first(where: { $0.path == path })?.size ?? 0
            guard Int64(data.count) <= record.quota - (tree.bytes - previous) else {
                throw VolumeError.quotaExceeded
            }
            var parent = target
            for part in components.dropLast() { parent = try parent.child(part, create: true) }
            try parent.write(components[components.count - 1], data: data)
        }
    }

    public func read(gameID: String, kind: VolumeKind, generation: String? = nil,
                     path: String, limit: Int = 64 << 20) throws -> Data {
        let components = try relativeComponents(path)
        guard limit > 0, limit <= 64 << 20 else { throw VolumeError.invalidPolicy }
        return try locked {
            let record = try resolve(gameID, kind, generation, in: loadRegistry())
            var parent = try directory(record)
            for part in components.dropLast() { parent = try parent.child(part) }
            return try parent.read(components[components.count - 1], limit: limit)
        }
    }

    /// A live session holds this lease; expiry alone cannot remove its scratch.
    public func withSessionLease<T>(gameID: String, sessionID: String,
                                    _ body: (VolumeRecord) throws -> T) throws -> T {
        let lease: SessionLease = try locked {
            let record = try resolve(gameID, .scratch, sessionID, in: loadRegistry())
            let handle = try lockFile(try metadata.child("leases"), record.id)
            guard flock(handle, LOCK_SH) == 0 else {
                close(handle)
                throw VolumeError.systemCall("session lease", errno)
            }
            let writer: Int32
            do {
                writer = try lockFile(try metadata.child("leases"), "writers-" + gameID)
                guard flock(writer, LOCK_SH) == 0 else {
                    close(writer)
                    throw VolumeError.systemCall("writer lease", errno)
                }
            } catch {
                flock(handle, LOCK_UN)
                close(handle)
                throw error
            }
            return SessionLease(record: record, scratch: handle, writer: writer)
        }
        defer {
            flock(lease.scratch, LOCK_UN)
            close(lease.scratch)
            flock(lease.writer, LOCK_UN)
            close(lease.writer)
        }
        return try body(lease.record)
    }

    func createScoped(gameID: String, kind: VolumeKind, generation: String,
                      expiresAt: Int64?) throws -> VolumeRecord {
        try locked {
            var registry = try loadRegistry()
            let title = try titleRecord(gameID, in: registry)
            if let existing = title.volumes.first(where: { $0.kind == kind && $0.generation == generation }) {
                return existing
            }
            let prefix = kind == .cache ? "caches" : "sessions"
            _ = try volumes.child(gameID).child(prefix).child(generation, create: true)
            let volume = record(gameID, kind, path: "\(prefix)/\(generation)",
                                generation: generation,
                                quota: kind == .cache ? title.quotas.cache : title.quotas.scratch,
                                expiresAt: expiresAt)
            for index in registry.titles.indices where registry.titles[index].gameID == gameID {
                registry.titles[index].volumes.append(volume)
            }
            try saveRegistry(&registry)
            return volume
        }
    }

    func directory(_ record: VolumeRecord) throws -> Directory {
        let relative = record.relativePath.split(separator: "/").dropFirst(2).joined(separator: "/")
        return try volumes.child(record.gameID).directory(relative)
    }

    func record(_ gameID: String, _ kind: VolumeKind, path: String, generation: String? = nil,
                quota: Int64, policy: BackupPolicy = BackupPolicy(), expiresAt: Int64? = nil) -> VolumeRecord {
        let identity = digest(Data("\(gameID)/\(kind.rawValue)/\(generation ?? "persistent")".utf8))
        return VolumeRecord(id: "vol-" + identity, gameID: gameID, kind: kind,
                            relativePath: "volumes/\(gameID)/\(path)", generation: generation,
                            quota: quota, backupPolicy: policy, expiresAt: expiresAt)
    }
}
