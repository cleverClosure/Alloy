// Author: Timur Isaev
import CryptoKit
import Foundation

public struct ClientIntent: Codable, Equatable, Sendable {
    public let namespace: String
    public let slot: String
    public let method: String
    public let key: String
    public let identifier: String?
}

public struct ClientJournal: Codable, Sendable {
    public var intents: [ClientIntent] = []
    public var cursors: [String: [String: Int]] = [:]
    public var cached: [String: CachedServiceSnapshot]?
    public init() {}

    public func intent(namespace: String, slot: String) -> ClientIntent? {
        intents.first { $0.namespace == namespace && $0.slot == slot }
    }

    public mutating func reserve(namespace: String, slot: String, method: String,
                                 identifier: String?) throws -> ClientIntent {
        if let existing = intent(namespace: namespace, slot: slot) {
            guard existing.method == method, existing.identifier == identifier else {
                throw ClientServiceError.invalidResponse
            }
            return existing
        }
        guard intents.count < 1_000 else { throw ClientServiceError.invalidResponse }
        let result = ClientIntent(namespace: namespace, slot: slot, method: method,
                                  key: UUID().uuidString, identifier: identifier)
        intents.append(result)
        return result
    }

    public static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
