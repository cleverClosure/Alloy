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
    case contentLengthMismatch(expected: Int, actual: Int)
    case deadlineExceeded
    case digestMismatch(expected: String, actual: String)
    case httpStatus(url: String, statusCode: Int)
    case invalidBaseURL(String)
    case invalidPartialFile(String)
    case invalidRangeResponse(String)
    case invalidRecord(String)
    case invalidResumeOffset(expected: Int, actual: Int)
    case noBaseURLs
    case redirectLimitExceeded(limit: Int)
    case requestFailed(url: String, reason: String)
    case responseTooLarge(limit: Int)
    case sizeMismatch(expected: Int, actual: Int)
    case truncatedBody(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case let .allMirrorsFailed(failures):
            "all content mirrors failed: \(failures.joined(separator: "; "))"
        case let .contentLengthMismatch(expected, actual):
            "content length mismatch: expected \(expected), got \(actual)"
        case .deadlineExceeded:
            "content download exceeded its deadline"
        case let .digestMismatch(expected, actual):
            "download digest mismatch: expected \(expected), got \(actual)"
        case let .httpStatus(url, statusCode):
            "content mirror \(url) returned HTTP \(statusCode)"
        case let .invalidBaseURL(url):
            "invalid content mirror base URL: \(url)"
        case let .invalidPartialFile(path):
            "invalid partial-download file: \(path)"
        case let .invalidRangeResponse(reason):
            "invalid HTTP range response: \(reason)"
        case let .invalidRecord(operationID):
            "invalid transport record: \(operationID)"
        case let .invalidResumeOffset(expected, actual):
            "invalid resume offset: expected \(expected) bytes on disk, got \(actual)"
        case .noBaseURLs:
            "at least one content mirror base URL is required"
        case let .redirectLimitExceeded(limit):
            "content download exceeded its \(limit)-redirect limit"
        case let .requestFailed(url, reason):
            "content request \(url) failed: \(reason)"
        case let .responseTooLarge(limit):
            "content response exceeded its declared \(limit)-byte limit"
        case let .sizeMismatch(expected, actual):
            "download size mismatch: expected \(expected), got \(actual)"
        case let .truncatedBody(expected, actual):
            "content response was truncated: expected \(expected) bytes, got \(actual)"
        }
    }
}

struct TransportStreamResult: Equatable, Sendable {
    let statusCode: Int
    let finalURL: URL
    let totalByteCount: Int
    let bytesTransferred: Int
    let resumedFromByteCount: Int
    let restartedFromZero: Bool
    let entityTag: String?
    let lastModified: String?
}

struct TransportStreamRequest: Equatable, Sendable {
    let sourceURL: URL
    let partialURL: URL
    let expectedSize: Int
    let resumeFromByteCount: Int
    let idleTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let redirectLimit: Int
    let entityValidator: String?

    var isValid: Bool {
        expectedSize >= 0
            && resumeFromByteCount >= 0
            && resumeFromByteCount <= expectedSize
            && idleTimeout > 0
            && idleTimeout.isFinite
            && resourceTimeout > 0
            && resourceTimeout.isFinite
            && redirectLimit >= 0
    }

    var urlRequest: URLRequest {
        var request = URLRequest(url: sourceURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if resumeFromByteCount > 0 {
            request.setValue(
                "bytes=\(resumeFromByteCount)-",
                forHTTPHeaderField: "Range"
            )
            if let entityValidator {
                request.setValue(entityValidator, forHTTPHeaderField: "If-Range")
            }
        }
        return request
    }
}

struct TransportFetchContext: Sendable {
    let baseURLs: [URL]
    let deadline: TimeInterval
    let redirectLimit: Int
    let faultInjector: FaultInjector?
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
