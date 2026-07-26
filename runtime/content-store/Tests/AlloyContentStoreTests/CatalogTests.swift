// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private func catalogTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-content-store-catalog-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func withCatalogStore(
    _ body: (URL, ContentStore) throws -> Void
) throws {
    let root = try catalogTestRoot()
    defer {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            chmod(url.path, S_IRWXU)
        }
        chmod(root.path, S_IRWXU)
        try? FileManager.default.removeItem(at: root)
    }
    try body(root, ContentStore(root: root))
}

private func catalogLayer(
    _ value: String,
    version: String
) -> LayerInput {
    let data = Data(value.utf8)
    return LayerInput(
        descriptor: LayerDescriptor(
            name: "catalog-test-runtime",
            version: version,
            digest: ContentStore.digest(data),
            mediaType: "application/vnd.alloy.test-layer",
            size: data.count,
            role: .hostRuntime
        ),
        contents: data
    )
}

private func activateCatalogGeneration(
    _ store: ContentStore,
    generationID: String,
    uniquePayload: String
) throws -> GenerationReference {
    try store.activate(
        gameID: "game",
        generationID: generationID,
        layers: [
            catalogLayer("shared", version: generationID),
            catalogLayer(uniquePayload, version: generationID)
        ]
    )
}

private func installCatalogDiskOnlyObject(
    _ data: Data,
    in store: ContentStore
) throws -> CatalogObjectRecord {
    let digest = ContentStore.digest(data)
    let url = try store.objectURL(digest)
    try store.createDirectory(url.deletingLastPathComponent())
    try data.write(to: url, options: .withoutOverwriting)
    guard chmod(url.path, S_IRUSR | S_IRGRP | S_IROTH) == 0 else {
        throw ContentStoreError.systemCall(
            operation: "chmod catalog test object",
            code: errno
        )
    }
    return CatalogObjectRecord(digest: digest, size: data.count, refCount: 0)
}

private func insertCatalogOnlyObject(
    _ object: CatalogObjectRecord,
    in store: ContentStore
) throws {
    let database = try CatalogSQLiteDatabase(
        url: store.catalogURL,
        createIfMissing: false
    )
    let statement = try database.prepare(
        "INSERT INTO objects(digest, size, refcount) VALUES (?, ?, ?)"
    )
    try statement.bind(object.digest, at: 1)
    try statement.bind(Int64(object.size), at: 2)
    try statement.bind(Int64(object.refCount), at: 3)
    try statement.execute()
}

private func catalogRecordLine<Value: Encodable>(
    _ kind: String,
    value: Value,
    store: ContentStore
) throws -> String {
    "\(kind):\(try store.canonicalCatalogJSON(value))"
}

private func lifecycleCatalogInventory(
    leaseCount: Int
) -> CatalogInventory {
    CatalogInventory(
        objectCount: 3,
        objectBytes: UInt64(
            Data("shared".utf8).count
                + Data("unique-b".utf8).count
                + Data("unique-c".utf8).count
        ),
        objectReferenceCount: 4,
        generationCount: 2,
        referenceCount: 2,
        leaseCount: leaseCount
    )
}

private func catalogScanRejectsEntry(
    _ store: ContentStore,
    named expectedName: String
) -> Bool {
    do {
        _ = try store.catalogConsistencyReport()
        return false
    } catch let ContentStoreError.unsafeStoreEntry(path) {
        return URL(fileURLWithPath: path).lastPathComponent == expectedName
    } catch {
        return false
    }
}

@Test("opening a fresh or invalid store creates a consistent empty catalog")
func catalogOpenCreatesAndRepairsEmptyCatalog() throws {
    try withCatalogStore { root, store in
        #expect(store.isRegularFile(store.catalogURL))
        #expect(try store.catalogConsistencyReport() == .consistent)
        #expect(try store.catalogInventory() == CatalogInventory(
            objectCount: 0,
            objectBytes: 0,
            objectReferenceCount: 0,
            generationCount: 0,
            referenceCount: 0,
            leaseCount: 0
        ))
        let canonicalEmptyDump = try store.canonicalCatalogDump()

        try FileManager.default.removeItem(at: store.catalogURL)
        try Data("not-a-sqlite-catalog".utf8).write(to: store.catalogURL)
        let reopened = try ContentStore(root: root)

        #expect(try reopened.catalogConsistencyReport() == .consistent)
        #expect(try reopened.canonicalCatalogDump() == canonicalEmptyDump)
    }
}

@Test("activation, leases, and garbage collection maintain the catalog automatically")
func catalogTracksLifecycleMutationsAutomatically() throws {
    try withCatalogStore { _, store in
        _ = try activateCatalogGeneration(
            store,
            generationID: "generation-a",
            uniquePayload: "unique-a"
        )
        #expect(try store.catalogConsistencyReport() == .consistent)

        let leased = try activateCatalogGeneration(
            store,
            generationID: "generation-b",
            uniquePayload: "unique-b"
        )
        #expect(try store.catalogConsistencyReport() == .consistent)
        let lease = try store.acquireLease(gameID: "game", generation: leased)
        #expect(try store.catalogConsistencyReport() == .consistent)

        _ = try activateCatalogGeneration(
            store,
            generationID: "generation-c",
            uniquePayload: "unique-c"
        )
        #expect(try store.catalogConsistencyReport() == .consistent)
        try Data("quarantined".utf8).write(
            to: store.quarantineDirectory.appendingPathComponent("seeded-entry")
        )
        let collection = try store.collectGarbage()
        #expect(collection.generationsRemoved == 1)
        #expect(collection.quarantineEntriesRemoved == 1)
        #expect(try store.catalogConsistencyReport() == .consistent)
        #expect(try store.catalogInventory() == lifecycleCatalogInventory(leaseCount: 1))

        try store.releaseLease(lease)

        #expect(try store.catalogConsistencyReport() == .consistent)
        #expect(try store.catalogInventory() == lifecycleCatalogInventory(leaseCount: 0))
    }
}

@Test("deletion, open-time rebuild, and forced rebuild preserve the canonical dump")
func catalogRebuildConvergesWithAutomaticMaintenance() throws {
    try withCatalogStore { root, store in
        _ = try activateCatalogGeneration(
            store,
            generationID: "generation-a",
            uniquePayload: "unique-a"
        )
        let leased = try activateCatalogGeneration(
            store,
            generationID: "generation-b",
            uniquePayload: "unique-b"
        )
        _ = try store.acquireLease(gameID: "game", generation: leased)
        _ = try activateCatalogGeneration(
            store,
            generationID: "generation-c",
            uniquePayload: "unique-c"
        )
        try Data("quarantined".utf8).write(
            to: store.quarantineDirectory.appendingPathComponent("seeded-entry")
        )
        let collection = try store.collectGarbage()
        #expect(collection.generationsRemoved == 1)
        #expect(collection.quarantineEntriesRemoved == 1)
        #expect(try store.catalogConsistencyReport() == .consistent)
        let incrementalDump = try store.canonicalCatalogDump()
        #expect(incrementalDump.hasSuffix("\n"))
        #expect(try store.canonicalCatalogDump() == incrementalDump)

        try FileManager.default.removeItem(at: store.catalogURL)
        let reopened = try ContentStore(root: root)
        #expect(try reopened.catalogConsistencyReport() == .consistent)
        #expect(try reopened.canonicalCatalogDump() == incrementalDump)

        #expect(try reopened.rebuildCatalog().action == .rebuilt)
        #expect(try reopened.canonicalCatalogDump() == incrementalDump)
    }
}

@Test("a caller-visible generation whose name ends in staging is indexed")
func catalogIndexesCallerVisibleStagingSuffix() throws {
    try withCatalogStore { root, store in
        let generation = try activateCatalogGeneration(
            store,
            generationID: ".release.staging",
            uniquePayload: "release"
        )

        #expect(generation.generationID == ".release.staging")
        #expect(try store.catalogConsistencyReport() == .consistent)
        #expect(try store.catalogInventory().generationCount == 1)
        #expect(
            try store.canonicalCatalogDump()
                .contains(#""generationId":".release.staging""#)
        )

        let reopened = try ContentStore(root: root)
        #expect(try reopened.catalogConsistencyReport() == .consistent)
        #expect(try reopened.catalogInventory().generationCount == 1)
    }
}

@Test("unknown reference and lease entries fail catalog scanning closed")
func catalogRejectsUnknownReferenceAndLeaseEntries() throws {
    try withCatalogStore { _, store in
        _ = try activateCatalogGeneration(
            store,
            generationID: "generation-a",
            uniquePayload: "unique-a"
        )
        let unknownReference = store.referencesDirectory
            .appendingPathComponent("game", isDirectory: true)
            .appendingPathComponent("unknown.json")
        try Data("unknown".utf8).write(to: unknownReference)

        #expect(catalogScanRejectsEntry(store, named: "unknown.json"))
    }

    try withCatalogStore { _, store in
        let unknownLease = store.leasesDirectory.appendingPathComponent("README")
        try Data("unknown".utf8).write(to: unknownLease)

        #expect(catalogScanRejectsEntry(store, named: "README"))
    }
}

@Test("consistency checker reports the exact catalog-ahead and disk-ahead rows")
func catalogConsistencyReportsExactBothDirections() throws {
    try withCatalogStore { root, store in
        _ = try activateCatalogGeneration(
            store,
            generationID: "generation-a",
            uniquePayload: "unique-a"
        )
        #expect(try store.catalogConsistencyReport() == .consistent)

        let baselineInventory = try store.catalogInventory()
        let catalogOnlyObject = CatalogObjectRecord(
            digest: "sha256:\(String(repeating: "f", count: 64))",
            size: 1,
            refCount: 0
        )
        try insertCatalogOnlyObject(catalogOnlyObject, in: store)
        let diskOnlyObject = try installCatalogDiskOnlyObject(
            Data("disk-only-catalog-object".utf8),
            in: store
        )
        let diskInventory = CatalogInventory(
            objectCount: baselineInventory.objectCount + 1,
            objectBytes: baselineInventory.objectBytes + UInt64(diskOnlyObject.size),
            objectReferenceCount: baselineInventory.objectReferenceCount,
            generationCount: baselineInventory.generationCount,
            referenceCount: baselineInventory.referenceCount,
            leaseCount: baselineInventory.leaseCount
        )
        let expected = CatalogConsistencyReport(
            catalogAhead: [
                try catalogRecordLine("object", value: catalogOnlyObject, store: store),
                try catalogRecordLine("inventory", value: baselineInventory, store: store)
            ],
            diskAhead: [
                try catalogRecordLine("object", value: diskOnlyObject, store: store),
                try catalogRecordLine("inventory", value: diskInventory, store: store)
            ]
        )
        #expect(try store.catalogConsistencyReport() == expected)

        let reopened = try ContentStore(root: root)
        #expect(try reopened.catalogConsistencyReport() == .consistent)
        let repairedDump = try reopened.canonicalCatalogDump()
        _ = try reopened.rebuildCatalog()
        #expect(try reopened.canonicalCatalogDump() == repairedDump)
    }
}

@Test(
    "catalog maintenance recovers at every transaction boundary",
    arguments: ContentStore.catalogMaintenanceFaultPoints
)
func catalogMaintenanceDeathRecovery(faultPoint: String) throws {
    try withCatalogStore { root, store in
        _ = try activateCatalogGeneration(
            store,
            generationID: "generation-a",
            uniquePayload: "unique-a"
        )
        _ = try installCatalogDiskOnlyObject(
            Data("fault-boundary-disk-object".utf8),
            in: store
        )
        #expect(try store.catalogConsistencyReport().diskAhead.count == 2)

        #expect(throws: ContentStoreError.injectedTermination(faultPoint)) {
            _ = try store.synchronizeCatalog { point in
                if point == faultPoint {
                    throw ContentStoreError.injectedTermination(point)
                }
            }
        }

        let reopened = try ContentStore(root: root)
        #expect(try reopened.catalogConsistencyReport() == .consistent)
        let recoveredDump = try reopened.canonicalCatalogDump()
        _ = try reopened.rebuildCatalog()
        #expect(try reopened.canonicalCatalogDump() == recoveredDump)
    }
}

@Test(
    "catalog replacement recovers at every transaction boundary",
    arguments: ContentStore.catalogMaintenanceFaultPoints
)
func catalogReplacementDeathRecovery(faultPoint: String) throws {
    try withCatalogStore { root, store in
        _ = try activateCatalogGeneration(
            store,
            generationID: "generation-a",
            uniquePayload: "unique-a"
        )
        let expectedDump = try store.canonicalCatalogDump()
        try FileManager.default.removeItem(at: store.catalogURL)

        #expect(throws: ContentStoreError.injectedTermination(faultPoint)) {
            _ = try store.synchronizeCatalog { point in
                if point == faultPoint {
                    throw ContentStoreError.injectedTermination(point)
                }
            }
        }

        let reopened = try ContentStore(root: root)
        #expect(try reopened.catalogConsistencyReport() == .consistent)
        #expect(try reopened.canonicalCatalogDump() == expectedDump)
    }
}

@Test("explicit recovery reconciles disk truth before returning")
func catalogRecoveryReconcilesAutomatically() throws {
    try withCatalogStore { _, store in
        _ = try activateCatalogGeneration(
            store,
            generationID: "generation-a",
            uniquePayload: "unique-a"
        )
        _ = try installCatalogDiskOnlyObject(
            Data("recovery-disk-object".utf8),
            in: store
        )
        #expect(try store.catalogConsistencyReport().diskAhead.count == 2)

        try store.recoverAll()
        #expect(try store.catalogConsistencyReport() == .consistent)
        #expect(try store.catalogInventory().objectCount == 3)
    }
}

extension SerializedTransportTests {
    @Test("transport publication maintains the catalog automatically")
    func transportPublicationMaintainsCatalog() throws {
        let payloadString = "catalog-transport-object"
        let payload = Data(payloadString.utf8)
        let descriptor = catalogLayer(
            payloadString,
            version: "transport"
        ).descriptor
        let fixture = try LoopbackHTTPFixture { _ in
            FixtureHTTPResponse(body: payload)
        }
        defer { fixture.stop() }

        try withCatalogStore { _, store in
            _ = try store.fetchObject(
                descriptor,
                from: [fixture.baseURL],
                operationID: "catalog-transport"
            )
            #expect(try store.catalogConsistencyReport() == .consistent)
            #expect(try store.catalogInventory() == CatalogInventory(
                objectCount: 1,
                objectBytes: UInt64(payload.count),
                objectReferenceCount: 0,
                generationCount: 0,
                referenceCount: 0,
                leaseCount: 0
            ))
        }
    }
}
