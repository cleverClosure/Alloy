// Author: Timur Isaev

import Foundation

private struct SteamIdentityFields {
  let appID: String
  let name: String
  let installDirectory: String
  let buildID: String
}

public enum SteamMetadataError: Error, Equatable, Sendable {
  case inputTooLarge(sourceName: String, actual: Int, maximum: Int)
  case invalidUTF8(sourceName: String)
  case truncatedInput(sourceName: String, offset: Int)
  case malformedNesting(sourceName: String, offset: Int)
  case nestingTooDeep(sourceName: String, offset: Int, maximum: Int)
  case tokenTooLarge(sourceName: String, offset: Int, maximum: Int)
  case duplicateKey(sourceName: String, key: String, offset: Int)
  case invalidUnsignedInteger(sourceName: String, field: String, value: String)
  case sizeOverflow(sourceName: String, field: String, value: String)
}

extension SteamMetadataError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .inputTooLarge(let sourceName, let actual, let maximum):
      "\(sourceName): input is \(actual) bytes; maximum is \(maximum)"
    case .invalidUTF8(let sourceName):
      "\(sourceName): input is not valid UTF-8"
    case .truncatedInput(let sourceName, let offset):
      "\(sourceName): input is truncated at byte \(offset)"
    case .malformedNesting(let sourceName, let offset):
      "\(sourceName): malformed VDF structure at byte \(offset)"
    case .nestingTooDeep(let sourceName, let offset, let maximum):
      "\(sourceName): VDF nesting exceeds \(maximum) at byte \(offset)"
    case .tokenTooLarge(let sourceName, let offset, let maximum):
      "\(sourceName): quoted token exceeds \(maximum) bytes at byte \(offset)"
    case .duplicateKey(let sourceName, let key, let offset):
      "\(sourceName): duplicate VDF key \(key) at byte \(offset)"
    case .invalidUnsignedInteger(let sourceName, let field, let value):
      "\(sourceName): \(field) is not an unsigned decimal integer: \(value)"
    case .sizeOverflow(let sourceName, let field, let value):
      "\(sourceName): \(field) exceeds UInt64: \(value)"
    }
  }
}

public struct SteamDepotManifest: Equatable, Sendable {
  public let manifestID: String
  public let size: UInt64
  public let sizeText: String

  fileprivate init(manifestID: String, size: UInt64, sizeText: String) {
    self.manifestID = manifestID
    self.size = size
    self.sizeText = sizeText
  }
}

public struct SteamAppManifest: Equatable, Sendable {
  public let appID: String
  public let name: String
  public let installDirectory: String
  public let buildID: String
  public let sizeOnDisk: UInt64
  public let sizeOnDiskText: String
  public let installedDepots: [String: SteamDepotManifest]

  fileprivate init(
    appID: String,
    name: String,
    installDirectory: String,
    buildID: String,
    sizeOnDisk: UInt64,
    sizeOnDiskText: String,
    installedDepots: [String: SteamDepotManifest]
  ) {
    self.appID = appID
    self.name = name
    self.installDirectory = installDirectory
    self.buildID = buildID
    self.sizeOnDisk = sizeOnDisk
    self.sizeOnDiskText = sizeOnDiskText
    self.installedDepots = installedDepots
  }

  public func fingerprintIdentity() throws -> FingerprintIdentity {
    var depots = [String: FingerprintDepotRecord]()
    depots.reserveCapacity(installedDepots.count)
    for (depotID, depot) in installedDepots {
      depots[depotID] = try FingerprintDepotRecord(
        manifest: depot.manifestID,
        size: depot.sizeText
      )
    }
    return try FingerprintIdentity(
      appID: appID,
      name: name,
      buildID: buildID,
      depots: depots
    )
  }
}

public enum SteamMetadataParser {
  public static let maximumInputBytes = 8 * 1_024 * 1_024
  public static let maximumNestingDepth = 64
  public static let maximumTokenBytes = 1 * 1_024 * 1_024

  public static func parse(
    data: Data,
    sourceName: String
  ) throws -> SteamAppManifest {
    guard data.count <= maximumInputBytes else {
      throw SteamMetadataError.inputTooLarge(
        sourceName: sourceName,
        actual: data.count,
        maximum: maximumInputBytes
      )
    }
    guard String(data: data, encoding: .utf8) != nil else {
      throw SteamMetadataError.invalidUTF8(sourceName: sourceName)
    }

    var parser = VDFParser(
      bytes: Array(data),
      sourceName: sourceName,
      maximumDepth: maximumNestingDepth,
      maximumTokenBytes: maximumTokenBytes
    )
    let document = try parser.parseDocument()
    return try decodeManifest(
      document,
      sourceName: sourceName,
      offset: parser.offset
    )
  }
}

extension SteamMetadataParser {
  fileprivate static func decodeManifest(
    _ document: [String: VDFValue],
    sourceName: String,
    offset: Int
  ) throws -> SteamAppManifest {
    let appState = try requiredAppState(
      document,
      sourceName: sourceName,
      offset: offset
    )
    let identity = try decodeIdentityFields(
      appState,
      sourceName: sourceName,
      offset: offset
    )
    let sizeOnDiskText = try requiredString(
      "SizeOnDisk",
      in: appState,
      sourceName: sourceName,
      offset: offset
    )
    let depotObject = try requiredObject(
      "InstalledDepots",
      in: appState,
      sourceName: sourceName,
      offset: offset
    )
    let sizeOnDisk = try parseSize(
      sizeOnDiskText,
      field: "SizeOnDisk",
      sourceName: sourceName
    )
    let installedDepots = try decodeDepots(
      depotObject,
      sourceName: sourceName,
      offset: offset
    )

    return SteamAppManifest(
      appID: identity.appID,
      name: identity.name,
      installDirectory: identity.installDirectory,
      buildID: identity.buildID,
      sizeOnDisk: sizeOnDisk,
      sizeOnDiskText: sizeOnDiskText,
      installedDepots: installedDepots
    )
  }

  fileprivate static func requiredAppState(
    _ document: [String: VDFValue],
    sourceName: String,
    offset: Int
  ) throws -> [String: VDFValue] {
    guard document.count == 1,
      case .object(let appState)? = document["AppState"]
    else {
      throw SteamMetadataError.malformedNesting(
        sourceName: sourceName,
        offset: offset
      )
    }
    return appState
  }

  fileprivate static func decodeIdentityFields(
    _ appState: [String: VDFValue],
    sourceName: String,
    offset: Int
  ) throws -> SteamIdentityFields {
    let appID = try requiredString(
      "appid",
      in: appState,
      sourceName: sourceName,
      offset: offset
    )
    let name = try requiredString(
      "name",
      in: appState,
      sourceName: sourceName,
      offset: offset
    )
    let installDirectory = try requiredString(
      "installdir",
      in: appState,
      sourceName: sourceName,
      offset: offset
    )
    let buildID = try requiredString(
      "buildid",
      in: appState,
      sourceName: sourceName,
      offset: offset
    )
    try validateIdentifier(appID, field: "appid", sourceName: sourceName)
    try validateIdentifier(buildID, field: "buildid", sourceName: sourceName)
    guard !name.isEmpty, !installDirectory.isEmpty else {
      throw SteamMetadataError.malformedNesting(
        sourceName: sourceName,
        offset: offset
      )
    }
    return SteamIdentityFields(
      appID: appID,
      name: name,
      installDirectory: installDirectory,
      buildID: buildID
    )
  }

  fileprivate static func decodeDepots(
    _ object: [String: VDFValue],
    sourceName: String,
    offset: Int
  ) throws -> [String: SteamDepotManifest] {
    var depots = [String: SteamDepotManifest]()
    depots.reserveCapacity(object.count)
    for (depotID, value) in object {
      try validateIdentifier(
        depotID,
        field: "InstalledDepots key",
        sourceName: sourceName
      )
      depots[depotID] = try decodeDepot(
        value,
        depotID: depotID,
        sourceName: sourceName,
        offset: offset
      )
    }
    return depots
  }

  fileprivate static func decodeDepot(
    _ value: VDFValue,
    depotID: String,
    sourceName: String,
    offset: Int
  ) throws -> SteamDepotManifest {
    guard case .object(let depot) = value else {
      throw SteamMetadataError.malformedNesting(
        sourceName: sourceName,
        offset: offset
      )
    }
    let manifestID = try requiredString(
      "manifest",
      in: depot,
      sourceName: sourceName,
      offset: offset
    )
    let sizeText = try requiredString(
      "size",
      in: depot,
      sourceName: sourceName,
      offset: offset
    )
    try validateIdentifier(
      manifestID,
      field: "InstalledDepots[\(depotID)].manifest",
      sourceName: sourceName
    )
    let size = try parseSize(
      sizeText,
      field: "InstalledDepots[\(depotID)].size",
      sourceName: sourceName
    )
    return SteamDepotManifest(
      manifestID: manifestID,
      size: size,
      sizeText: sizeText
    )
  }

  fileprivate static func requiredString(
    _ key: String,
    in object: [String: VDFValue],
    sourceName: String,
    offset: Int
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw SteamMetadataError.malformedNesting(
        sourceName: sourceName,
        offset: offset
      )
    }
    return value
  }

  fileprivate static func requiredObject(
    _ key: String,
    in object: [String: VDFValue],
    sourceName: String,
    offset: Int
  ) throws -> [String: VDFValue] {
    guard case .object(let value)? = object[key] else {
      throw SteamMetadataError.malformedNesting(
        sourceName: sourceName,
        offset: offset
      )
    }
    return value
  }

  fileprivate static func validateIdentifier(
    _ value: String,
    field: String,
    sourceName: String
  ) throws {
    guard !value.isEmpty,
      value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
    else {
      throw SteamMetadataError.invalidUnsignedInteger(
        sourceName: sourceName,
        field: field,
        value: value
      )
    }
  }

  fileprivate static func parseSize(
    _ value: String,
    field: String,
    sourceName: String
  ) throws -> UInt64 {
    try validateIdentifier(value, field: field, sourceName: sourceName)
    guard let size = UInt64(value) else {
      throw SteamMetadataError.sizeOverflow(
        sourceName: sourceName,
        field: field,
        value: value
      )
    }
    return size
  }
}
