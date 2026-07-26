// Author: Timur Isaev

import Foundation

public struct TransportResult: Equatable, Sendable {
    public let digest: String
    public let objectURL: URL
    public let sourceURL: URL?
    public let mirrorIndex: Int?
    public let bytesTransferred: Int
    public let resumedFromByteCount: Int
    public let reusedExistingObject: Bool

}

public enum ContentTransportError: Error, CustomStringConvertible, Equatable, Sendable {
    case allMirrorsFailed([String])
    case deadlineExceeded
    case digestMismatch(expected: String, actual: String)
    case httpStatus(url: String, statusCode: Int)
    case invalidBaseURL(String)
    case invalidRecord(String)
    case noBaseURLs
    case requestFailed(url: String, reason: String)
    case sizeMismatch(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case let .allMirrorsFailed(failures):
            "all content mirrors failed: \(failures.joined(separator: "; "))"
        case .deadlineExceeded:
            "content download exceeded its deadline"
        case let .digestMismatch(expected, actual):
            "download digest mismatch: expected \(expected), got \(actual)"
        case let .httpStatus(url, statusCode):
            "content mirror \(url) returned HTTP \(statusCode)"
        case let .invalidBaseURL(url):
            "invalid content mirror base URL: \(url)"
        case let .invalidRecord(operationID):
            "invalid transport record: \(operationID)"
        case .noBaseURLs:
            "at least one content mirror base URL is required"
        case let .requestFailed(url, reason):
            "content request \(url) failed: \(reason)"
        case let .sizeMismatch(expected, actual):
            "download size mismatch: expected \(expected), got \(actual)"
        }
    }
}

enum TransportState: String, Codable, Sendable {
    case downloading
    case downloaded
    case verified
    case published
}

struct TransportRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"
    static let kind = "fetch-object"

    let schemaVersion: String
    let kind: String
    let operationID: String
    let digest: String
    let expectedSize: Int
    let baseURLs: [String]
    var mirrorIndex: Int
    var sourceURL: String?
    var byteCount: Int
    var state: TransportState

    init(
        operationID: String,
        descriptor: LayerDescriptor,
        baseURLs: [URL]
    ) {
        schemaVersion = Self.currentSchemaVersion
        kind = Self.kind
        self.operationID = operationID
        digest = descriptor.digest
        expectedSize = descriptor.size
        self.baseURLs = baseURLs.map(\.absoluteString)
        mirrorIndex = 0
        sourceURL = nil
        byteCount = 0
        state = .downloading
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case operationID = "operationId"
        case digest
        case expectedSize
        case baseURLs = "baseUrls"
        case mirrorIndex
        case sourceURL = "sourceUrl"
        case byteCount
        case state
    }
}
