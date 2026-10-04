// Author: Timur Isaev
import AlloyContentStore
import AlloyStoreCatalog
import Foundation

public struct PageQuery: Codable, Sendable {
    public let limit: Int?
    public let cursor: String?
    public init(limit: Int = 100, cursor: String? = nil) { self.limit = limit; self.cursor = cursor }
}

public struct IdentifierRequest: Codable, Sendable {
    public let identifier: String
    public init(_ identifier: String) { self.identifier = identifier }
}

public struct KeyRequest: Codable, Sendable {
    public let key: String
    public init(_ key: String) { self.key = key }
}

public struct KeyedIdentifier: Codable, Sendable {
    public let identifier: String
    public let key: String
    public init(identifier: String, key: String) { self.identifier = identifier; self.key = key }
}

public struct InstallPlanRequest: Codable, Sendable {
    public let gameID: String
    public let installationID: String
    public let generationID: String
    public let layers: [LayerDescriptor]
    public let baseURLs: [URL]
    public init(gameID: String, installationID: String, generationID: String,
                layers: [LayerDescriptor], baseURLs: [URL]) {
        self.gameID = gameID
        self.installationID = installationID
        self.generationID = generationID
        self.layers = layers
        self.baseURLs = baseURLs
    }
}

public struct UninstallPlanRequest: Codable, Sendable {
    public let gameID: String
    public let installationID: String
    public init(gameID: String, installationID: String) { self.gameID = gameID; self.installationID = installationID }
}

public struct OperationCursor: Codable, Sendable {
    public let operationID: String
    public let nextIndex: Int
    public init(operationID: String, nextIndex: Int = 0) { self.operationID = operationID; self.nextIndex = nextIndex }
}

public struct SequencedOperationEvent: Codable, Sendable {
    public let index: Int
    public let event: OperationEvent
    public init(index: Int, event: OperationEvent) { self.index = index; self.event = event }
}

/// The snapshot is authoritative at revision; events are an ordered audit tail,
/// not patches to be applied over that newer snapshot.
public struct OperationUpdate: Codable, Sendable {
    public let snapshot: CatalogOperation
    public let revision: Int
    public let events: [SequencedOperationEvent]
    public let next: OperationCursor
    public let hasMore: Bool
    public let workerActive: Bool

    public init(snapshot: CatalogOperation, events: [SequencedOperationEvent], next: OperationCursor,
                hasMore: Bool, workerActive: Bool) {
        self.snapshot = snapshot
        revision = snapshot.events.count
        self.events = events
        self.next = next
        self.hasMore = hasMore
        self.workerActive = workerActive
    }
}

extension RuntimeClient {
    public func request<Input: Encodable, Output: Decodable>(
        _ method: String, _ input: Input, returning: Output.Type
    ) throws -> Output {
        try call(method, payload: RuntimeEncoding.encode(input)).decode(Output.self)
    }

    public func listGames(_ query: PageQuery = PageQuery()) throws -> CatalogPage {
        try request("catalog.list", query, returning: CatalogPage.self)
    }

    public func planInstall(_ input: InstallPlanRequest) throws -> InstallPlan {
        try request("install.plan", input, returning: InstallPlan.self)
    }

    public func startInstall(planID: String, key: String) throws -> CatalogOperation {
        try request("install.start", KeyedIdentifier(identifier: planID, key: key), returning: CatalogOperation.self)
    }

    public func operation(_ identifier: String) throws -> CatalogOperation {
        try request("operation.get", IdentifierRequest(identifier), returning: CatalogOperation.self)
    }

    public func updates(_ cursor: OperationCursor) throws -> OperationUpdate {
        try request("operation.updates", cursor, returning: OperationUpdate.self)
    }
}
