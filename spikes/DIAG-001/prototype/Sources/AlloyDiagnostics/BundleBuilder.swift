// Author: Timur Isaev

import Foundation

public struct PreparedBundle: Sendable {
  public let manifest: BundleManifest
  let payloads: [String: Data]

  /// Available before any consent selection. No uploaded or raw bytes are consulted.
  public var preview: PrivacyPreview { PrivacyPreview(manifest: manifest) }

  @discardableResult
  public func export(to destination: URL) throws -> URL {
    guard destination.isFileURL else { throw BundleError.invalidInput }
    let manager = FileManager.default
    guard !manager.fileExists(atPath: destination.path) else { throw BundleError.destinationExists }
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".diag-\(UUID().uuidString)")
    try manager.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    defer { try? manager.removeItem(at: staging) }
    for (path, data) in payloads {
      try writePrivate(data, to: staging.appendingPathComponent(path))
    }
    try writePrivate(try DiagnosticsJSON.encode(manifest), to: staging.appendingPathComponent("manifest.json"))
    _ = try SealedBundleReader.read(staging)
    try manager.moveItem(at: staging, to: destination)
    return destination
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    guard FileManager.default.createFile(
      atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]
    ) else {
      throw BundleError.invalidInput
    }
  }
}

public enum BundleBuilder {
  public static func prepare(
    events: [StructuredEvent], documents: [BundleDocument] = [], captures: [NativeCaptureReport] = []
  ) throws -> PreparedBundle {
    guard events.count <= 1_024, captures.count <= 32, documents.count <= BundleRules.maxDocuments else {
      throw BundleError.exceededLimit
    }
    var sanitized: [StructuredEvent] = []
    var eventBytes = 2
    var removed: Set<DataClass> = []
    for event in events + (try captures.map(summary)) {
      let result = try EventRedactor.redact(event)
      eventBytes += try DiagnosticsJSON.encode(result.event).count + (sanitized.isEmpty ? 0 : 1)
      guard eventBytes <= BundleRules.maxFileBytes else { throw BundleError.exceededLimit }
      sanitized.append(result.event)
      removed.formUnion(result.removedClasses)
    }
    // Raw native stacks enumerate loaded modules and contain local paths. Keep
    // only the typed cause summary; dropping raw stacks is deliberate minimization.
    if !captures.isEmpty { removed.formUnion([.homePaths, .moduleProcessFileInventory]) }
    let eventData = try DiagnosticsJSON.encode(sanitized)
    var payloads = ["events.json": eventData]
    var totalBytes = eventData.count
    var files = [entry("events.json", kind: .events, data: eventData, classes: BundleRules.classes(in: sanitized))]
    for (index, document) in documents.enumerated() {
      let result = try DocumentRedactor.redact(document.data, declaredClasses: document.dataClasses)
      removed.formUnion(result.removedClasses)
      guard let data = result.data, !data.isEmpty else { continue }
      totalBytes += data.count
      guard totalBytes <= BundleRules.maxTotalBytes else { throw BundleError.exceededLimit }
      let path = String(format: "document-%03d.txt", index)
      payloads[path] = data
      files.append(entry(path, kind: .text, data: data, classes: result.retainedClasses))
    }
    guard files.allSatisfy({ $0.bytes <= BundleRules.maxFileBytes }),
          files.reduce(0, { $0 + $1.bytes }) <= BundleRules.maxTotalBytes else {
      throw BundleError.exceededLimit
    }
    let manifest = BundleManifest(
      schemaVersion: 1, bundleID: UUID().uuidString.lowercased(), files: files.sorted { $0.path < $1.path },
      dataClasses: BundleRules.sorted(Set(files.flatMap(\.dataClasses))),
      removedClasses: BundleRules.sorted(removed), localOnly: true,
      retention: BundleRules.retention, supportCaseLink: nil
    )
    return PreparedBundle(manifest: manifest, payloads: payloads)
  }

  private static func entry(_ path: String, kind: BundleFile.Kind, data: Data, classes: Set<DataClass>) -> BundleFile {
    BundleFile(path: path, kind: kind, bytes: data.count, sha256: BundleRules.digest(data),
               dataClasses: BundleRules.sorted(classes))
  }

  private static func summary(_ report: NativeCaptureReport) throws -> StructuredEvent {
    guard report.elapsedSeconds.isFinite, report.elapsedSeconds >= 0 else { throw BundleError.invalidInput }
    return try StructuredEvent(
      eventCode: "native_\(report.kind.rawValue)", timestampUnixMilliseconds: 0, correlation: report.correlation,
      fields: [
        EventField(name: "capture_reason", value: report.reason, dataClass: .runtimeOutcome),
        EventField(name: "capture_tool", value: report.tool, dataClass: .componentVersions),
        EventField(name: "capture_seconds", value: String(report.elapsedSeconds), dataClass: .runtimeOutcome)
      ]
    )
  }
}
