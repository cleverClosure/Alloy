// Author: Timur Isaev

import Foundation

public struct CatalogObjectRecord: Codable, Equatable, Sendable {
    public let digest: String
    public let size: Int
    public let refCount: Int

    public init(digest: String, size: Int, refCount: Int) {
        self.digest = digest
        self.size = size
        self.refCount = refCount
    }
}

public struct CatalogGenerationRecord: Codable, Equatable, Sendable {
    public let gameID: String
    public let generationID: String
    public let manifestDigest: String
    public let objectDigests: [String]

    public init(
        gameID: String,
        generationID: String,
        manifestDigest: String,
        objectDigests: [String]
    ) {
        self.gameID = gameID
        self.generationID = generationID
        self.manifestDigest = manifestDigest
        self.objectDigests = objectDigests
    }

    enum CodingKeys: String, CodingKey {
        case gameID = "gameId"
        case generationID = "generationId"
        case manifestDigest
        case objectDigests
    }
}

public struct CatalogReferenceRecord: Codable, Equatable, Sendable {
    public let gameID: String
    public let kind: String
    public let generationID: String
    public let manifestDigest: String

    public init(
        gameID: String,
        kind: String,
        generationID: String,
        manifestDigest: String
    ) {
        self.gameID = gameID
        self.kind = kind
        self.generationID = generationID
        self.manifestDigest = manifestDigest
    }

    enum CodingKeys: String, CodingKey {
        case gameID = "gameId"
        case kind
        case generationID = "generationId"
        case manifestDigest
    }
}

public struct CatalogLeaseRecord: Codable, Equatable, Sendable {
    public let leaseID: String
    public let gameID: String
    public let generationID: String
    public let manifestDigest: String
    public let objectDigests: [String]
    public let holder: LeaseProcessIdentity
    public let createdAtUnixSeconds: Int64

    public init(
        leaseID: String,
        gameID: String,
        generationID: String,
        manifestDigest: String,
        objectDigests: [String],
        holder: LeaseProcessIdentity,
        createdAtUnixSeconds: Int64
    ) {
        self.leaseID = leaseID
        self.gameID = gameID
        self.generationID = generationID
        self.manifestDigest = manifestDigest
        self.objectDigests = objectDigests
        self.holder = holder
        self.createdAtUnixSeconds = createdAtUnixSeconds
    }

    enum CodingKeys: String, CodingKey {
        case leaseID = "leaseId"
        case gameID = "gameId"
        case generationID = "generationId"
        case manifestDigest
        case objectDigests
        case holder
        case createdAtUnixSeconds
    }
}

public struct CatalogDump: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "1.0"

    public let schemaVersion: String
    public let objects: [CatalogObjectRecord]
    public let generations: [CatalogGenerationRecord]
    public let references: [CatalogReferenceRecord]
    public let leases: [CatalogLeaseRecord]
    public let inventory: CatalogInventory

    public init(
        objects: [CatalogObjectRecord],
        generations: [CatalogGenerationRecord],
        references: [CatalogReferenceRecord],
        leases: [CatalogLeaseRecord],
        inventory: CatalogInventory
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.objects = objects
        self.generations = generations
        self.references = references
        self.leases = leases
        self.inventory = inventory
    }
}

public struct CatalogInventory: Codable, Equatable, Sendable {
    public let objectCount: Int
    public let objectBytes: UInt64
    public let objectReferenceCount: Int
    public let generationCount: Int
    public let referenceCount: Int
    public let leaseCount: Int

    public init(
        objectCount: Int,
        objectBytes: UInt64,
        objectReferenceCount: Int,
        generationCount: Int,
        referenceCount: Int,
        leaseCount: Int
    ) {
        self.objectCount = objectCount
        self.objectBytes = objectBytes
        self.objectReferenceCount = objectReferenceCount
        self.generationCount = generationCount
        self.referenceCount = referenceCount
        self.leaseCount = leaseCount
    }
}

public struct CatalogConsistencyReport: Codable, Equatable, Sendable {
    public let catalogAhead: [String]
    public let diskAhead: [String]

    public init(catalogAhead: [String], diskAhead: [String]) {
        self.catalogAhead = catalogAhead.sorted()
        self.diskAhead = diskAhead.sorted()
    }

    public var divergenceCount: Int {
        catalogAhead.count + diskAhead.count
    }

    public var isConsistent: Bool {
        divergenceCount == 0
    }

    public static let consistent = CatalogConsistencyReport(
        catalogAhead: [],
        diskAhead: []
    )
}

public struct CatalogMaintenanceResult: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case unchanged
        case reconciled
        case rebuilt
    }

    public let action: Action
    public let repairedDivergenceCount: Int

    public init(action: Action, repairedDivergenceCount: Int) {
        self.action = action
        self.repairedDivergenceCount = repairedDivergenceCount
    }
}

public enum CatalogError: Error, CustomStringConvertible, Equatable {
    case catalogMissing
    case invalidCatalogValue(String)
    case invalidSchema(String)
    case sqlite(code: Int32, message: String)

    public var description: String {
        switch self {
        case .catalogMissing:
            "catalog file is missing"
        case let .invalidCatalogValue(value):
            "invalid catalog value: \(value)"
        case let .invalidSchema(reason):
            "invalid catalog schema: \(reason)"
        case let .sqlite(code, message):
            "SQLite error \(code): \(message)"
        }
    }
}
