// Author: Timur Isaev

import CryptoKit
import Foundation

public enum FingerprintError: Error, Equatable, Sendable {
  case invalidRecord(String)
  case unsupportedVersion(Int)
  case invalidDecimal(field: String, value: String)
  case invalidSHA256(field: String, value: String)
  case unknownField(String)
  case unsafeRelativePath(String)
  case duplicateFilePath(String)
  case unsortedFilePaths(previous: String, current: String)
  case fileCountMismatch(recorded: Int, actual: Int)
  case totalBytesMismatch(recorded: UInt64, actual: UInt64)
  case aggregateMismatch(recorded: String, actual: String)
  case sizeOverflow
  case installRootNotDirectory(String)
  case scanChanged(String)
  case fileSystem(path: String, operation: String, code: Int32)
  case inputOutput(path: String, operation: String)
}

extension FingerprintError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidRecord(let value):
      "invalid fingerprint record discriminator: \(value)"
    case .unsupportedVersion(let value):
      "unsupported fingerprint version: \(value)"
    case .invalidDecimal(let field, let value):
      "\(field) must be a nonempty ASCII decimal string: \(value)"
    case .invalidSHA256(let field, let value):
      "\(field) must be a lowercase SHA-256 digest: \(value)"
    case .unknownField(let field):
      "unknown fingerprint field: \(field)"
    case .unsafeRelativePath(let path):
      "unsafe fingerprint relative path: \(path)"
    case .duplicateFilePath(let path):
      "duplicate fingerprint file path: \(path)"
    case .unsortedFilePaths(let previous, let current):
      "fingerprint files are not UTF-8 bytewise sorted: \(previous), \(current)"
    case .fileCountMismatch(let recorded, let actual):
      "fingerprint file_count is \(recorded), expected \(actual)"
    case .totalBytesMismatch(let recorded, let actual):
      "fingerprint total_bytes is \(recorded), expected \(actual)"
    case .aggregateMismatch(let recorded, let actual):
      "fingerprint aggregate is \(recorded), expected \(actual)"
    case .sizeOverflow:
      "fingerprint byte total exceeds UInt64"
    case .installRootNotDirectory(let path):
      "fingerprint install root is not a directory: \(path)"
    case .scanChanged(let path):
      "install changed while fingerprinting: \(path)"
    case .fileSystem(let path, let operation, let code):
      "\(operation) failed for \(path) with errno \(code)"
    case .inputOutput(let path, let operation):
      "\(operation) failed for \(path)"
    }
  }
}

public struct FingerprintFileRecord: Codable, Equatable, Sendable {
  public let path: String
  public let size: UInt64
  public let sha256: String

  public init(path: String, size: UInt64, sha256: String) throws {
    try FingerprintValidation.validateRelativePath(path)
    try FingerprintValidation.validateSHA256(sha256, field: "files[].sha256")
    self.path = path
    self.size = size
    self.sha256 = sha256
  }

  public init(from decoder: any Decoder) throws {
    try FingerprintValidation.rejectUnknownKeys(
      decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue))
    )
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      path: values.decode(String.self, forKey: .path),
      size: values.decode(UInt64.self, forKey: .size),
      sha256: values.decode(String.self, forKey: .sha256)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case path
    case size
    case sha256
  }
}

public struct FingerprintDepotRecord: Codable, Equatable, Sendable {
  public let manifest: String
  public let size: String

  public init(manifest: String, size: String) throws {
    try FingerprintValidation.validateDecimal(manifest, field: "depots[].manifest")
    try FingerprintValidation.validateDecimal(size, field: "depots[].size")
    self.manifest = manifest
    self.size = size
  }

  public init(from decoder: any Decoder) throws {
    try FingerprintValidation.rejectUnknownKeys(
      decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue))
    )
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      manifest: values.decode(String.self, forKey: .manifest),
      size: values.decode(String.self, forKey: .size)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case manifest
    case size
  }
}

public struct FingerprintIdentity: Codable, Equatable, Sendable {
  public let appID: String
  public let name: String
  public let buildID: String
  public let depots: [String: FingerprintDepotRecord]

  public init(
    appID: String,
    name: String,
    buildID: String,
    depots: [String: FingerprintDepotRecord]
  ) throws {
    try FingerprintValidation.validateDecimal(appID, field: "appid")
    try FingerprintValidation.validateDecimal(buildID, field: "buildid")
    guard !name.isEmpty else {
      throw FingerprintError.invalidRecord("name must not be empty")
    }
    guard !depots.isEmpty else {
      throw FingerprintError.invalidRecord("depots must not be empty")
    }
    for depotID in depots.keys {
      try FingerprintValidation.validateDecimal(depotID, field: "depots key")
    }
    self.appID = appID
    self.name = name
    self.buildID = buildID
    self.depots = depots
  }

  public init(from decoder: any Decoder) throws {
    try FingerprintValidation.rejectUnknownKeys(
      decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue))
    )
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      appID: values.decode(String.self, forKey: .appID),
      name: values.decode(String.self, forKey: .name),
      buildID: values.decode(String.self, forKey: .buildID),
      depots: values.decode(
        [String: FingerprintDepotRecord].self,
        forKey: .depots
      )
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case appID = "appid"
    case name
    case buildID = "buildid"
    case depots
  }
}

public struct FingerprintRecord: Codable, Equatable, Sendable {
  public static let currentRecord = "alloy-store-001-fingerprint"
  public static let currentVersion = 1

  public let record: String
  public let version: Int
  public let appID: String
  public let name: String
  public let buildID: String
  public let depots: [String: FingerprintDepotRecord]
  public let fileCount: Int
  public let totalBytes: UInt64
  public let aggregateSHA256: String
  public let files: [FingerprintFileRecord]

  public init(
    record: String,
    version: Int,
    appID: String,
    name: String,
    buildID: String,
    depots: [String: FingerprintDepotRecord],
    fileCount: Int,
    totalBytes: UInt64,
    aggregateSHA256: String,
    files: [FingerprintFileRecord]
  ) throws {
    guard record == Self.currentRecord else {
      throw FingerprintError.invalidRecord(record)
    }
    guard version == Self.currentVersion else {
      throw FingerprintError.unsupportedVersion(version)
    }
    _ = try FingerprintIdentity(
      appID: appID,
      name: name,
      buildID: buildID,
      depots: depots
    )
    try FingerprintValidation.validateFiles(files)
    guard fileCount == files.count else {
      throw FingerprintError.fileCountMismatch(
        recorded: fileCount,
        actual: files.count
      )
    }
    let actualTotal = try FingerprintValidation.totalBytes(files)
    guard totalBytes == actualTotal else {
      throw FingerprintError.totalBytesMismatch(
        recorded: totalBytes,
        actual: actualTotal
      )
    }
    try FingerprintValidation.validateSHA256(
      aggregateSHA256,
      field: "aggregate_sha256"
    )
    let actualAggregate = FingerprintValidation.aggregateSHA256(files)
    guard aggregateSHA256 == actualAggregate else {
      throw FingerprintError.aggregateMismatch(
        recorded: aggregateSHA256,
        actual: actualAggregate
      )
    }

    self.record = record
    self.version = version
    self.appID = appID
    self.name = name
    self.buildID = buildID
    self.depots = depots
    self.fileCount = fileCount
    self.totalBytes = totalBytes
    self.aggregateSHA256 = aggregateSHA256
    self.files = files
  }

  public init(
    identity: FingerprintIdentity,
    files: [FingerprintFileRecord]
  ) throws {
    try FingerprintValidation.validateFiles(files)
    let totalBytes = try FingerprintValidation.totalBytes(files)
    try self.init(
      record: Self.currentRecord,
      version: Self.currentVersion,
      appID: identity.appID,
      name: identity.name,
      buildID: identity.buildID,
      depots: identity.depots,
      fileCount: files.count,
      totalBytes: totalBytes,
      aggregateSHA256: FingerprintValidation.aggregateSHA256(files),
      files: files
    )
  }

  public init(from decoder: any Decoder) throws {
    try FingerprintValidation.rejectUnknownKeys(
      decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue))
    )
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      record: values.decode(String.self, forKey: .record),
      version: values.decode(Int.self, forKey: .version),
      appID: values.decode(String.self, forKey: .appID),
      name: values.decode(String.self, forKey: .name),
      buildID: values.decode(String.self, forKey: .buildID),
      depots: values.decode(
        [String: FingerprintDepotRecord].self,
        forKey: .depots
      ),
      fileCount: values.decode(Int.self, forKey: .fileCount),
      totalBytes: values.decode(UInt64.self, forKey: .totalBytes),
      aggregateSHA256: values.decode(String.self, forKey: .aggregateSHA256),
      files: values.decode([FingerprintFileRecord].self, forKey: .files)
    )
  }

  public func canonicalJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(self)
    data.append(0x0A)
    return data
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case record
    case version
    case appID = "appid"
    case name
    case buildID = "buildid"
    case depots
    case fileCount = "file_count"
    case totalBytes = "total_bytes"
    case aggregateSHA256 = "aggregate_sha256"
    case files
  }
}

enum FingerprintValidation {
  static func validateDecimal(_ value: String, field: String) throws {
    guard !value.isEmpty,
      value.utf8.allSatisfy({ byte in
        byte >= 48 && byte <= 57
      })
    else {
      throw FingerprintError.invalidDecimal(field: field, value: value)
    }
  }

  static func validateSHA256(_ value: String, field: String) throws {
    guard value.utf8.count == 64,
      value.utf8.allSatisfy({ byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
      })
    else {
      throw FingerprintError.invalidSHA256(field: field, value: value)
    }
  }

  static func validateRelativePath(_ path: String) throws {
    let bytes = path.utf8
    guard !bytes.isEmpty,
      bytes.first != 0x2F,
      !bytes.contains(0x00)
    else {
      throw FingerprintError.unsafeRelativePath(path)
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw FingerprintError.unsafeRelativePath(path)
    }
  }

  static func validateFiles(_ files: [FingerprintFileRecord]) throws {
    var previous: FingerprintFileRecord?
    for file in files {
      try validateRelativePath(file.path)
      try validateSHA256(file.sha256, field: "files[].sha256")
      if let previous {
        if previous.path == file.path {
          throw FingerprintError.duplicateFilePath(file.path)
        }
        guard utf8Less(previous.path, file.path) else {
          throw FingerprintError.unsortedFilePaths(
            previous: previous.path,
            current: file.path
          )
        }
      }
      previous = file
    }
  }

  static func totalBytes(_ files: [FingerprintFileRecord]) throws -> UInt64 {
    try files.reduce(into: UInt64.zero) { result, file in
      let (sum, overflow) = result.addingReportingOverflow(file.size)
      guard !overflow else {
        throw FingerprintError.sizeOverflow
      }
      result = sum
    }
  }

  static func aggregateSHA256(_ files: [FingerprintFileRecord]) -> String {
    var aggregate = SHA256()
    for file in files {
      aggregate.update(data: Data(file.path.utf8))
      aggregate.update(data: Data([0x00]))
      aggregate.update(data: Data(String(file.size).utf8))
      aggregate.update(data: Data([0x00]))
      aggregate.update(data: Data(file.sha256.utf8))
      aggregate.update(data: Data([0x0A]))
    }
    return hex(aggregate.finalize())
  }

  static func utf8Less(_ left: String, _ right: String) -> Bool {
    left.utf8.lexicographicallyPrecedes(right.utf8)
  }

  static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    let alphabet = Array("0123456789abcdef".utf8)
    var result = [UInt8]()
    result.reserveCapacity(64)
    for byte in bytes {
      result.append(alphabet[Int(byte >> 4)])
      result.append(alphabet[Int(byte & 0x0F)])
    }
    guard let encoded = String(bytes: result, encoding: .ascii) else {
      preconditionFailure("lowercase hexadecimal bytes must be valid ASCII")
    }
    return encoded
  }

  static func rejectUnknownKeys(
    _ decoder: any Decoder,
    allowed: Set<String>
  ) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let unknown = container.allKeys
      .map(\.stringValue)
      .filter({ !allowed.contains($0) })
      .min()
    if let unknown {
      throw FingerprintError.unknownField(unknown)
    }
  }

  private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      intValue = nil
    }

    init?(intValue: Int) {
      stringValue = String(intValue)
      self.intValue = intValue
    }
  }
}
