// Author: Timur Isaev

import Darwin
import Foundation

public struct CacheIdentity: Codable, Equatable, Sendable {
    public let runtimeIdentity: String
    public let providers: [String: String]
    public let compatibilityInputs: [String: String]

    public init(runtimeIdentity: String, providers: [String: String], compatibilityInputs: [String: String]) {
        self.runtimeIdentity = runtimeIdentity
        self.providers = providers
        self.compatibilityInputs = compatibilityInputs
    }

    public var epoch: String { get throws { "epoch-" + digest(try encoded(self)) } }

    func validate() throws {
        guard !runtimeIdentity.isEmpty, runtimeIdentity.utf8.count <= 256,
              !providers.isEmpty, providers.count <= 64, !compatibilityInputs.isEmpty,
              compatibilityInputs.count <= 64 else { throw VolumeError.invalidPolicy }
        for pair in Array(providers) + Array(compatibilityInputs) {
            try identifier(pair.key)
            guard !pair.value.isEmpty, pair.value.utf8.count <= 1024 else { throw VolumeError.invalidPolicy }
        }
    }
}

public struct CacheSelection: Codable, Equatable, Sendable {
    public let gameID: String
    public let identity: CacheIdentity
    public let volume: VolumeRecord
}

struct DisposalJournal: Codable {
    let gameID: String
    let operation: String
    let retired: [VolumeRecord]
    let cache: CacheSelection?
}

extension TitleVolumeStore {
    public static let cacheFaultPoints = ["after-journal", "after-create", "after-switch",
                                         "after-retire", "after-registry", "after-commit"]
    public static let scratchFaultPoints = ["after-journal", "after-retire", "after-registry", "after-commit"]

    public func activateCache(gameID: String, identity: CacheIdentity,
                              faultInjector: VolumeFaultInjector? = nil) throws -> CacheSelection {
        try identity.validate()
        return try locked {
            try quiet(gameID) {
                let registry = try loadRegistry()
                let title = try titleRecord(gameID, in: registry)
                if let current = try activeCacheUnlocked(gameID), current.identity == identity {
                    _ = try directory(current.volume).inventory(limit: current.volume.quota)
                    return current
                }
                let epoch = try identity.epoch
                let volume = record(gameID, .cache, path: "caches/" + epoch,
                                    generation: epoch, quota: title.quotas.cache)
                let selection = CacheSelection(gameID: gameID, identity: identity, volume: volume)
                let journal = DisposalJournal(gameID: gameID, operation: "cache",
                    retired: title.volumes.filter { $0.kind == .cache && $0.id != volume.id }, cache: selection)
                try metadata.write("disposal.json", data: checked(journal))
                try faultInjector?("cache.after-journal")
                try applyDisposal(journal, fault: faultInjector)
                return selection
            }
        }
    }

    public func activeCache(gameID: String) throws -> CacheSelection? {
        try locked { try activeCacheUnlocked(gameID) }
    }

    @discardableResult
    public func expireScratch(gameID: String, now: Int64,
                              faultInjector: VolumeFaultInjector? = nil) throws -> [String] {
        guard now >= 0 else { throw VolumeError.invalidPolicy }
        return try locked {
            let title = try titleRecord(gameID, in: loadRegistry())
            var handles: [Int32] = []
            defer { for handle in handles { flock(handle, LOCK_UN); close(handle) } }
            var retired: [VolumeRecord] = []
            for record in title.volumes where record.kind == .scratch && (record.expiresAt ?? Int64.max) <= now {
                let handle = try lockFile(try metadata.child("leases"), record.id)
                if flock(handle, LOCK_EX | LOCK_NB) != 0 {
                    let code = errno
                    close(handle)
                    guard code == EWOULDBLOCK else { throw VolumeError.systemCall("cleanup lease", code) }
                    continue
                }
                handles.append(handle)
                retired.append(record)
            }
            guard !retired.isEmpty else { return [] }
            let journal = DisposalJournal(gameID: gameID, operation: "scratch", retired: retired, cache: nil)
            try metadata.write("disposal.json", data: checked(journal))
            try faultInjector?("scratch.after-journal")
            try applyDisposal(journal, fault: faultInjector)
            return retired.map(\.id)
        }
    }

    func recoverDisposal() throws {
        guard try metadata.information("disposal.json") != nil else { return }
        let journal = try decodeChecked(DisposalJournal.self, metadata.read("disposal.json"))
        if journal.operation == "cache" {
            try quiet(journal.gameID) { try applyDisposal(journal, fault: nil) }
        } else {
            // No new session can acquire a lease until recovery under the registry lock completes.
            try applyDisposal(journal, fault: nil)
        }
    }

    func activeCacheUnlocked(_ gameID: String) throws -> CacheSelection? {
        let title = try titleRecord(gameID, in: loadRegistry())
        guard try metadata.information("cache-current") != nil else { return nil }
        let directory = try metadata.child("cache-current")
        guard try directory.information(gameID + ".json") != nil else { return nil }
        let selection = try decodeChecked(CacheSelection.self, directory.read(gameID + ".json"))
        try selection.identity.validate()
        guard selection.gameID == gameID, selection.volume.kind == .cache,
              try selection.identity.epoch == selection.volume.generation,
              title.volumes.contains(selection.volume) else { throw VolumeError.integrityMismatch }
        return selection
    }

    private func validateDisposal(_ journal: DisposalJournal, title: TitleRecord) throws {
        guard ["cache", "scratch"].contains(journal.operation),
              (journal.operation == "cache") == (journal.cache != nil),
              Set(journal.retired.map(\.id)).count == journal.retired.count else {
            throw VolumeError.integrityMismatch
        }
        for volume in journal.retired {
            let kind: VolumeKind = journal.operation == "cache" ? .cache : .scratch
            guard volume.kind == kind, let generation = volume.generation else { throw VolumeError.integrityMismatch }
            try identifier(generation)
            let prefix = kind == .cache ? "caches/" : "sessions/"
            let expected = record(title.gameID, kind, path: prefix + generation, generation: generation,
                                  quota: kind == .cache ? title.quotas.cache : title.quotas.scratch,
                                  expiresAt: volume.expiresAt)
            guard volume == expected else { throw VolumeError.integrityMismatch }
        }
        if let cache = journal.cache {
            try cache.identity.validate()
            let epoch = try cache.identity.epoch
            let expected = record(title.gameID, .cache, path: "caches/" + epoch,
                                  generation: epoch, quota: title.quotas.cache)
            guard cache.gameID == title.gameID, cache.volume == expected,
                  !journal.retired.contains(where: { $0.id == expected.id }) else {
                throw VolumeError.integrityMismatch
            }
        }
    }

    private func applyDisposal(_ journal: DisposalJournal, fault: VolumeFaultInjector?) throws {
        var registry = try loadRegistry()
        let title = try titleRecord(journal.gameID, in: registry)
        try validateDisposal(journal, title: title)
        if let cache = journal.cache {
            guard let epoch = cache.volume.generation else { throw VolumeError.integrityMismatch }
            _ = try volumes.child(journal.gameID).child("caches").child(epoch, create: true)
            for index in registry.titles.indices where registry.titles[index].gameID == journal.gameID {
                if !registry.titles[index].volumes.contains(where: { $0.id == cache.volume.id }) {
                    registry.titles[index].volumes.append(cache.volume)
                }
            }
            try saveRegistry(&registry)
            try fault?("cache.after-create")
            try metadata.child("cache-current", create: true).write(journal.gameID + ".json", data: checked(cache))
            try fault?("cache.after-switch")
        }
        let trash = try metadata.child("disposable-trash", create: true)
        for volume in journal.retired { try retire(volume, into: trash) }
        try fault?(journal.operation + ".after-retire")
        let removed = Set(journal.retired.map(\.id))
        for index in registry.titles.indices where registry.titles[index].gameID == journal.gameID {
            registry.titles[index].volumes.removeAll { removed.contains($0.id) }
        }
        try saveRegistry(&registry)
        try fault?(journal.operation + ".after-registry")
        for volume in journal.retired { try trash.remove(volume.id) }
        try metadata.remove("disposal.json")
        try fault?(journal.operation + ".after-commit")
    }

    private func retire(_ volume: VolumeRecord, into trash: Directory) throws {
        guard [.cache, .scratch].contains(volume.kind), let generation = volume.generation else {
            throw VolumeError.integrityMismatch
        }
        let parent = try volumes.child(volume.gameID).child(volume.kind == .cache ? "caches" : "sessions")
        if try parent.information(generation) != nil {
            _ = try parent.child(generation)
            let status = renameatx_np(parent.descriptor, generation, trash.descriptor, volume.id, UInt32(RENAME_EXCL))
            guard status == 0 else {
                throw VolumeError.systemCall("retire disposable", errno)
            }
            try parent.sync()
            try trash.sync()
        }
    }
}
