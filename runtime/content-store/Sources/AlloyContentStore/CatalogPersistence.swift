// Author: Timur Isaev

import Foundation
import SQLite3

extension ContentStore {
    func loadCatalogSnapshotUnlocked() throws -> CatalogDump {
        guard isRegularFile(catalogURL) else {
            throw CatalogError.catalogMissing
        }
        let database = try CatalogSQLiteDatabase(
            url: catalogURL,
            createIfMissing: false
        )
        try validateCatalogSchema(database)

        let objects = try loadCatalogObjects(database)
        let generations = try loadCatalogGenerations(database)
        let references = try loadCatalogReferences(database)
        let leases = try loadCatalogLeases(database)
        let inventory = try loadCatalogInventory(database)
        return CatalogDump(
            objects: objects,
            generations: generations,
            references: references,
            leases: leases,
            inventory: inventory
        )
    }

    func loadCatalogInventoryUnlocked() throws -> CatalogInventory {
        guard isRegularFile(catalogURL) else {
            throw CatalogError.catalogMissing
        }
        let database = try CatalogSQLiteDatabase(
            url: catalogURL,
            createIfMissing: false
        )
        try validateCatalogSchema(database)
        return try loadCatalogInventory(database)
    }

    func replaceCatalogUnlocked(
        with snapshot: CatalogDump,
        faultInjector: FaultInjector?
    ) throws {
        try faultInjector?("before-catalog-maintenance")
        try removeCatalogFilesUnlocked()
        try createDirectory(catalogURL.deletingLastPathComponent())
        do {
            let database = try CatalogSQLiteDatabase(
                url: catalogURL,
                createIfMissing: true
            )
            try database.execute(CatalogSchema.creationSQL)
            try database.transaction {
                try writeCatalogSnapshot(snapshot, to: database)
                try faultInjector?("after-catalog-reconcile")
            }
        }
        try syncFile(catalogURL)
        try syncDirectory(catalogURL.deletingLastPathComponent())
        try faultInjector?("after-catalog-commit")
    }

    func reconcileCatalogUnlocked(
        from catalog: CatalogDump,
        to snapshot: CatalogDump,
        faultInjector: FaultInjector?
    ) throws {
        try faultInjector?("before-catalog-maintenance")
        let database = try CatalogSQLiteDatabase(
            url: catalogURL,
            createIfMissing: false
        )
        try validateCatalogSchema(database)
        try database.transaction {
            try writeCatalogDelta(
                from: catalog,
                to: snapshot,
                in: database
            )
            try faultInjector?("after-catalog-reconcile")
        }
        try syncFile(catalogURL)
        try syncDirectory(catalogURL.deletingLastPathComponent())
        try faultInjector?("after-catalog-commit")
    }

    func removeCatalogFilesUnlocked() throws {
        for url in [
            catalogURL,
            URL(fileURLWithPath: catalogURL.path + "-journal"),
            URL(fileURLWithPath: catalogURL.path + "-wal"),
            URL(fileURLWithPath: catalogURL.path + "-shm")
        ] where pathEntryExists(url) {
            guard isRegularFile(url) else {
                throw ContentStoreError.unsafeStoreEntry(url.path)
            }
            try fileManager.removeItem(at: url)
        }
        try syncDirectory(catalogURL.deletingLastPathComponent())
    }

    func validateCatalogSchema(_ database: CatalogSQLiteDatabase) throws {
        let applicationID = try catalogScalarInteger(
            database,
            sql: "PRAGMA application_id"
        )
        guard applicationID == CatalogSchema.applicationID else {
            throw CatalogError.invalidSchema(
                "application_id \(applicationID) is not \(CatalogSchema.applicationID)"
            )
        }
        let userVersion = try catalogScalarInteger(
            database,
            sql: "PRAGMA user_version"
        )
        guard userVersion == CatalogSchema.userVersion else {
            throw CatalogError.invalidSchema(
                "user_version \(userVersion) is not \(CatalogSchema.userVersion)"
            )
        }
        let statement = try database.prepare(
            "SELECT schema_version FROM catalog_metadata WHERE singleton = 1"
        )
        var versions: [String] = []
        try statement.rows { row in
            versions.append(try row.string(at: 0))
        }
        guard versions == [CatalogDump.currentSchemaVersion] else {
            throw CatalogError.invalidSchema(
                "catalog_metadata does not declare schema 1.0"
            )
        }
    }

    func catalogScalarInteger(
        _ database: CatalogSQLiteDatabase,
        sql: String
    ) throws -> Int64 {
        let statement = try database.prepare(sql)
        var values: [Int64] = []
        try statement.rows { row in
            values.append(try row.integer(at: 0))
        }
        guard values.count == 1, let value = values.first else {
            throw CatalogError.invalidCatalogValue(
                "scalar query returned \(values.count) rows"
            )
        }
        return value
    }

    func loadCatalogObjects(
        _ database: CatalogSQLiteDatabase
    ) throws -> [CatalogObjectRecord] {
        let statement = try database.prepare(
            """
            SELECT digest, size, refcount
            FROM objects
            ORDER BY digest
            """
        )
        var records: [CatalogObjectRecord] = []
        try statement.rows { row in
            records.append(CatalogObjectRecord(
                digest: try row.string(at: 0),
                size: try catalogInt(try row.integer(at: 1), field: "object size"),
                refCount: try catalogInt(
                    try row.integer(at: 2),
                    field: "object refcount"
                )
            ))
        }
        return records
    }

    func loadCatalogGenerations(
        _ database: CatalogSQLiteDatabase
    ) throws -> [CatalogGenerationRecord] {
        let layersByGeneration = try loadCatalogGenerationLayers(database)
        let statement = try database.prepare(
            """
            SELECT game_id, generation_id, manifest_digest, layer_count
            FROM generations
            ORDER BY game_id, generation_id
            """
        )
        var records: [CatalogGenerationRecord] = []
        try statement.rows { row in
            records.append(try catalogGenerationRecord(
                row,
                layersByGeneration: layersByGeneration
            ))
        }
        guard records.count == Set(layersByGeneration.keys).count
                || layersByGeneration.isEmpty else {
            throw CatalogError.invalidCatalogValue(
                "generation layers reference a missing generation"
            )
        }
        return records
    }

    func loadCatalogGenerationLayers(
        _ database: CatalogSQLiteDatabase
    ) throws -> [CatalogGenerationKey: [(Int, String)]] {
        let layerStatement = try database.prepare(
            """
            SELECT game_id, generation_id, layer_index, digest
            FROM generation_layers
            ORDER BY game_id, generation_id, layer_index
            """
        )
        var layersByGeneration: [CatalogGenerationKey: [(Int, String)]] = [:]
        try layerStatement.rows { row in
            let key = CatalogGenerationKey(
                gameID: try row.string(at: 0),
                generationID: try row.string(at: 1)
            )
            layersByGeneration[key, default: []].append((
                try catalogInt(
                    try row.integer(at: 2),
                    field: "generation layer index"
                ),
                try row.string(at: 3)
            ))
        }
        return layersByGeneration
    }

    func catalogGenerationRecord(
        _ row: CatalogSQLiteRow,
        layersByGeneration: [CatalogGenerationKey: [(Int, String)]]
    ) throws -> CatalogGenerationRecord {
        let gameID = try row.string(at: 0)
        let generationID = try row.string(at: 1)
        let layerCount = try catalogInt(
            try row.integer(at: 3),
            field: "generation layer count"
        )
        let indexedLayers = layersByGeneration[
            CatalogGenerationKey(gameID: gameID, generationID: generationID),
            default: []
        ]
        guard indexedLayers.count == layerCount,
              indexedLayers.map(\.0) == Array(0..<layerCount) else {
            throw CatalogError.invalidCatalogValue(
                "non-contiguous layers for \(gameID)/\(generationID)"
            )
        }
        return CatalogGenerationRecord(
            gameID: gameID,
            generationID: generationID,
            manifestDigest: try row.string(at: 2),
            objectDigests: indexedLayers.map(\.1)
        )
    }

    func loadCatalogReferences(
        _ database: CatalogSQLiteDatabase
    ) throws -> [CatalogReferenceRecord] {
        let statement = try database.prepare(
            """
            SELECT game_id, kind, generation_id, manifest_digest
            FROM generation_references
            ORDER BY game_id, kind
            """
        )
        var records: [CatalogReferenceRecord] = []
        try statement.rows { row in
            records.append(CatalogReferenceRecord(
                gameID: try row.string(at: 0),
                kind: try row.string(at: 1),
                generationID: try row.string(at: 2),
                manifestDigest: try row.string(at: 3)
            ))
        }
        return records
    }

    func loadCatalogLeases(
        _ database: CatalogSQLiteDatabase
    ) throws -> [CatalogLeaseRecord] {
        let objectsByLease = try loadCatalogLeaseObjects(database)
        let statement = try database.prepare(
            """
            SELECT lease_id, game_id, generation_id, manifest_digest,
                   process_id, start_time_seconds, start_time_microseconds,
                   created_at_unix_seconds, object_count
            FROM leases
            ORDER BY lease_id
            """
        )
        var records: [CatalogLeaseRecord] = []
        try statement.rows { row in
            records.append(try catalogLeaseRecord(
                row,
                objectsByLease: objectsByLease
            ))
        }
        guard records.count == Set(objectsByLease.keys).count
                || objectsByLease.isEmpty else {
            throw CatalogError.invalidCatalogValue(
                "lease objects reference a missing lease"
            )
        }
        return records
    }

    func loadCatalogLeaseObjects(
        _ database: CatalogSQLiteDatabase
    ) throws -> [String: [(Int, String)]] {
        let objectStatement = try database.prepare(
            """
            SELECT lease_id, object_index, digest
            FROM lease_objects
            ORDER BY lease_id, object_index
            """
        )
        var objectsByLease: [String: [(Int, String)]] = [:]
        try objectStatement.rows { row in
            objectsByLease[try row.string(at: 0), default: []].append((
                try catalogInt(
                    try row.integer(at: 1),
                    field: "lease object index"
                ),
                try row.string(at: 2)
            ))
        }
        return objectsByLease
    }

    func catalogLeaseRecord(
        _ row: CatalogSQLiteRow,
        objectsByLease: [String: [(Int, String)]]
    ) throws -> CatalogLeaseRecord {
        let leaseID = try row.string(at: 0)
        let objectCount = try catalogInt(
            try row.integer(at: 8),
            field: "lease object count"
        )
        let indexedObjects = objectsByLease[leaseID, default: []]
        guard indexedObjects.count == objectCount,
              indexedObjects.map(\.0) == Array(0..<objectCount) else {
            throw CatalogError.invalidCatalogValue(
                "non-contiguous objects for lease \(leaseID)"
            )
        }
        return CatalogLeaseRecord(
            leaseID: leaseID,
            gameID: try row.string(at: 1),
            generationID: try row.string(at: 2),
            manifestDigest: try row.string(at: 3),
            objectDigests: indexedObjects.map(\.1),
            holder: LeaseProcessIdentity(
                processID: try catalogInt32(
                    try row.integer(at: 4),
                    field: "lease process id"
                ),
                startTimeSeconds: try catalogUInt64(
                    try row.integer(at: 5),
                    field: "lease start seconds"
                ),
                startTimeMicroseconds: try catalogUInt32(
                    try row.integer(at: 6),
                    field: "lease start microseconds"
                )
            ),
            createdAtUnixSeconds: try row.integer(at: 7)
        )
    }

    func loadCatalogInventory(
        _ database: CatalogSQLiteDatabase
    ) throws -> CatalogInventory {
        let statement = try database.prepare(
            """
            SELECT object_count, object_bytes, object_reference_count,
                   generation_count, reference_count, lease_count
            FROM inventory
            WHERE singleton = 1
            """
        )
        var records: [CatalogInventory] = []
        try statement.rows { row in
            records.append(CatalogInventory(
                objectCount: try catalogInt(
                    try row.integer(at: 0),
                    field: "inventory object count"
                ),
                objectBytes: try catalogUInt64(
                    try row.integer(at: 1),
                    field: "inventory object bytes"
                ),
                objectReferenceCount: try catalogInt(
                    try row.integer(at: 2),
                    field: "inventory object reference count"
                ),
                generationCount: try catalogInt(
                    try row.integer(at: 3),
                    field: "inventory generation count"
                ),
                referenceCount: try catalogInt(
                    try row.integer(at: 4),
                    field: "inventory reference count"
                ),
                leaseCount: try catalogInt(
                    try row.integer(at: 5),
                    field: "inventory lease count"
                )
            ))
        }
        guard records.count == 1, let inventory = records.first else {
            throw CatalogError.invalidCatalogValue(
                "inventory must contain exactly one row"
            )
        }
        return inventory
    }

}
