// Author: Timur Isaev

import Foundation

extension ContentStore {
    public static let catalogMaintenanceFaultPoints = [
        "before-catalog-maintenance",
        "after-catalog-reconcile",
        "after-catalog-commit"
    ]

    /// Opens the rebuildable catalog, verifies it against disk truth, and
    /// replaces it when it is missing, invalid, or divergent.
    @discardableResult
    public func ensureCatalog(
        faultInjector: FaultInjector? = nil
    ) throws -> CatalogMaintenanceResult {
        try withExclusiveLock {
            try ensureCatalogUnlocked(faultInjector: faultInjector)
        }
    }

    /// Reconciles catalog rows with a fresh disk snapshot in one durable
    /// SQLite transaction. Disk is always the source of truth.
    @discardableResult
    public func synchronizeCatalog(
        faultInjector: FaultInjector? = nil
    ) throws -> CatalogMaintenanceResult {
        try withExclusiveLock {
            try synchronizeCatalogUnlocked(faultInjector: faultInjector)
        }
    }

    /// Deletes and recreates the catalog solely from versioned disk artifacts.
    @discardableResult
    public func rebuildCatalog(
        faultInjector: FaultInjector? = nil
    ) throws -> CatalogMaintenanceResult {
        try withExclusiveLock {
            let snapshot = try diskCatalogSnapshotUnlocked()
            try replaceCatalogUnlocked(
                with: snapshot,
                faultInjector: faultInjector
            )
            return CatalogMaintenanceResult(
                action: .rebuilt,
                repairedDivergenceCount: 0
            )
        }
    }

    /// Compares every modeled disk record with every catalog row. A changed
    /// row appears once in each direction, making lost and invented state
    /// independently visible.
    public func catalogConsistencyReport() throws -> CatalogConsistencyReport {
        try withExclusiveLock {
            let disk = try diskCatalogSnapshotUnlocked()
            guard pathEntryExists(catalogURL) else {
                return try missingCatalogReport(for: disk)
            }
            guard isRegularFile(catalogURL) else {
                throw ContentStoreError.unsafeStoreEntry(catalogURL.path)
            }
            return try compareCatalogSnapshots(
                catalog: loadCatalogSnapshotUnlocked(),
                disk: disk
            )
        }
    }

    /// Emits sorted, canonical JSON for reproducible comparisons and support
    /// diagnostics. SQLite page layout is deliberately not part of the format.
    public func canonicalCatalogDump() throws -> String {
        try withExclusiveLock {
            let snapshot = try loadCatalogSnapshotUnlocked()
            return try canonicalCatalogJSON(snapshot)
        }
    }

    /// Reads the transactionally maintained singleton inventory row.
    public func catalogInventory() throws -> CatalogInventory {
        try withExclusiveLock {
            try loadCatalogInventoryUnlocked()
        }
    }

    func ensureCatalogUnlocked(
        faultInjector: FaultInjector?
    ) throws -> CatalogMaintenanceResult {
        let disk = try diskCatalogSnapshotUnlocked()
        guard pathEntryExists(catalogURL) else {
            try replaceCatalogUnlocked(
                with: disk,
                faultInjector: faultInjector
            )
            return CatalogMaintenanceResult(
                action: .rebuilt,
                repairedDivergenceCount: 1
            )
        }
        guard isRegularFile(catalogURL) else {
            throw ContentStoreError.unsafeStoreEntry(catalogURL.path)
        }

        do {
            let report = try compareCatalogSnapshots(
                catalog: loadCatalogSnapshotUnlocked(),
                disk: disk
            )
            guard !report.isConsistent else {
                return CatalogMaintenanceResult(
                    action: .unchanged,
                    repairedDivergenceCount: 0
                )
            }
            try replaceCatalogUnlocked(
                with: disk,
                faultInjector: faultInjector
            )
            return CatalogMaintenanceResult(
                action: .rebuilt,
                repairedDivergenceCount: report.divergenceCount
            )
        } catch is CatalogError {
            try replaceCatalogUnlocked(
                with: disk,
                faultInjector: faultInjector
            )
            return CatalogMaintenanceResult(
                action: .rebuilt,
                repairedDivergenceCount: 1
            )
        }
    }

    func synchronizeCatalogUnlocked(
        faultInjector: FaultInjector?
    ) throws -> CatalogMaintenanceResult {
        let disk = try diskCatalogSnapshotUnlocked()
        guard pathEntryExists(catalogURL) else {
            try replaceCatalogUnlocked(
                with: disk,
                faultInjector: faultInjector
            )
            return CatalogMaintenanceResult(
                action: .rebuilt,
                repairedDivergenceCount: 1
            )
        }
        guard isRegularFile(catalogURL) else {
            throw ContentStoreError.unsafeStoreEntry(catalogURL.path)
        }

        let catalog: CatalogDump
        do {
            catalog = try loadCatalogSnapshotUnlocked()
        } catch is CatalogError {
            try replaceCatalogUnlocked(
                with: disk,
                faultInjector: faultInjector
            )
            return CatalogMaintenanceResult(
                action: .rebuilt,
                repairedDivergenceCount: 1
            )
        }
        let report = try compareCatalogSnapshots(catalog: catalog, disk: disk)
        guard !report.isConsistent else {
            return CatalogMaintenanceResult(
                action: .unchanged,
                repairedDivergenceCount: 0
            )
        }
        try reconcileCatalogUnlocked(
            from: catalog,
            to: disk,
            faultInjector: faultInjector
        )
        return CatalogMaintenanceResult(
            action: .reconciled,
            repairedDivergenceCount: report.divergenceCount
        )
    }

    func diskCatalogSnapshotUnlocked() throws -> CatalogDump {
        let objectState = try diskCatalogObjectsUnlocked()
        let generationState = try diskCatalogGenerationsUnlocked(
            objectSizes: objectState.sizes
        )
        let objects = objectState.sizes.map { digest, size in
            CatalogObjectRecord(
                digest: digest,
                size: size,
                refCount: generationState.referenceCounts[digest, default: 0]
            )
        }.sorted { $0.digest < $1.digest }
        let references = try diskCatalogReferencesUnlocked()
        let leases = try diskCatalogLeasesUnlocked()
        return CatalogDump(
            objects: objects,
            generations: generationState.records,
            references: references,
            leases: leases,
            inventory: CatalogInventory(
                objectCount: objects.count,
                objectBytes: objectState.totalBytes,
                objectReferenceCount: try catalogReferenceTotal(
                    generationState.referenceCounts
                ),
                generationCount: generationState.records.count,
                referenceCount: references.count,
                leaseCount: leases.count
            )
        )
    }

    func diskCatalogObjectsUnlocked() throws -> (
        sizes: [String: Int],
        totalBytes: UInt64
    ) {
        var objectSizes: [String: Int] = [:]
        var totalObjectBytes: UInt64 = 0
        for objectURL in try validatedObjectURLsUnlocked() {
            let digest = casDigest(for: objectURL)
            let byteCount = try regularFileBytes(objectURL)
            guard byteCount <= UInt64(Int.max) else {
                throw CatalogError.invalidCatalogValue(
                    "object \(digest) exceeds the supported integer range"
                )
            }
            objectSizes[digest] = Int(byteCount)
            let (sum, overflow) = totalObjectBytes.addingReportingOverflow(byteCount)
            guard !overflow else {
                throw CatalogError.invalidCatalogValue(
                    "object byte total overflows UInt64"
                )
            }
            totalObjectBytes = sum
        }
        return (objectSizes, totalObjectBytes)
    }

    func diskCatalogGenerationsUnlocked(
        objectSizes: [String: Int]
    ) throws -> (
        records: [CatalogGenerationRecord],
        referenceCounts: [String: Int]
    ) {
        var generations: [CatalogGenerationRecord] = []
        var objectReferenceCounts: [String: Int] = [:]
        let stagingGenerations = try catalogStagingGenerationsUnlocked()
        for gameDirectory in try directoryEntries(generationsDirectory) {
            try appendCatalogGenerations(
                in: gameDirectory,
                objectSizes: objectSizes,
                stagingGenerations: stagingGenerations,
                records: &generations,
                referenceCounts: &objectReferenceCounts
            )
        }
        generations.sort(by: catalogGenerationOrder)
        return (generations, objectReferenceCounts)
    }

    func catalogStagingGenerationsUnlocked() throws -> Set<RootedGeneration> {
        let journalURLs = try directoryEntries(journalsDirectory)
            .filter { $0.pathExtension == "json" }
        var stagingGenerations: Set<RootedGeneration> = []
        for journalURL in journalURLs {
            guard let operation = try? readJournal(journalURL),
                  !operation.state.isTerminal else {
                continue
            }
            stagingGenerations.insert(RootedGeneration(
                gameID: operation.gameID,
                generationID: ".\(operation.generationID).\(operation.operationID).staging"
            ))
        }
        return stagingGenerations
    }

    func appendCatalogGenerations(
        in gameDirectory: URL,
        objectSizes: [String: Int],
        stagingGenerations: Set<RootedGeneration>,
        records: inout [CatalogGenerationRecord],
        referenceCounts: inout [String: Int]
    ) throws {
        guard isDirectory(gameDirectory) else {
            throw ContentStoreError.unsafeStoreEntry(gameDirectory.path)
        }
        let gameID = gameDirectory.lastPathComponent
        try validateIdentifier(gameID)
        for generationDirectory in try directoryEntries(gameDirectory) {
            let generationID = generationDirectory.lastPathComponent
            if stagingGenerations.contains(RootedGeneration(
                gameID: gameID,
                generationID: generationID
            )) {
                continue
            }
            let record = try diskCatalogGeneration(
                gameID: gameID,
                generationDirectory: generationDirectory
            )
            records.append(record)
            for digest in record.objectDigests {
                guard objectSizes[digest] != nil else {
                    throw ContentStoreError.corruptObject(digest)
                }
                let current = referenceCounts[digest, default: 0]
                guard current < Int.max else {
                    throw CatalogError.invalidCatalogValue(
                        "object reference count overflows Int"
                    )
                }
                referenceCounts[digest] = current + 1
            }
        }
    }

    func diskCatalogGeneration(
        gameID: String,
        generationDirectory: URL
    ) throws -> CatalogGenerationRecord {
        let generationID = generationDirectory.lastPathComponent
        guard isDirectory(generationDirectory) else {
            throw ContentStoreError.unsafeStoreEntry(generationDirectory.path)
        }
        try validateIdentifier(generationID)
        let manifestURL = generationDirectory.appendingPathComponent("manifest.json")
        guard isRegularFile(manifestURL) else {
            throw ContentStoreError.incompleteGeneration(generationID)
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let reference = GenerationReference(
            generationID: generationID,
            manifestDigest: Self.digest(manifestData)
        )
        try validateReference(reference, gameID: gameID)
        let manifest = try decoder.decode(
            GenerationManifest.self,
            from: manifestData
        )
        return CatalogGenerationRecord(
            gameID: gameID,
            generationID: generationID,
            manifestDigest: reference.manifestDigest,
            objectDigests: manifest.layers.map(\.digest)
        )
    }

    func catalogReferenceTotal(
        _ referenceCounts: [String: Int]
    ) throws -> Int {
        try referenceCounts.values.reduce(0) {
            let (sum, overflow) = $0.addingReportingOverflow($1)
            guard !overflow else {
                throw CatalogError.invalidCatalogValue(
                    "object reference total overflows Int"
                )
            }
            return sum
        }
    }

    func diskCatalogReferencesUnlocked() throws -> [CatalogReferenceRecord] {
        var records: [CatalogReferenceRecord] = []
        for gameDirectory in try directoryEntries(referencesDirectory) {
            guard isDirectory(gameDirectory) else {
                throw ContentStoreError.unsafeStoreEntry(gameDirectory.path)
            }
            let gameID = gameDirectory.lastPathComponent
            try validateIdentifier(gameID)
            let allowedEntries = Set(ReferenceKind.allCases.map {
                "\($0.rawValue).json"
            })
            for entry in try directoryEntries(gameDirectory)
            where !allowedEntries.contains(entry.lastPathComponent) {
                throw ContentStoreError.unsafeStoreEntry(entry.path)
            }
            for kind in ReferenceKind.allCases {
                guard let reference = try readReference(kind, gameID: gameID) else {
                    continue
                }
                records.append(CatalogReferenceRecord(
                    gameID: gameID,
                    kind: kind.rawValue,
                    generationID: reference.generationID,
                    manifestDigest: reference.manifestDigest
                ))
            }
        }
        return records.sorted(by: catalogReferenceOrder)
    }

    func diskCatalogLeasesUnlocked() throws -> [CatalogLeaseRecord] {
        var records: [CatalogLeaseRecord] = []
        let leaseURLs = try directoryEntries(leasesDirectory)
        for leaseURL in leaseURLs {
            guard leaseURL.pathExtension == "json" else {
                throw ContentStoreError.unsafeStoreEntry(leaseURL.path)
            }
            let lease = try readLease(leaseURL)
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
            records.append(CatalogLeaseRecord(
                leaseID: lease.leaseID,
                gameID: lease.gameID,
                generationID: lease.generationID,
                manifestDigest: lease.manifestDigest,
                objectDigests: lease.objectDigests,
                holder: lease.holder,
                createdAtUnixSeconds: lease.createdAtUnixSeconds
            ))
        }
        return records.sorted { $0.leaseID < $1.leaseID }
    }

    func compareCatalogSnapshots(
        catalog: CatalogDump,
        disk: CatalogDump
    ) throws -> CatalogConsistencyReport {
        let catalogLines = Set(try catalogRecordLines(catalog))
        let diskLines = Set(try catalogRecordLines(disk))
        return CatalogConsistencyReport(
            catalogAhead: Array(catalogLines.subtracting(diskLines)),
            diskAhead: Array(diskLines.subtracting(catalogLines))
        )
    }

    func missingCatalogReport(
        for disk: CatalogDump
    ) throws -> CatalogConsistencyReport {
        CatalogConsistencyReport(
            catalogAhead: [],
            diskAhead: ["catalog-file:missing"] + (try catalogRecordLines(disk))
        )
    }

    func catalogRecordLines(_ dump: CatalogDump) throws -> [String] {
        var lines: [String] = []
        for object in dump.objects {
            lines.append("object:\(try canonicalCatalogJSON(object))")
        }
        for generation in dump.generations {
            lines.append("generation:\(try canonicalCatalogJSON(generation))")
        }
        for reference in dump.references {
            lines.append("reference:\(try canonicalCatalogJSON(reference))")
        }
        for lease in dump.leases {
            lines.append("lease:\(try canonicalCatalogJSON(lease))")
        }
        lines.append("inventory:\(try canonicalCatalogJSON(dump.inventory))")
        return lines.sorted()
    }

    func canonicalCatalogJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(bytes: data, encoding: .utf8) else {
            throw CatalogError.invalidCatalogValue(
                "canonical JSON is not UTF-8"
            )
        }
        return string + "\n"
    }

    var catalogURL: URL {
        root.appendingPathComponent("metadata/catalog.sqlite")
    }
}

private func catalogGenerationOrder(
    _ lhs: CatalogGenerationRecord,
    _ rhs: CatalogGenerationRecord
) -> Bool {
    if lhs.gameID != rhs.gameID {
        return lhs.gameID < rhs.gameID
    }
    return lhs.generationID < rhs.generationID
}

private func catalogReferenceOrder(
    _ lhs: CatalogReferenceRecord,
    _ rhs: CatalogReferenceRecord
) -> Bool {
    if lhs.gameID != rhs.gameID {
        return lhs.gameID < rhs.gameID
    }
    return lhs.kind < rhs.kind
}
