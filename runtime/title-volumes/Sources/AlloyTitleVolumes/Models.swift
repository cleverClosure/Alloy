// Author: Timur Isaev

import CryptoKit
import Foundation

public enum VolumeError: Error, Equatable, Sendable {
    case invalidIdentifier
    case unsafePath
    case unsafeFile
    case corruptRegistry
    case unknownTitle
    case unknownVolume
    case quotaExceeded
    case integrityMismatch
    case conflict
    case busy
    case invalidPolicy
    case systemCall(String, Int32)
}

public enum VolumeKind: String, Codable, Sendable, CaseIterable {
    case saves, settings, cache, scratch
}

public struct VolumeQuotas: Codable, Equatable, Sendable {
    public var saves: Int64
    public var settings: Int64
    public var cache: Int64
    public var scratch: Int64

    public init(saves: Int64 = 4 << 30, settings: Int64 = 64 << 20,
                cache: Int64 = 8 << 30, scratch: Int64 = 1 << 30) {
        self.saves = saves
        self.settings = settings
        self.cache = cache
        self.scratch = scratch
    }

    func validate() throws {
        guard [saves, settings, cache, scratch].allSatisfy({ $0 > 0 && $0 <= 1 << 40 }) else {
            throw VolumeError.invalidPolicy
        }
    }
}

public struct BackupPolicy: Codable, Equatable, Sendable {
    public var periodicIntervalSeconds: Int64?
    public init(periodicIntervalSeconds: Int64? = nil) {
        self.periodicIntervalSeconds = periodicIntervalSeconds
    }
}

public struct VolumeRecord: Codable, Equatable, Sendable {
    public let id: String
    public let gameID: String
    public let kind: VolumeKind
    public let relativePath: String
    /// A settings revision, cache epoch, or session ID; never a runtime generation.
    public var generation: String?
    public let quota: Int64
    public let backupPolicy: BackupPolicy
    public var expiresAt: Int64?
}

struct TitleRecord: Codable {
    let gameID: String
    let quotas: VolumeQuotas
    var volumes: [VolumeRecord]
}

struct Registry: Codable {
    var schemaVersion = 1
    var revision: UInt64 = 0
    var titles: [TitleRecord] = []
}

struct SessionLease {
    let record: VolumeRecord
    let scratch: Int32
    let writer: Int32
}

struct CheckedDocument: Codable {
    let payload: Data
    let sha256: String
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func checked<T: Encodable>(_ value: T) throws -> Data {
    let payload = try encoded(value)
    return try encoded(CheckedDocument(payload: payload, sha256: digest(payload)))
}

func decodeChecked<T: Decodable>(_ type: T.Type, _ bytes: Data) throws -> T {
    do {
        let document = try JSONDecoder().decode(CheckedDocument.self, from: bytes)
        guard digest(document.payload) == document.sha256 else { throw VolumeError.integrityMismatch }
        return try JSONDecoder().decode(type, from: document.payload)
    } catch { throw VolumeError.integrityMismatch }
}

func identifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 128, value != ".", value != "..",
          value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0)
              || [45, 46, 95].contains($0) }), !value.hasPrefix(".") else {
        throw VolumeError.invalidIdentifier
    }
}

func caseKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive],
                                                        locale: Locale(identifier: "en_US_POSIX"))
}

func relativeComponents(_ path: String) throws -> [String] {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty, parts.count <= 32, path.utf8.count <= 2048 else { throw VolumeError.unsafePath }
    for part in parts {
        guard !part.isEmpty, part != ".", part != "..", part.utf8.count <= 240,
              part == part.precomposedStringWithCanonicalMapping,
              !part.hasSuffix("."), !part.hasSuffix(" "),
              !part.unicodeScalars.contains(where: { $0.value < 32 || "\\:*?\"<>|".unicodeScalars.contains($0) })
        else { throw VolumeError.unsafePath }
        let stem = part.split(separator: ".")[0].uppercased()
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        guard !reserved.contains(stem) else { throw VolumeError.unsafePath }
    }
    return parts
}
