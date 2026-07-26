// Author: Timur Isaev

import Darwin
import Foundation

extension ContentStore {
    public static let garbageCollectionFaultPoints = [
        "after-gc-mark",
        "after-gc-generation-sweep-item",
        "after-gc-generation-sweep",
        "after-gc-object-sweep-item",
        "after-gc-object-sweep",
        "after-gc-download-sweep-item",
        "after-gc-download-sweep",
        "after-gc-quarantine-sweep-item",
        "after-gc-quarantine-sweep"
    ]

    /// Recomputes reachability under the process-wide store lock and removes
    /// only state that is unreachable after journal recovery.
    @discardableResult
    public func collectGarbage(
        faultInjector: FaultInjector? = nil
    ) throws -> GarbageCollectionResult {
        try withExclusiveLock {
            // An interrupted activation may have published objects before its
            // candidate reference exists. Complete recovery before computing
            // the exact reference-and-lease root set.
            try recoverAllUnlocked()
            let mark = try markReachableStateUnlocked()
            let protectedDownloads = try protectedTransportOperationIDsUnlocked()
            try faultInjector?("after-gc-mark")

            let removedGenerations = try sweepGenerationsUnlocked(
                preserving: mark.generations,
                faultInjector: faultInjector
            )
            let removedObjects = try sweepObjectsUnlocked(
                preserving: mark.objectDigests,
                faultInjector: faultInjector
            )
            let removedDownloads = try sweepDirectoryEntriesUnlocked(
                downloadsDirectory,
                itemFaultPoint: "after-gc-download-sweep-item",
                completionFaultPoint: "after-gc-download-sweep",
                preserving: protectedDownloads,
                faultInjector: faultInjector
            )
            let removedQuarantine = try sweepDirectoryEntriesUnlocked(
                quarantineDirectory,
                itemFaultPoint: "after-gc-quarantine-sweep-item",
                completionFaultPoint: "after-gc-quarantine-sweep",
                faultInjector: faultInjector
            )

            return GarbageCollectionResult(
                generationsRemoved: removedGenerations.count,
                objectsRemoved: removedObjects.count,
                downloadsRemoved: removedDownloads.count,
                quarantineEntriesRemoved: removedQuarantine.count,
                bytesReclaimed: removedGenerations.bytes
                    + removedObjects.bytes
                    + removedDownloads.bytes
                    + removedQuarantine.bytes
            )
        }
    }

    func markReachableStateUnlocked() throws -> GarbageCollectionMark {
        var generations = Set<RootedGeneration>()
        var objectDigests = Set<String>()

        for gameDirectory in try directoryEntries(referencesDirectory) {
            guard isDirectory(gameDirectory) else {
                throw ContentStoreError.unsafeStoreEntry(gameDirectory.path)
            }
            let gameID = gameDirectory.lastPathComponent
            try validateIdentifier(gameID)
            for kind in ReferenceKind.allCases {
                guard let reference = try readReference(kind, gameID: gameID) else {
                    continue
                }
                try addRoot(
                    gameID: gameID,
                    reference: reference,
                    generations: &generations,
                    objectDigests: &objectDigests
                )
            }
        }

        for lease in try liveLeaseRecordsPruningStaleUnlocked() {
            let reference = GenerationReference(
                generationID: lease.generationID,
                manifestDigest: lease.manifestDigest
            )
            try validateReference(reference, gameID: lease.gameID)
            let manifest = try readGenerationManifest(reference, gameID: lease.gameID)
            let expectedDigests = Array(Set(manifest.layers.map(\.digest))).sorted()
            guard lease.objectDigests == expectedDigests else {
                throw ContentStoreError.invalidLease(lease.leaseID)
            }
            generations.insert(RootedGeneration(
                gameID: lease.gameID,
                generationID: lease.generationID
            ))
            objectDigests.formUnion(expectedDigests)
        }
        return GarbageCollectionMark(
            generations: generations,
            objectDigests: objectDigests
        )
    }

    func addRoot(
        gameID: String,
        reference: GenerationReference,
        generations: inout Set<RootedGeneration>,
        objectDigests: inout Set<String>
    ) throws {
        let manifest = try readGenerationManifest(reference, gameID: gameID)
        generations.insert(RootedGeneration(
            gameID: gameID,
            generationID: reference.generationID
        ))
        objectDigests.formUnion(manifest.layers.map(\.digest))
    }

    func sweepGenerationsUnlocked(
        preserving roots: Set<RootedGeneration>,
        faultInjector: FaultInjector?
    ) throws -> (count: Int, bytes: UInt64) {
        var removed = 0
        var bytes: UInt64 = 0
        for gameDirectory in try directoryEntries(generationsDirectory) {
            guard isDirectory(gameDirectory) else {
                throw ContentStoreError.unsafeStoreEntry(gameDirectory.path)
            }
            let gameID = gameDirectory.lastPathComponent
            try validateIdentifier(gameID)
            for generationDirectory in try directoryEntries(gameDirectory) {
                guard isDirectory(generationDirectory) else {
                    throw ContentStoreError.unsafeStoreEntry(generationDirectory.path)
                }
                let root = RootedGeneration(
                    gameID: gameID,
                    generationID: generationDirectory.lastPathComponent
                )
                if !roots.contains(root) {
                    bytes += try recursiveReclaimableRegularFileBytes(generationDirectory)
                    try removeSealedStagingDirectory(generationDirectory)
                    removed += 1
                    try faultInjector?("after-gc-generation-sweep-item")
                }
            }
            if try directoryEntries(gameDirectory).isEmpty {
                try fileManager.removeItem(at: gameDirectory)
                try syncDirectory(generationsDirectory)
            }
        }
        try faultInjector?("after-gc-generation-sweep")
        return (removed, bytes)
    }

    func sweepObjectsUnlocked(
        preserving objectDigests: Set<String>,
        faultInjector: FaultInjector?
    ) throws -> (count: Int, bytes: UInt64) {
        var removed = 0
        var bytes: UInt64 = 0
        for object in try validatedObjectURLsUnlocked() {
            let digest = "sha256:\(object.deletingLastPathComponent().lastPathComponent)\(object.lastPathComponent)"
            _ = try rawSHA256(digest)
            guard !objectDigests.contains(digest) else {
                continue
            }
            bytes += try regularFileBytes(object)
            try fileManager.removeItem(at: object)
            try syncDirectory(object.deletingLastPathComponent())
            removed += 1
            try faultInjector?("after-gc-object-sweep-item")
        }
        try removeEmptyObjectPrefixDirectories()
        try faultInjector?("after-gc-object-sweep")
        return (removed, bytes)
    }

    func removeEmptyObjectPrefixDirectories() throws {
        for directory in try directoryEntries(objectsDirectory) where isDirectory(directory) {
            if try directoryEntries(directory).isEmpty {
                try fileManager.removeItem(at: directory)
            }
        }
        try syncDirectory(objectsDirectory)
    }

    func validatedObjectURLsUnlocked() throws -> [URL] {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        var objects: [URL] = []
        for shard in try directoryEntries(objectsDirectory) {
            let shardName = shard.lastPathComponent
            guard isDirectory(shard),
                  shardName.count == 2,
                  shardName.unicodeScalars.allSatisfy({ lowercaseHex.contains($0) }) else {
                throw ContentStoreError.unsafeStoreEntry(shard.path)
            }
            for object in try directoryEntries(shard) {
                let suffix = object.lastPathComponent
                guard isRegularFile(object),
                      suffix.count == 62,
                      suffix.unicodeScalars.allSatisfy({ lowercaseHex.contains($0) }) else {
                    throw ContentStoreError.unsafeStoreEntry(object.path)
                }
                objects.append(object)
            }
        }
        return objects.sorted { $0.path < $1.path }
    }

    func sweepDirectoryEntriesUnlocked(
        _ directory: URL,
        itemFaultPoint: String,
        completionFaultPoint: String,
        preserving entryNames: Set<String> = [],
        faultInjector: FaultInjector?
    ) throws -> (count: Int, bytes: UInt64) {
        var removed = 0
        var bytes: UInt64 = 0
        for entry in try directoryEntries(directory)
        where !entryNames.contains(entry.lastPathComponent) {
            bytes += try recursiveRegularFileBytes(entry)
            try fileManager.removeItem(at: entry)
            try syncDirectory(directory)
            removed += 1
            try faultInjector?(itemFaultPoint)
        }
        try faultInjector?(completionFaultPoint)
        return (removed, bytes)
    }

    func directoryEntries(_ directory: URL) throws -> [URL] {
        try createDirectory(directory)
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func regularFileBytes(_ url: URL) throws -> UInt64 {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw ContentStoreError.systemCall(operation: "stat \(url.lastPathComponent)", code: errno)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            return 0
        }
        return UInt64(max(0, information.st_size))
    }

    func recursiveRegularFileBytes(_ root: URL) throws -> UInt64 {
        if isRegularFile(root) {
            return try regularFileBytes(root)
        }
        guard isDirectory(root) else {
            return 0
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return 0
        }
        var bytes: UInt64 = 0
        while let url = enumerator.nextObject() as? URL {
            if isRegularFile(url) {
                bytes += try regularFileBytes(url)
            } else if !isDirectory(url) {
                enumerator.skipDescendants()
            }
        }
        return bytes
    }

    func recursiveReclaimableRegularFileBytes(_ root: URL) throws -> UInt64 {
        if isRegularFile(root) {
            return try reclaimableRegularFileBytes(root)
        }
        guard isDirectory(root) else {
            throw ContentStoreError.unsafeStoreEntry(root.path)
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return 0
        }
        var bytes: UInt64 = 0
        while let url = enumerator.nextObject() as? URL {
            if isRegularFile(url) {
                bytes += try reclaimableRegularFileBytes(url)
            } else if !isDirectory(url) {
                throw ContentStoreError.unsafeStoreEntry(url.path)
            }
        }
        return bytes
    }

    func reclaimableRegularFileBytes(_ url: URL) throws -> UInt64 {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw ContentStoreError.systemCall(
                operation: "stat \(url.lastPathComponent)",
                code: errno
            )
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            return 0
        }
        return information.st_nlink == 1
            ? UInt64(max(0, information.st_size))
            : 0
    }
}
