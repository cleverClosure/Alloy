// Author: Timur Isaev
// swiftlint:disable file_length

import CryptoKit
import Foundation

public enum InvalidationRecordError: Error, Equatable, Sendable {
  case invalidRecord(String)
  case unsupportedVersion(Int)
  case invalidField(String)
  case invalidSHA256(field: String, value: String)
  case unsortedArray(String)
  case duplicateArrayValue(field: String, value: String)
  case overlappingFilePath(String)
  case inconsistentMetadataFlag
  case inconsistentContentFlag
  case inconsistentDepotDelta
  case invalidInvalidationID(recorded: String, expected: String)
  case unknownField(String)
}

extension InvalidationRecordError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidRecord(let value):
      "invalid invalidation record discriminator: \(value)"
    case .unsupportedVersion(let value):
      "unsupported invalidation record version: \(value)"
    case .invalidField(let field):
      "invalid invalidation field: \(field)"
    case .invalidSHA256(let field, let value):
      "\(field) must be a lowercase SHA-256 digest: \(value)"
    case .unsortedArray(let field):
      "\(field) is not UTF-8 bytewise sorted"
    case .duplicateArrayValue(let field, let value):
      "\(field) contains duplicate value: \(value)"
    case .overlappingFilePath(let path):
      "file delta classes overlap at: \(path)"
    case .inconsistentMetadataFlag:
      "metadata_changed does not match the build identities"
    case .inconsistentContentFlag:
      "game_content_changed does not match the build identities and file deltas"
    case .inconsistentDepotDelta:
      "changed_depot_ids does not match the manifest maps"
    case .invalidInvalidationID(let recorded, let expected):
      "invalidation id \(recorded) does not match \(expected)"
    case .unknownField(let field):
      "unknown invalidation field: \(field)"
    }
  }
}

public struct InvalidationBuildIdentity: Codable, Equatable, Sendable {
  public let buildID: String
  public let manifestIDs: [String: String]
  public let aggregateSHA256: String

  public init(
    buildID: String,
    manifestIDs: [String: String],
    aggregateSHA256: String
  ) throws {
    guard StoreIdentityRecordValidation.isDecimal(buildID) else {
      throw InvalidationRecordError.invalidField("build_id")
    }
    guard !manifestIDs.isEmpty else {
      throw InvalidationRecordError.invalidField("manifest_ids")
    }
    for (depotID, manifestID) in manifestIDs {
      guard StoreIdentityRecordValidation.isDecimal(depotID),
        StoreIdentityRecordValidation.isDecimal(manifestID)
      else {
        throw InvalidationRecordError.invalidField(
          "manifest_ids[\(depotID)]"
        )
      }
    }
    guard StoreIdentityRecordValidation.isSHA256(aggregateSHA256) else {
      throw InvalidationRecordError.invalidSHA256(
        field: "aggregate_sha256",
        value: aggregateSHA256
      )
    }
    self.buildID = buildID
    self.manifestIDs = manifestIDs
    self.aggregateSHA256 = aggregateSHA256
  }

  public init(from decoder: any Decoder) throws {
    try rejectUnknownInvalidationFields(
      decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue))
    )
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      buildID: values.decode(String.self, forKey: .buildID),
      manifestIDs: values.decode([String: String].self, forKey: .manifestIDs),
      aggregateSHA256: values.decode(
        String.self,
        forKey: .aggregateSHA256
      )
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case buildID = "build_id"
    case manifestIDs = "manifest_ids"
    case aggregateSHA256 = "aggregate_sha256"
  }
}

public struct InvalidationRecord: Codable, Equatable, Sendable {
  public static let currentRecord = "alloy-store-identity-invalidation"
  public static let currentVersion = 1

  public let record: String
  public let version: Int
  public let invalidationID: String
  public let gameID: String
  public let storefront: String
  public let superseded: InvalidationBuildIdentity
  public let observed: InvalidationBuildIdentity
  public let metadataChanged: Bool
  public let gameContentChanged: Bool
  public let changedDepotIDs: [String]
  public let addedFilePaths: [String]
  public let removedFilePaths: [String]
  public let changedFilePaths: [String]
  public let selectorIDs: [String]

  // swiftlint:disable:next function_body_length
  public init(
    record: String,
    version: Int,
    invalidationID: String,
    gameID: String,
    storefront: String,
    superseded: InvalidationBuildIdentity,
    observed: InvalidationBuildIdentity,
    metadataChanged: Bool,
    gameContentChanged: Bool,
    changedDepotIDs: [String],
    addedFilePaths: [String],
    removedFilePaths: [String],
    changedFilePaths: [String],
    selectorIDs: [String]
  ) throws {
    try Self.validate(
      record: record,
      version: version,
      gameID: gameID,
      storefront: storefront,
      superseded: superseded,
      observed: observed,
      metadataChanged: metadataChanged,
      gameContentChanged: gameContentChanged,
      changedDepotIDs: changedDepotIDs,
      addedFilePaths: addedFilePaths,
      removedFilePaths: removedFilePaths,
      changedFilePaths: changedFilePaths,
      selectorIDs: selectorIDs
    )
    let expectedID = try Self.computeID(
      record: record,
      version: version,
      gameID: gameID,
      storefront: storefront,
      superseded: superseded,
      observed: observed,
      metadataChanged: metadataChanged,
      gameContentChanged: gameContentChanged,
      changedDepotIDs: changedDepotIDs,
      addedFilePaths: addedFilePaths,
      removedFilePaths: removedFilePaths,
      changedFilePaths: changedFilePaths,
      selectorIDs: selectorIDs
    )
    guard
      StoreIdentityRecordValidation.sameText(
        invalidationID,
        expectedID
      )
    else {
      throw InvalidationRecordError.invalidInvalidationID(
        recorded: invalidationID,
        expected: expectedID
      )
    }

    self.record = record
    self.version = version
    self.invalidationID = invalidationID
    self.gameID = gameID
    self.storefront = storefront
    self.superseded = superseded
    self.observed = observed
    self.metadataChanged = metadataChanged
    self.gameContentChanged = gameContentChanged
    self.changedDepotIDs = changedDepotIDs
    self.addedFilePaths = addedFilePaths
    self.removedFilePaths = removedFilePaths
    self.changedFilePaths = changedFilePaths
    self.selectorIDs = selectorIDs
  }

  // swiftlint:disable:next function_parameter_count
  public static func make(
    gameID: String,
    storefront: String,
    superseded: InvalidationBuildIdentity,
    observed: InvalidationBuildIdentity,
    metadataChanged: Bool,
    gameContentChanged: Bool,
    changedDepotIDs: [String],
    addedFilePaths: [String],
    removedFilePaths: [String],
    changedFilePaths: [String],
    selectorIDs: [String]
  ) throws -> InvalidationRecord {
    let invalidationID = try computeID(
      record: currentRecord,
      version: currentVersion,
      gameID: gameID,
      storefront: storefront,
      superseded: superseded,
      observed: observed,
      metadataChanged: metadataChanged,
      gameContentChanged: gameContentChanged,
      changedDepotIDs: changedDepotIDs,
      addedFilePaths: addedFilePaths,
      removedFilePaths: removedFilePaths,
      changedFilePaths: changedFilePaths,
      selectorIDs: selectorIDs
    )
    return try InvalidationRecord(
      record: currentRecord,
      version: currentVersion,
      invalidationID: invalidationID,
      gameID: gameID,
      storefront: storefront,
      superseded: superseded,
      observed: observed,
      metadataChanged: metadataChanged,
      gameContentChanged: gameContentChanged,
      changedDepotIDs: changedDepotIDs,
      addedFilePaths: addedFilePaths,
      removedFilePaths: removedFilePaths,
      changedFilePaths: changedFilePaths,
      selectorIDs: selectorIDs
    )
  }

  public init(from decoder: any Decoder) throws {
    try rejectUnknownInvalidationFields(
      decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue))
    )
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      record: values.decode(String.self, forKey: .record),
      version: values.decode(Int.self, forKey: .version),
      invalidationID: values.decode(String.self, forKey: .invalidationID),
      gameID: values.decode(String.self, forKey: .gameID),
      storefront: values.decode(String.self, forKey: .storefront),
      superseded: values.decode(
        InvalidationBuildIdentity.self,
        forKey: .superseded
      ),
      observed: values.decode(
        InvalidationBuildIdentity.self,
        forKey: .observed
      ),
      metadataChanged: values.decode(Bool.self, forKey: .metadataChanged),
      gameContentChanged: values.decode(
        Bool.self,
        forKey: .gameContentChanged
      ),
      changedDepotIDs: values.decode([String].self, forKey: .changedDepotIDs),
      addedFilePaths: values.decode([String].self, forKey: .addedFilePaths),
      removedFilePaths: values.decode([String].self, forKey: .removedFilePaths),
      changedFilePaths: values.decode([String].self, forKey: .changedFilePaths),
      selectorIDs: values.decode([String].self, forKey: .selectorIDs)
    )
  }

  public static func decode(_ data: Data) throws -> InvalidationRecord {
    try JSONDecoder().decode(InvalidationRecord.self, from: data)
  }

  public func canonicalJSON() throws -> Data {
    try StoreIdentityRecordValidation.canonicalJSON(self)
  }

  public var digestHex: String {
    String(invalidationID.dropFirst("sha256:".count))
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case record
    case version
    case invalidationID = "invalidation_id"
    case gameID = "game_id"
    case storefront
    case superseded
    case observed
    case metadataChanged = "metadata_changed"
    case gameContentChanged = "game_content_changed"
    case changedDepotIDs = "changed_depot_ids"
    case addedFilePaths = "added_file_paths"
    case removedFilePaths = "removed_file_paths"
    case changedFilePaths = "changed_file_paths"
    case selectorIDs = "selector_ids"
  }
}

extension InvalidationRecord {
  fileprivate struct Payload: Encodable {
    let record: String
    let version: Int
    let gameID: String
    let storefront: String
    let superseded: InvalidationBuildIdentity
    let observed: InvalidationBuildIdentity
    let metadataChanged: Bool
    let gameContentChanged: Bool
    let changedDepotIDs: [String]
    let addedFilePaths: [String]
    let removedFilePaths: [String]
    let changedFilePaths: [String]
    let selectorIDs: [String]

    // swiftlint:disable:next nesting
    private enum CodingKeys: String, CodingKey {
      case record
      case version
      case gameID = "game_id"
      case storefront
      case superseded
      case observed
      case metadataChanged = "metadata_changed"
      case gameContentChanged = "game_content_changed"
      case changedDepotIDs = "changed_depot_ids"
      case addedFilePaths = "added_file_paths"
      case removedFilePaths = "removed_file_paths"
      case changedFilePaths = "changed_file_paths"
      case selectorIDs = "selector_ids"
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length function_parameter_count
  fileprivate static func validate(
    record: String,
    version: Int,
    gameID: String,
    storefront: String,
    superseded: InvalidationBuildIdentity,
    observed: InvalidationBuildIdentity,
    metadataChanged: Bool,
    gameContentChanged: Bool,
    changedDepotIDs: [String],
    addedFilePaths: [String],
    removedFilePaths: [String],
    changedFilePaths: [String],
    selectorIDs: [String]
  ) throws {
    guard record == currentRecord else {
      throw InvalidationRecordError.invalidRecord(record)
    }
    guard version == currentVersion else {
      throw InvalidationRecordError.unsupportedVersion(version)
    }
    guard StoreIdentityRecordValidation.isDecimal(gameID) else {
      throw InvalidationRecordError.invalidField("game_id")
    }
    guard storefront == "steam" else {
      throw InvalidationRecordError.invalidField("storefront")
    }
    try validateSortedUnique(
      changedDepotIDs,
      field: "changed_depot_ids",
      elementIsValid: StoreIdentityRecordValidation.isDecimal
    )
    try validateSortedUnique(
      addedFilePaths,
      field: "added_file_paths",
      elementIsValid: StoreIdentityRecordValidation.isSafeRelativePath
    )
    try validateSortedUnique(
      removedFilePaths,
      field: "removed_file_paths",
      elementIsValid: StoreIdentityRecordValidation.isSafeRelativePath
    )
    try validateSortedUnique(
      changedFilePaths,
      field: "changed_file_paths",
      elementIsValid: StoreIdentityRecordValidation.isSafeRelativePath
    )
    guard !selectorIDs.isEmpty else {
      throw InvalidationRecordError.invalidField("selector_ids")
    }
    try validateSortedUnique(
      selectorIDs,
      field: "selector_ids",
      elementIsValid: StoreIdentityRecordValidation.isSelectorID
    )

    for path in addedFilePaths {
      let overlapsRemoved = removedFilePaths.contains(where: {
        StoreIdentityRecordValidation.sameText($0, path)
      })
      let overlapsChanged = changedFilePaths.contains(where: {
        StoreIdentityRecordValidation.sameText($0, path)
      })
      if overlapsRemoved || overlapsChanged {
        throw InvalidationRecordError.overlappingFilePath(path)
      }
    }
    for path in removedFilePaths
    where changedFilePaths.contains(where: {
      StoreIdentityRecordValidation.sameText($0, path)
    }) {
      throw InvalidationRecordError.overlappingFilePath(path)
    }

    let manifestsChanged = !sameManifestMap(
      superseded.manifestIDs,
      observed.manifestIDs
    )
    let expectedMetadataChanged =
      !StoreIdentityRecordValidation.sameText(
        superseded.buildID,
        observed.buildID
      ) || manifestsChanged
    guard metadataChanged == expectedMetadataChanged else {
      throw InvalidationRecordError.inconsistentMetadataFlag
    }
    let expectedDepotIDs = changedDepots(
      superseded.manifestIDs,
      observed.manifestIDs
    )
    guard exactArray(expectedDepotIDs, changedDepotIDs) else {
      throw InvalidationRecordError.inconsistentDepotDelta
    }

    let expectedContentChanged =
      !StoreIdentityRecordValidation.sameText(
        superseded.aggregateSHA256,
        observed.aggregateSHA256
      )
    guard gameContentChanged == expectedContentChanged else {
      throw InvalidationRecordError.inconsistentContentFlag
    }
    let fileDeltaCount =
      addedFilePaths.count + removedFilePaths.count + changedFilePaths.count
    guard
      (gameContentChanged && fileDeltaCount > 0)
        || (!gameContentChanged && fileDeltaCount == 0)
    else {
      throw InvalidationRecordError.inconsistentContentFlag
    }
    guard metadataChanged || gameContentChanged else {
      throw InvalidationRecordError.inconsistentContentFlag
    }
  }

  fileprivate static func validateSortedUnique(
    _ values: [String],
    field: String,
    elementIsValid: (String) -> Bool
  ) throws {
    var previous: String?
    for value in values {
      guard elementIsValid(value) else {
        throw InvalidationRecordError.invalidField(field)
      }
      if let previous {
        if StoreIdentityRecordValidation.sameText(previous, value) {
          throw InvalidationRecordError.duplicateArrayValue(
            field: field,
            value: value
          )
        }
        guard StoreIdentityRecordValidation.utf8Less(previous, value) else {
          throw InvalidationRecordError.unsortedArray(field)
        }
      }
      previous = value
    }
  }

  fileprivate static func changedDepots(
    _ left: [String: String],
    _ right: [String: String]
  ) -> [String] {
    Set(left.keys).union(right.keys)
      .filter { depotID in
        guard let leftID = left[depotID], let rightID = right[depotID] else {
          return true
        }
        return !StoreIdentityRecordValidation.sameText(leftID, rightID)
      }
      .sorted(by: StoreIdentityRecordValidation.utf8Less)
  }

  fileprivate static func sameManifestMap(
    _ left: [String: String],
    _ right: [String: String]
  ) -> Bool {
    guard left.count == right.count else {
      return false
    }
    return left.allSatisfy { key, value in
      guard let rightValue = right[key] else {
        return false
      }
      return StoreIdentityRecordValidation.sameText(value, rightValue)
    }
  }

  fileprivate static func exactArray(_ left: [String], _ right: [String]) -> Bool {
    left.count == right.count
      && zip(left, right).allSatisfy(StoreIdentityRecordValidation.sameText)
  }

  // swiftlint:disable:next function_parameter_count
  fileprivate static func computeID(
    record: String,
    version: Int,
    gameID: String,
    storefront: String,
    superseded: InvalidationBuildIdentity,
    observed: InvalidationBuildIdentity,
    metadataChanged: Bool,
    gameContentChanged: Bool,
    changedDepotIDs: [String],
    addedFilePaths: [String],
    removedFilePaths: [String],
    changedFilePaths: [String],
    selectorIDs: [String]
  ) throws -> String {
    let payload = Payload(
      record: record,
      version: version,
      gameID: gameID,
      storefront: storefront,
      superseded: superseded,
      observed: observed,
      metadataChanged: metadataChanged,
      gameContentChanged: gameContentChanged,
      changedDepotIDs: changedDepotIDs,
      addedFilePaths: addedFilePaths,
      removedFilePaths: removedFilePaths,
      changedFilePaths: changedFilePaths,
      selectorIDs: selectorIDs
    )
    let bytes = try StoreIdentityRecordValidation.canonicalJSON(payload)
    let digest = SHA256.hash(data: bytes)
    return "sha256:\(FingerprintValidation.hex(digest))"
  }
}

private func rejectUnknownInvalidationFields(
  _ decoder: any Decoder,
  allowed: Set<String>
) throws {
  if let unknown = try StoreIdentityAnyCodingKey.unknownField(
    decoder,
    allowed: allowed
  ) {
    throw InvalidationRecordError.unknownField(unknown)
  }
}
