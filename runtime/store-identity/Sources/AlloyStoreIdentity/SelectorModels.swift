// Author: Timur Isaev

import Foundation

public enum SelectorRegistryError: Error, Equatable, Sendable {
  case invalidRecord(String)
  case unsupportedVersion(Int)
  case invalidAuthor(String)
  case invalidField(String)
  case invalidSHA256(field: String, value: String)
  case unsafeArtifactPath(String)
  case unsortedSelectors
  case duplicateSelectorID(String)
  case unknownField(String)
}

extension SelectorRegistryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidRecord(let value):
      "invalid selector registry record discriminator: \(value)"
    case .unsupportedVersion(let value):
      "unsupported selector registry version: \(value)"
    case .invalidAuthor(let value):
      "invalid selector registry author: \(value)"
    case .invalidField(let field):
      "invalid selector registry field: \(field)"
    case .invalidSHA256(let field, let value):
      "\(field) must be a lowercase SHA-256 digest: \(value)"
    case .unsafeArtifactPath(let path):
      "unsafe selector artifact path: \(path)"
    case .unsortedSelectors:
      "selector records are not UTF-8 bytewise sorted"
    case .duplicateSelectorID(let selectorID):
      "duplicate selector id: \(selectorID)"
    case .unknownField(let field):
      "unknown selector registry field: \(field)"
    }
  }
}

public struct EvidenceArtifact: Codable, Equatable, Sendable {
  public let kind: String
  public let path: String
  public let sha256: String

  public init(
    kind: String,
    path: String,
    sha256: String
  ) throws {
    let allowedKinds = Set(["fingerprint", "scene-measurement", "launch-policy"])
    guard allowedKinds.contains(kind) else {
      throw SelectorRegistryError.invalidField("artifact.kind")
    }
    guard StoreIdentityRecordValidation.isSafeRelativePath(path) else {
      throw SelectorRegistryError.unsafeArtifactPath(path)
    }
    guard StoreIdentityRecordValidation.isSHA256(sha256) else {
      throw SelectorRegistryError.invalidSHA256(
        field: "artifact.sha256",
        value: sha256
      )
    }
    self.kind = kind
    self.path = path
    self.sha256 = sha256
  }

  public init(from decoder: any Decoder) throws {
    try rejectUnknownSelectorFields(
      decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue))
    )
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      kind: values.decode(String.self, forKey: .kind),
      path: values.decode(String.self, forKey: .path),
      sha256: values.decode(String.self, forKey: .sha256)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case kind
    case path
    case sha256
  }
}

public struct BuildSelector: Codable, Equatable, Sendable {
  public static let anchoredImagePath =
    "The Life and Suffering of Sir Brante.exe"
  private static let launchImageAliases: Set<String> = [
    "executableSHA256", "processPolicies[].imageSHA256"
  ]

  public let selectorID: String
  public let artifact: EvidenceArtifact
  public let storefront: String
  public let gameID: String
  public let storeBuildID: String
  public let manifestIDs: [String: String]
  public let aggregateSHA256: String
  public let imageHashes: [String: String]

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  public init(
    selectorID: String,
    artifact: EvidenceArtifact,
    storefront: String,
    gameID: String,
    storeBuildID: String,
    manifestIDs: [String: String],
    aggregateSHA256: String,
    imageHashes: [String: String]
  ) throws {
    guard StoreIdentityRecordValidation.isSelectorID(selectorID) else {
      throw SelectorRegistryError.invalidField("selector_id")
    }
    guard storefront == "steam" else {
      throw SelectorRegistryError.invalidField("storefront")
    }
    guard StoreIdentityRecordValidation.isDecimal(gameID) else {
      throw SelectorRegistryError.invalidField("game_id")
    }
    guard StoreIdentityRecordValidation.isDecimal(storeBuildID) else {
      throw SelectorRegistryError.invalidField("store_build_id")
    }
    guard !manifestIDs.isEmpty else {
      throw SelectorRegistryError.invalidField("manifest_ids")
    }
    for (depotID, manifestID) in manifestIDs {
      guard StoreIdentityRecordValidation.isDecimal(depotID),
        StoreIdentityRecordValidation.isDecimal(manifestID)
      else {
        throw SelectorRegistryError.invalidField(
          "manifest_ids[\(depotID)]"
        )
      }
    }
    guard StoreIdentityRecordValidation.isSHA256(aggregateSHA256) else {
      throw SelectorRegistryError.invalidSHA256(
        field: "aggregate_sha256",
        value: aggregateSHA256
      )
    }
    let installedImageKeys = Set(imageHashes.keys).subtracting(Self.launchImageAliases)
    let requiredAliases = artifact.kind == "launch-policy" ? Self.launchImageAliases : []
    guard installedImageKeys.count == 1,
      let installedImagePath = installedImageKeys.first,
      StoreIdentityRecordValidation.isSafeRelativePath(installedImagePath),
      StoreIdentityRecordValidation.isSafeMapKey(installedImagePath),
      Set(imageHashes.keys) == installedImageKeys.union(requiredAliases)
    else {
      throw SelectorRegistryError.invalidField("image_hashes")
    }
    var commonImageDigest: String?
    for (key, digest) in imageHashes {
      guard StoreIdentityRecordValidation.isSafeMapKey(key) else {
        throw SelectorRegistryError.invalidField("image_hashes key")
      }
      guard StoreIdentityRecordValidation.isSHA256(digest) else {
        throw SelectorRegistryError.invalidSHA256(
          field: "image_hashes[\(key)]",
          value: digest
        )
      }
      if let commonImageDigest {
        guard
          StoreIdentityRecordValidation.sameText(
            commonImageDigest,
            digest
          )
        else {
          throw SelectorRegistryError.invalidField("image_hashes")
        }
      } else {
        commonImageDigest = digest
      }
    }

    self.selectorID = selectorID
    self.artifact = artifact
    self.storefront = storefront
    self.gameID = gameID
    self.storeBuildID = storeBuildID
    self.manifestIDs = manifestIDs
    self.aggregateSHA256 = aggregateSHA256
    self.imageHashes = imageHashes
  }

  public init(from decoder: any Decoder) throws {
    try rejectUnknownSelectorFields(
      decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue))
    )
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      selectorID: values.decode(String.self, forKey: .selectorID),
      artifact: values.decode(EvidenceArtifact.self, forKey: .artifact),
      storefront: values.decode(String.self, forKey: .storefront),
      gameID: values.decode(String.self, forKey: .gameID),
      storeBuildID: values.decode(String.self, forKey: .storeBuildID),
      manifestIDs: values.decode([String: String].self, forKey: .manifestIDs),
      aggregateSHA256: values.decode(
        String.self,
        forKey: .aggregateSHA256
      ),
      imageHashes: values.decode([String: String].self, forKey: .imageHashes)
    )
  }

  public func matches(
    _ fingerprint: FingerprintRecord,
    storefront expectedStorefront: String = "steam"
  ) -> Bool {
    guard
      StoreIdentityRecordValidation.sameText(
        storefront,
        expectedStorefront
      ),
      StoreIdentityRecordValidation.sameText(gameID, fingerprint.appID),
      StoreIdentityRecordValidation.sameText(
        storeBuildID,
        fingerprint.buildID
      ),
      StoreIdentityRecordValidation.sameText(
        aggregateSHA256,
        fingerprint.aggregateSHA256
      ),
      manifestIDs.count == fingerprint.depots.count
    else {
      return false
    }
    guard
      manifestIDs.allSatisfy({ depotID, manifestID in
        guard let depot = fingerprint.depots[depotID] else {
          return false
        }
        return StoreIdentityRecordValidation.sameText(
          manifestID,
          depot.manifest
        )
      })
    else {
      return false
    }
    guard
      let installedImagePath = imageHashes.keys.first(where: { !Self.launchImageAliases.contains($0) }),
      let image = fingerprint.files.first(where: {
        StoreIdentityRecordValidation.sameText($0.path, installedImagePath)
      })
    else {
      return false
    }
    return imageHashes.values.allSatisfy {
      StoreIdentityRecordValidation.sameText($0, image.sha256)
    }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case selectorID = "selector_id"
    case artifact
    case storefront
    case gameID = "game_id"
    case storeBuildID = "store_build_id"
    case manifestIDs = "manifest_ids"
    case aggregateSHA256 = "aggregate_sha256"
    case imageHashes = "image_hashes"
  }
}

public struct SelectorRegistry: Codable, Equatable, Sendable {
  public static let currentRecord = "alloy-store-identity-selector-registry"
  public static let currentVersion = 1
  public static let currentAuthor = "Timur Isaev"

  public let record: String
  public let version: Int
  public let author: String
  public let selectors: [BuildSelector]

  public init(
    record: String,
    version: Int,
    author: String,
    selectors: [BuildSelector]
  ) throws {
    guard record == Self.currentRecord else {
      throw SelectorRegistryError.invalidRecord(record)
    }
    guard version == Self.currentVersion else {
      throw SelectorRegistryError.unsupportedVersion(version)
    }
    guard author == Self.currentAuthor else {
      throw SelectorRegistryError.invalidAuthor(author)
    }
    guard !selectors.isEmpty else {
      throw SelectorRegistryError.invalidField("selectors")
    }
    var previousID: String?
    for selector in selectors {
      if let previousID {
        if StoreIdentityRecordValidation.sameText(
          previousID,
          selector.selectorID
        ) {
          throw SelectorRegistryError.duplicateSelectorID(selector.selectorID)
        }
        guard
          StoreIdentityRecordValidation.utf8Less(
            previousID,
            selector.selectorID
          )
        else {
          throw SelectorRegistryError.unsortedSelectors
        }
      }
      previousID = selector.selectorID
    }

    self.record = record
    self.version = version
    self.author = author
    self.selectors = selectors
  }

  public init(selectors: [BuildSelector]) throws {
    try self.init(
      record: Self.currentRecord,
      version: Self.currentVersion,
      author: Self.currentAuthor,
      selectors: selectors
    )
  }

  public init(from decoder: any Decoder) throws {
    try rejectUnknownSelectorFields(
      decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue))
    )
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      record: values.decode(String.self, forKey: .record),
      version: values.decode(Int.self, forKey: .version),
      author: values.decode(String.self, forKey: .author),
      selectors: values.decode([BuildSelector].self, forKey: .selectors)
    )
  }

  public static func decode(_ data: Data) throws -> SelectorRegistry {
    try JSONDecoder().decode(SelectorRegistry.self, from: data)
  }

  public func canonicalJSON() throws -> Data {
    try StoreIdentityRecordValidation.canonicalJSON(self)
  }

  public func matchingSelectors(
    for fingerprint: FingerprintRecord,
    storefront: String = "steam"
  ) -> [BuildSelector] {
    selectors.filter {
      $0.matches(fingerprint, storefront: storefront)
    }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case record
    case version
    case author
    case selectors
  }
}

enum StoreIdentityRecordValidation {
  static func isDecimal(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
  }

  static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  static func isIdentifier(_ value: String) -> Bool {
    guard let first = value.utf8.first,
      first >= 97 && first <= 122
    else {
      return false
    }
    return value.utf8.allSatisfy {
      ($0 >= 97 && $0 <= 122)
        || ($0 >= 48 && $0 <= 57)
        || $0 == 0x2D
        || $0 == 0x5F
    }
  }

  static func isSelectorID(_ value: String) -> Bool {
    guard value.utf8.count >= 3,
      value.utf8.count <= 128,
      let first = value.utf8.first,
      isLowercaseAlphanumeric(first)
    else {
      return false
    }
    return value.utf8.allSatisfy {
      isLowercaseAlphanumeric($0)
        || $0 == 0x2D
        || $0 == 0x2E
        || $0 == 0x5F
    }
  }

  static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty,
      path.utf8.first != 0x2F,
      !path.utf8.contains(0x00)
    else {
      return false
    }
    let components = path.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    return components.allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  static func isSafeMapKey(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.allSatisfy {
        $0.value >= 0x20 && $0.value != 0x7F
      }
  }

  static func sameText(_ left: String, _ right: String) -> Bool {
    left.utf8.elementsEqual(right.utf8)
  }

  static func utf8Less(_ left: String, _ right: String) -> Bool {
    left.utf8.lexicographicallyPrecedes(right.utf8)
  }

  static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
  }

  private static func isLowercaseAlphanumeric(_ byte: UInt8) -> Bool {
    (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
  }
}

private func rejectUnknownSelectorFields(
  _ decoder: any Decoder,
  allowed: Set<String>
) throws {
  if let unknown = try StoreIdentityAnyCodingKey.unknownField(
    decoder,
    allowed: allowed
  ) {
    throw SelectorRegistryError.unknownField(unknown)
  }
}

struct StoreIdentityAnyCodingKey: CodingKey {
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

  static func unknownField(
    _ decoder: any Decoder,
    allowed: Set<String>
  ) throws -> String? {
    let container = try decoder.container(keyedBy: StoreIdentityAnyCodingKey.self)
    return container.allKeys
      .map(\.stringValue)
      .filter { !allowed.contains($0) }
      .min()
  }
}
