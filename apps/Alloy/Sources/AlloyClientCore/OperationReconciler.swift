// Author: Timur Isaev
import AlloyRuntimeAPI
import Foundation

/// Service snapshots are authoritative. Events validate an audit cursor, never patch newer state.
public struct OperationReconciler: Sendable {
    public private(set) var values: [String: OperationUpdate] = [:]
    public init() {}

    public mutating func accept(_ update: OperationUpdate) throws {
        let identifier = update.snapshot.operationID
        guard update.next.operationID == identifier, update.revision == update.snapshot.events.count,
              update.next.nextIndex >= 0, update.next.nextIndex <= update.revision,
              update.hasMore == (update.next.nextIndex < update.revision) else {
            throw ClientServiceError.invalidResponse
        }
        let indices = update.events.map(\.index)
        let start = update.next.nextIndex - indices.count
        guard start >= 0, indices == Array(start..<update.next.nextIndex), update.events.allSatisfy({
            $0.index < update.revision && $0.event == update.snapshot.events[$0.index]
        }) else { throw ClientServiceError.invalidResponse }
        if let previous = values[identifier] {
            guard previous.snapshot.kind == update.snapshot.kind,
                  previous.snapshot.payloadDigest == update.snapshot.payloadDigest,
                  previous.snapshot.idempotencyKey == update.snapshot.idempotencyKey else {
                throw ClientServiceError.invalidResponse
            }
            if previous.revision > update.revision { return }
            if previous.revision == update.revision && previous.snapshot != update.snapshot {
                throw ClientServiceError.invalidResponse
            }
            if previous.snapshot.state.isTerminal && previous.snapshot.state != update.snapshot.state {
                throw ClientServiceError.invalidResponse
            }
        }
        values[identifier] = update
    }
}

public struct CachedServiceSnapshot: Codable, Sendable {
    public let games: [LibraryGame]
    public let activities: [ClientActivity]
    public let observedAt: Date
}
