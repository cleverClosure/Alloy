// Author: Timur Isaev

import CryptoKit
import Foundation

public enum BundleError: Error, Equatable {
  case invalidInput
  case exceededLimit
  case destinationExists
  case invalidSeal
  case unsafeContent
}

public struct BundleDocument: Sendable {
  public let data: Data
  public let dataClasses: Set<DataClass>

  public init(data: Data, dataClasses: Set<DataClass>) {
    self.data = data
    self.dataClasses = dataClasses
  }
}

public struct BundleFile: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case events
    case text
  }

  public let path: String
  public let kind: Kind
  public let bytes: Int
  public let sha256: String
  public let dataClasses: [DataClass]
}

public struct BundleManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let bundleID: String
  public let files: [BundleFile]
  public let dataClasses: [DataClass]
  public let removedClasses: [DataClass]
  public let localOnly: Bool
  public let retention: String
  public let supportCaseLink: String?
}

public struct PrivacyPreview: Equatable, Sendable {
  public let bundleID: String
  public let files: [BundleFile]
  public let dataClasses: [DataClass]
  public let removedClasses: [DataClass]
  public let totalBytes: Int
  public let localOnly: Bool
  public let retention: String
  public let supportCaseLink: String?

  init(manifest: BundleManifest) {
    bundleID = manifest.bundleID
    files = manifest.files
    dataClasses = manifest.dataClasses
    removedClasses = manifest.removedClasses
    totalBytes = manifest.files.reduce(0) { $0 + $1.bytes }
    localOnly = manifest.localOnly
    retention = manifest.retention
    supportCaseLink = manifest.supportCaseLink
  }
}

/// A deliberately unimplemented boundary: local export grants no upload permission.
public enum DiagnosticUpload {
  public enum Availability: Equatable, Sendable { case unavailable }

  public static func availability(consent: ConsentLevel) -> Availability { .unavailable }
}

enum BundleRules {
  static let maxFileBytes = 1_048_576
  static let maxTotalBytes = 8_388_608
  static let maxDocuments = 30
  static let retention = "Local prototype files remain until explicitly deleted by their owner."

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func sorted(_ classes: Set<DataClass>) -> [DataClass] {
    classes.sorted { $0.rawValue < $1.rawValue }
  }

  static func classes(in events: [StructuredEvent]) -> Set<DataClass> {
    guard !events.isEmpty else { return [] }
    // Fixed schema: event code; correlation versions, host and game/profile IDs;
    // timestamp and operation/session/runtime outcome context. Optional lab IDs
    // describe the same runtime context, never an unrelated process inventory.
    return events.reduce(into: Set<DataClass>([
      .componentVersions, .errorCode, .hostCapabilities, .gameProfileIdentifiers, .runtimeOutcome
    ])) { result, event in
      result.formUnion(event.fields.map(\.dataClass))
    }
  }

  static func validPath(_ file: BundleFile) -> Bool {
    switch file.kind {
    case .events: return file.path == "events.json"
    case .text:
      return file.path.range(of: #"^document-[0-9]{3}\.txt$"#, options: .regularExpression) != nil
    }
  }
}
