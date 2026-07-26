// Author: Timur Isaev

import Foundation

extension ContentStore {
    /// Reports the additional CAS bytes needed for the supplied layer set.
    ///
    /// A valid object already in the CAS costs zero. Duplicate input digests
    /// are counted once.
    public func preflightDiskSpace(for layers: [LayerDescriptor]) throws -> DiskSpacePlan {
        guard !layers.isEmpty else {
            throw ContentStoreError.emptyLayerSet
        }
        for layer in layers {
            try validateLayerDescriptor(layer)
        }

        return try withExclusiveLock {
            try preflightDiskSpaceUnlocked(for: layers)
        }
    }

    /// Plans and refuses an operation before it starts when it will not fit.
    @discardableResult
    public func preflightDiskSpace(
        for layers: [LayerDescriptor],
        availableBytes: UInt64
    ) throws -> DiskSpacePlan {
        let plan = try preflightDiskSpace(for: layers)
        try plan.requireFits(availableBytes: availableBytes)
        return plan
    }

    /// Estimates the current sweep targets using every reference and live lease
    /// as roots. Stale lease records are pruned by the lease subsystem.
    public func estimateGarbageCollectionReclaim() throws -> ReclaimEstimate {
        try withExclusiveLock {
            try estimateGarbageCollectionReclaimUnlocked(
                additionalReachableDigests: []
            )
        }
    }

    /// Integration hook for collection roots that are not generation references.
    ///
    /// This overload takes the store lock so lease and GC implementations can
    /// share the same estimator without exposing the hook publicly.
    func estimateGarbageCollectionReclaim(
        additionalReachableDigests: Set<String>
    ) throws -> ReclaimEstimate {
        try withExclusiveLock {
            try estimateGarbageCollectionReclaimUnlocked(
                additionalReachableDigests: additionalReachableDigests
            )
        }
    }

    func preflightDiskSpaceUnlocked(for layers: [LayerDescriptor]) throws -> DiskSpacePlan {
        var uniqueLayers: [String: LayerDescriptor] = [:]
        for layer in layers {
            if let existingLayer = uniqueLayers[layer.digest] {
                guard existingLayer.size == layer.size else {
                    throw ContentStoreError.invalidLayer(
                        "duplicate digest has inconsistent declared sizes"
                    )
                }
            } else {
                uniqueLayers[layer.digest] = layer
            }
        }

        var presentObjectCount = 0
        var missingObjectCount = 0
        var additionalBytesRequired: UInt64 = 0
        for descriptor in uniqueLayers.values {
            if (try? validateObject(descriptor)) != nil {
                presentObjectCount += 1
                continue
            }

            missingObjectCount += 1
            additionalBytesRequired = try addingByteCount(
                UInt64(descriptor.size),
                to: additionalBytesRequired
            )
        }

        return DiskSpacePlan(
            inputObjectCount: layers.count,
            uniqueObjectCount: uniqueLayers.count,
            presentObjectCount: presentObjectCount,
            missingObjectCount: missingObjectCount,
            additionalBytesRequired: additionalBytesRequired
        )
    }

    func estimateGarbageCollectionReclaimUnlocked(
        additionalReachableDigests: Set<String>
    ) throws -> ReclaimEstimate {
        let mark = try markReachableStateUnlocked()
        var reachableDigests = mark.objectDigests
        reachableDigests.formUnion(additionalReachableDigests)
        let incompleteOperations = try incompleteOperationsUnlocked()
        reachableDigests.formUnion(
            incompleteOperations.flatMap { $0.layers.map(\.digest) }
        )
        var reachableGenerations = mark.generations
        reachableGenerations.formUnion(incompleteOperations.map {
            RootedGeneration(gameID: $0.gameID, generationID: $0.generationID)
        })

        let generationUsage = try reclaimableGenerationUsageUnlocked(preserving: reachableGenerations)

        var casUsage = FileUsage()
        for url in try validatedObjectURLsUnlocked() {
            guard !reachableDigests.contains(casDigest(for: url)) else {
                continue
            }
            try casUsage.addRegularFile(url, store: self)
        }

        let protectedDownloads = Set(incompleteOperations.map(\.operationID))
        var downloadUsage = FileUsage()
        for url in try fileManager.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: nil
        ) where !protectedDownloads.contains(url.lastPathComponent) {
            try downloadUsage.addContents(of: url, store: self)
        }

        var quarantineUsage = FileUsage()
        for url in try fileManager.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: nil
        ) {
            try quarantineUsage.addContents(of: url, store: self)
        }

        let totalBytes = try addingByteCounts([
            generationUsage.bytes, casUsage.bytes, downloadUsage.bytes, quarantineUsage.bytes
        ])
        return ReclaimEstimate(
            generationBytes: generationUsage.bytes,
            casObjectBytes: casUsage.bytes,
            abandonedDownloadBytes: downloadUsage.bytes,
            quarantineBytes: quarantineUsage.bytes,
            totalBytes: totalBytes,
            deferredOperationCount: incompleteOperations.count,
            generationCount: generationUsage.count,
            casObjectCount: casUsage.fileCount,
            abandonedDownloadFileCount: downloadUsage.fileCount,
            quarantineFileCount: quarantineUsage.fileCount
        )
    }

    func incompleteOperationsUnlocked() throws -> [ActivationOperation] {
        let journalURLs = try fileManager.contentsOfDirectory(
            at: journalsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }

        var operations: [ActivationOperation] = []
        for url in journalURLs {
            let operation = try readJournal(url)
            if !operation.state.isTerminal {
                operations.append(operation)
            }
        }
        return operations
    }

    func reclaimableGenerationUsageUnlocked(
        preserving roots: Set<RootedGeneration>
    ) throws -> (bytes: UInt64, count: Int) {
        var bytes: UInt64 = 0
        var count = 0
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
                guard !roots.contains(root) else {
                    continue
                }
                bytes = try addingByteCount(
                    recursiveReclaimableRegularFileBytes(generationDirectory),
                    to: bytes
                )
                count += 1
            }
        }
        return (bytes, count)
    }

    func casDigest(for url: URL) -> String {
        let shard = url.deletingLastPathComponent().lastPathComponent
        let suffix = url.lastPathComponent
        return "sha256:\(shard)\(suffix)"
    }

    func addingByteCount(_ value: UInt64, to total: UInt64) throws -> UInt64 {
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard !overflow else {
            throw DiskPlanningError.byteCountOverflow
        }
        return sum
    }

    func addingByteCounts(_ values: [UInt64]) throws -> UInt64 {
        try values.reduce(0) { total, value in
            try addingByteCount(value, to: total)
        }
    }
}

private struct FileUsage {
    var bytes: UInt64 = 0
    var fileCount = 0

    mutating func addRegularFile(_ url: URL, store: ContentStore) throws {
        guard store.isRegularFile(url) else {
            return
        }
        let attributes = try store.fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            return
        }
        bytes = try store.addingByteCount(number.uint64Value, to: bytes)
        fileCount += 1
    }

    mutating func addContents(of url: URL, store: ContentStore) throws {
        if store.isRegularFile(url) {
            try addRegularFile(url, store: store)
            return
        }
        guard store.isDirectory(url),
              let enumerator = store.fileManager.enumerator(
                  at: url,
                  includingPropertiesForKeys: nil,
                  options: []
              ) else {
            return
        }
        while let item = enumerator.nextObject() as? URL {
            try addRegularFile(item, store: store)
        }
    }
}
