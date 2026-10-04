// Author: Timur Isaev

import Foundation

public struct SealedBundle: Sendable {
  public let manifest: BundleManifest
  public let events: [StructuredEvent]
  public let documents: [String: Data]
  public var preview: PrivacyPreview { PrivacyPreview(manifest: manifest) }
}

/// A content-hash seal detects accidental mutation. It is neither a signature
/// nor encryption and does not authenticate a deliberately rewritten bundle.
public enum SealedBundleReader {
  public static func read(_ directory: URL) throws -> SealedBundle {
    guard directory.isFileURL else { throw BundleError.invalidSeal }
    let root = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard root.isDirectory == true, root.isSymbolicLink != true else { throw BundleError.invalidSeal }
    let manifestData = try boundedRead(directory.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(BundleManifest.self, from: manifestData)
    try validate(manifest)
    guard try DiagnosticsJSON.encode(manifest) == manifestData else { throw BundleError.invalidSeal }
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    guard Set(names) == Set(manifest.files.map(\.path) + ["manifest.json"]) else { throw BundleError.invalidSeal }
    var events: [StructuredEvent] = []
    var documents: [String: Data] = [:]
    for file in manifest.files {
      let data = try boundedRead(directory.appendingPathComponent(file.path))
      guard data.count == file.bytes, BundleRules.digest(data) == file.sha256 else { throw BundleError.invalidSeal }
      switch file.kind {
      case .events:
        events = try readEvents(data, file: file)
      case .text:
        let result = try DocumentRedactor.redact(data, declaredClasses: Set(file.dataClasses))
        guard result.data == data, result.removedClasses.isEmpty else { throw BundleError.unsafeContent }
        documents[file.path] = data
      }
    }
    return SealedBundle(manifest: manifest, events: events, documents: documents)
  }

  private static func readEvents(_ data: Data, file: BundleFile) throws -> [StructuredEvent] {
    let events = try JSONDecoder().decode([StructuredEvent].self, from: data)
    guard events.count <= 1_056, BundleRules.sorted(BundleRules.classes(in: events)) == file.dataClasses else {
      throw BundleError.invalidSeal
    }
    for event in events {
      guard try EventRedactor.redact(event).event == event else { throw BundleError.unsafeContent }
    }
    return events
  }

  private static func validate(_ manifest: BundleManifest) throws {
    guard manifest.schemaVersion == 1, UUID(uuidString: manifest.bundleID) != nil,
          manifest.localOnly, manifest.retention == BundleRules.retention, manifest.supportCaseLink == nil,
          manifest.files.count <= BundleRules.maxDocuments + 1,
          manifest.files.filter({ $0.kind == .events }).count == 1,
          Set(manifest.files.map(\.path)).count == manifest.files.count,
          manifest.files.map(\.path) == manifest.files.map(\.path).sorted(),
          manifest.files.allSatisfy({
            BundleRules.validPath($0) && $0.bytes >= 0 && $0.bytes <= BundleRules.maxFileBytes
              && $0.dataClasses == BundleRules.sorted(Set($0.dataClasses))
          }),
          manifest.files.reduce(0, { $0 + $1.bytes }) <= BundleRules.maxTotalBytes,
          manifest.dataClasses == BundleRules.sorted(Set(manifest.files.flatMap(\.dataClasses))),
          manifest.removedClasses == BundleRules.sorted(Set(manifest.removedClasses)) else {
      throw BundleError.invalidSeal
    }
  }

  private static func boundedRead(_ url: URL) throws -> Data {
    let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
          let size = attributes.fileSize, size <= BundleRules.maxFileBytes else { throw BundleError.invalidSeal }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: BundleRules.maxFileBytes + 1) ?? Data()
    guard data.count <= BundleRules.maxFileBytes else { throw BundleError.exceededLimit }
    return data
  }
}
