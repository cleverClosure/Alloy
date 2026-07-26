// Author: Timur Isaev

import Foundation

extension ContentStore {
    func writeCatalogDelta(
        from catalog: CatalogDump,
        to disk: CatalogDump,
        in database: CatalogSQLiteDatabase
    ) throws {
        let catalogObjects = Dictionary(
            uniqueKeysWithValues: catalog.objects.map { ($0.digest, $0) }
        )
        let diskObjects = Dictionary(
            uniqueKeysWithValues: disk.objects.map { ($0.digest, $0) }
        )
        for object in disk.objects where catalogObjects[object.digest] != object {
            try upsertCatalogObject(object, into: database)
        }

        let catalogReferences = catalogReferenceDictionary(catalog.references)
        let diskReferences = catalogReferenceDictionary(disk.references)
        for reference in catalog.references
        where diskReferences[catalogReferenceKey(reference)] != reference {
            try deleteCatalogReference(reference, from: database)
        }

        let catalogLeases = Dictionary(
            uniqueKeysWithValues: catalog.leases.map { ($0.leaseID, $0) }
        )
        let diskLeases = Dictionary(
            uniqueKeysWithValues: disk.leases.map { ($0.leaseID, $0) }
        )
        for lease in catalog.leases where diskLeases[lease.leaseID] != lease {
            try deleteCatalogLease(lease, from: database)
        }

        let catalogGenerations = catalogGenerationDictionary(catalog.generations)
        let diskGenerations = catalogGenerationDictionary(disk.generations)
        for generation in catalog.generations
        where diskGenerations[catalogGenerationKey(generation)] == nil {
            try deleteCatalogGeneration(generation, from: database)
        }
        for generation in disk.generations
        where catalogGenerations[catalogGenerationKey(generation)] != generation {
            try upsertCatalogGeneration(generation, into: database)
        }

        for object in catalog.objects where diskObjects[object.digest] == nil {
            try deleteCatalogObject(object, from: database)
        }
        for reference in disk.references
        where catalogReferences[catalogReferenceKey(reference)] != reference {
            try insertCatalogReference(reference, into: database)
        }
        for lease in disk.leases where catalogLeases[lease.leaseID] != lease {
            try insertCatalogLease(lease, into: database)
        }
        if catalog.inventory != disk.inventory {
            try database.execute("DELETE FROM inventory")
            try insertCatalogInventory(disk.inventory, into: database)
        }
    }

    func writeCatalogSnapshot(
        _ snapshot: CatalogDump,
        to database: CatalogSQLiteDatabase
    ) throws {
        try database.execute(
            """
            DELETE FROM generation_references;
            DELETE FROM lease_objects;
            DELETE FROM leases;
            DELETE FROM generation_layers;
            DELETE FROM generations;
            DELETE FROM objects;
            DELETE FROM inventory;
            """
        )

        for object in snapshot.objects {
            let statement = try database.prepare(
                "INSERT INTO objects(digest, size, refcount) VALUES (?, ?, ?)"
            )
            try statement.bind(object.digest, at: 1)
            try statement.bind(Int64(object.size), at: 2)
            try statement.bind(Int64(object.refCount), at: 3)
            try statement.execute()
        }
        for generation in snapshot.generations {
            try insertCatalogGeneration(generation, into: database)
        }
        for reference in snapshot.references {
            try insertCatalogReference(reference, into: database)
        }
        for lease in snapshot.leases {
            try insertCatalogLease(lease, into: database)
        }
        try insertCatalogInventory(snapshot.inventory, into: database)
    }

    func upsertCatalogObject(
        _ object: CatalogObjectRecord,
        into database: CatalogSQLiteDatabase
    ) throws {
        let statement = try database.prepare(
            """
            INSERT INTO objects(digest, size, refcount)
            VALUES (?, ?, ?)
            ON CONFLICT(digest) DO UPDATE SET
                size = excluded.size,
                refcount = excluded.refcount
            """
        )
        try statement.bind(object.digest, at: 1)
        try statement.bind(Int64(object.size), at: 2)
        try statement.bind(Int64(object.refCount), at: 3)
        try statement.execute()
    }

    func insertCatalogReference(
        _ reference: CatalogReferenceRecord,
        into database: CatalogSQLiteDatabase
    ) throws {
        let statement = try database.prepare(
            """
            INSERT INTO generation_references(
                game_id, kind, generation_id, manifest_digest
            ) VALUES (?, ?, ?, ?)
            """
        )
        try statement.bind(reference.gameID, at: 1)
        try statement.bind(reference.kind, at: 2)
        try statement.bind(reference.generationID, at: 3)
        try statement.bind(reference.manifestDigest, at: 4)
        try statement.execute()
    }

    func insertCatalogGeneration(
        _ generation: CatalogGenerationRecord,
        into database: CatalogSQLiteDatabase
    ) throws {
        let statement = try database.prepare(
            """
            INSERT INTO generations(
                game_id, generation_id, manifest_digest, layer_count
            ) VALUES (?, ?, ?, ?)
            """
        )
        try statement.bind(generation.gameID, at: 1)
        try statement.bind(generation.generationID, at: 2)
        try statement.bind(generation.manifestDigest, at: 3)
        try statement.bind(Int64(generation.objectDigests.count), at: 4)
        try statement.execute()
        try insertCatalogGenerationLayers(generation, into: database)
    }

    func insertCatalogGenerationLayers(
        _ generation: CatalogGenerationRecord,
        into database: CatalogSQLiteDatabase
    ) throws {
        for (index, digest) in generation.objectDigests.enumerated() {
            let layerStatement = try database.prepare(
                """
                INSERT INTO generation_layers(
                    game_id, generation_id, layer_index, digest
                ) VALUES (?, ?, ?, ?)
                """
            )
            try layerStatement.bind(generation.gameID, at: 1)
            try layerStatement.bind(generation.generationID, at: 2)
            try layerStatement.bind(Int64(index), at: 3)
            try layerStatement.bind(digest, at: 4)
            try layerStatement.execute()
        }
    }

    func upsertCatalogGeneration(
        _ generation: CatalogGenerationRecord,
        into database: CatalogSQLiteDatabase
    ) throws {
        let deleteLayers = try database.prepare(
            """
            DELETE FROM generation_layers
            WHERE game_id = ? AND generation_id = ?
            """
        )
        try deleteLayers.bind(generation.gameID, at: 1)
        try deleteLayers.bind(generation.generationID, at: 2)
        try deleteLayers.execute()

        let statement = try database.prepare(
            """
            INSERT INTO generations(
                game_id, generation_id, manifest_digest, layer_count
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(game_id, generation_id) DO UPDATE SET
                manifest_digest = excluded.manifest_digest,
                layer_count = excluded.layer_count
            """
        )
        try statement.bind(generation.gameID, at: 1)
        try statement.bind(generation.generationID, at: 2)
        try statement.bind(generation.manifestDigest, at: 3)
        try statement.bind(Int64(generation.objectDigests.count), at: 4)
        try statement.execute()
        try insertCatalogGenerationLayers(generation, into: database)
    }

    func insertCatalogLease(
        _ lease: CatalogLeaseRecord,
        into database: CatalogSQLiteDatabase
    ) throws {
        let statement = try database.prepare(
            """
            INSERT INTO leases(
                lease_id, game_id, generation_id, manifest_digest,
                process_id, start_time_seconds, start_time_microseconds,
                created_at_unix_seconds, object_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind(lease.leaseID, at: 1)
        try statement.bind(lease.gameID, at: 2)
        try statement.bind(lease.generationID, at: 3)
        try statement.bind(lease.manifestDigest, at: 4)
        try statement.bind(Int64(lease.holder.processID), at: 5)
        try statement.bind(
            try catalogSQLiteInteger(
                lease.holder.startTimeSeconds,
                field: "lease start seconds"
            ),
            at: 6
        )
        try statement.bind(Int64(lease.holder.startTimeMicroseconds), at: 7)
        try statement.bind(lease.createdAtUnixSeconds, at: 8)
        try statement.bind(Int64(lease.objectDigests.count), at: 9)
        try statement.execute()

        for (index, digest) in lease.objectDigests.enumerated() {
            let objectStatement = try database.prepare(
                """
                INSERT INTO lease_objects(lease_id, object_index, digest)
                VALUES (?, ?, ?)
                """
            )
            try objectStatement.bind(lease.leaseID, at: 1)
            try objectStatement.bind(Int64(index), at: 2)
            try objectStatement.bind(digest, at: 3)
            try objectStatement.execute()
        }
    }

    func insertCatalogInventory(
        _ inventory: CatalogInventory,
        into database: CatalogSQLiteDatabase
    ) throws {
        let statement = try database.prepare(
            """
            INSERT INTO inventory(
                singleton, object_count, object_bytes, object_reference_count,
                generation_count, reference_count, lease_count
            ) VALUES (1, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind(Int64(inventory.objectCount), at: 1)
        try statement.bind(
            try catalogSQLiteInteger(
                inventory.objectBytes,
                field: "inventory object bytes"
            ),
            at: 2
        )
        try statement.bind(Int64(inventory.objectReferenceCount), at: 3)
        try statement.bind(Int64(inventory.generationCount), at: 4)
        try statement.bind(Int64(inventory.referenceCount), at: 5)
        try statement.bind(Int64(inventory.leaseCount), at: 6)
        try statement.execute()
    }

    func deleteCatalogObject(
        _ object: CatalogObjectRecord,
        from database: CatalogSQLiteDatabase
    ) throws {
        let statement = try database.prepare(
            "DELETE FROM objects WHERE digest = ?"
        )
        try statement.bind(object.digest, at: 1)
        try statement.execute()
    }

    func deleteCatalogGeneration(
        _ generation: CatalogGenerationRecord,
        from database: CatalogSQLiteDatabase
    ) throws {
        let statement = try database.prepare(
            """
            DELETE FROM generations
            WHERE game_id = ? AND generation_id = ?
            """
        )
        try statement.bind(generation.gameID, at: 1)
        try statement.bind(generation.generationID, at: 2)
        try statement.execute()
    }

    func deleteCatalogReference(
        _ reference: CatalogReferenceRecord,
        from database: CatalogSQLiteDatabase
    ) throws {
        let statement = try database.prepare(
            """
            DELETE FROM generation_references
            WHERE game_id = ? AND kind = ?
            """
        )
        try statement.bind(reference.gameID, at: 1)
        try statement.bind(reference.kind, at: 2)
        try statement.execute()
    }

    func deleteCatalogLease(
        _ lease: CatalogLeaseRecord,
        from database: CatalogSQLiteDatabase
    ) throws {
        let statement = try database.prepare(
            "DELETE FROM leases WHERE lease_id = ?"
        )
        try statement.bind(lease.leaseID, at: 1)
        try statement.execute()
    }

    func catalogGenerationDictionary(
        _ records: [CatalogGenerationRecord]
    ) -> [CatalogGenerationKey: CatalogGenerationRecord] {
        Dictionary(uniqueKeysWithValues: records.map {
            (catalogGenerationKey($0), $0)
        })
    }

    func catalogReferenceDictionary(
        _ records: [CatalogReferenceRecord]
    ) -> [CatalogReferenceKey: CatalogReferenceRecord] {
        Dictionary(uniqueKeysWithValues: records.map {
            (catalogReferenceKey($0), $0)
        })
    }

    func catalogGenerationKey(
        _ record: CatalogGenerationRecord
    ) -> CatalogGenerationKey {
        CatalogGenerationKey(
            gameID: record.gameID,
            generationID: record.generationID
        )
    }

    func catalogReferenceKey(
        _ record: CatalogReferenceRecord
    ) -> CatalogReferenceKey {
        CatalogReferenceKey(gameID: record.gameID, kind: record.kind)
    }
}
