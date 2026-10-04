// Author: Timur Isaev

import CryptoKit
import Foundation
import Testing
@testable import AlloyDiagnostics

@Suite("Local sealed bundle controls")
struct BundleTests {
  @Test("preview precedes consent and exported content exactly matches its manifest")
  func preparePreviewExportRead() throws {
    let clean = try bundleFixture("redaction-clean", extension: "txt")
    let seeded = try bundleFixture("redaction-seeded", extension: "txt")
    let secrets = try JSONDecoder().decode([String].self, from: bundleFixture("redaction-secrets", extension: "json"))
    let event = try bundleTestEvent(fields: [
      EventField(name: "client", value: "client-synthetic", dataClass: .pseudonymousClientIdentifier),
      EventField(name: "private", value: "private_field_payload", dataClass: .credentials)
    ])
    let prepared = try BundleBuilder.prepare(events: [event], documents: [
      BundleDocument(data: seeded, dataClasses: [.runtimeOutcome]),
      BundleDocument(data: clean, dataClasses: [.metadataVerification])
    ])
    let preview = prepared.preview
    let retained: Set<DataClass> = [
      .componentVersions, .errorCode, .hostCapabilities, .gameProfileIdentifiers,
      .runtimeOutcome, .pseudonymousClientIdentifier, .metadataVerification
    ]
    #expect(Set(preview.dataClasses) == retained)
    #expect(preview.files.map(\.path) == ["document-000.txt", "document-001.txt", "events.json"])
    #expect(preview.files == prepared.manifest.files)
    #expect(preview.removedClasses == prepared.manifest.removedClasses)
    #expect(preview.localOnly)
    #expect(!preview.retention.isEmpty)
    #expect(preview.supportCaseLink == nil)
    for consent in ConsentLevel.allCases {
      #expect(DiagnosticUpload.availability(consent: consent) == .unavailable)
    }
    #expect(prepared.preview == preview)

    try withBundleScratch { scratch in
      let destination = scratch.appendingPathComponent("report")
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      #expect(try prepared.export(to: destination) == destination)
      let read = try SealedBundleReader.read(destination)
      #expect(read.manifest == prepared.manifest)
      #expect(read.preview == preview)
      #expect(read.events.count == 1)
      #expect(read.events.first?.correlation == event.correlation)
      #expect(read.events.first?.fields.map(\.name) == ["client"])
      #expect(read.documents["document-001.txt"] == clean)
      #expect(Set(read.documents.keys) == ["document-000.txt", "document-001.txt"])
      try verifyExportedFiles(destination, preview: preview, secrets: secrets + ["private_field_payload"])
      #expect(throws: BundleError.destinationExists) { try prepared.export(to: destination) }
      #expect(try SealedBundleReader.read(destination).manifest == prepared.manifest)
    }
  }

  @Test("all sensitive document classes are excluded, including opaque media")
  func sensitiveClassesExcluded() throws {
    let sensitive: Set<DataClass> = [
      .credentials, .homePaths, .chatVoiceContent, .sensitiveURLs, .saveGameContent,
      .tokensCookies, .moduleProcessFileInventory, .gameplayVideo, .screenshots, .usernames
    ]
    let documents = sensitive.map { BundleDocument(data: Data([0xFF, 0x00, 0xFE]), dataClasses: [$0]) }
    let prepared = try BundleBuilder.prepare(events: [], documents: documents)
    #expect(prepared.manifest.files.map(\.path) == ["events.json"])
    #expect(prepared.manifest.dataClasses.isEmpty)
    #expect(Set(prepared.manifest.removedClasses) == sensitive)
    try withBundleScratch { scratch in
      let destination = try prepared.export(to: scratch.appendingPathComponent("report"))
      let read = try SealedBundleReader.read(destination)
      #expect(read.events.isEmpty)
      #expect(read.documents.isEmpty)
      #expect(read.preview.totalBytes == 2)
    }
  }

  @Test("capture export retains only typed summaries and excludes raw stack content")
  func captureSummaryOnly() throws {
    let capture = try bundleCapture()
    let prepared = try BundleBuilder.prepare(events: [], captures: [capture])
    #expect(Set(prepared.manifest.removedClasses) == [.homePaths, .moduleProcessFileInventory])
    try withBundleScratch { scratch in
      let destination = try prepared.export(to: scratch.appendingPathComponent("report"))
      let read = try SealedBundleReader.read(destination)
      let event = try #require(read.events.first)
      #expect(event.eventCode == "native_crash")
      #expect(event.correlation == capture.correlation)
      #expect(Set(event.fields.map(\.name)) == ["capture_reason", "capture_tool", "capture_seconds"])
      #expect(event.fields.first { $0.name == "capture_reason" }?.value == capture.reason)
      #expect(read.documents.isEmpty)
      for member in try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
        let text = try String(contentsOf: member, encoding: .utf8)
        #expect(!text.contains("RAW_STACK_PRIVATE_SENTINEL"))
        #expect(!text.contains("capture-private-player"))
        #expect(!text.contains("capture_stack_token"))
      }
    }
  }

  @Test("tampered bytes, absent members, and unlisted members break the seal")
  func directoryAndDigestTampering() throws {
    try withExportedBundle { directory in
      try Data("modified".utf8).write(to: directory.appendingPathComponent("document-000.txt"))
      #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
    }
    try withExportedBundle { directory in
      try FileManager.default.removeItem(at: directory.appendingPathComponent("events.json"))
      #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
    }
    try withExportedBundle { directory in
      try Data("extra secret".utf8).write(to: directory.appendingPathComponent("unlisted.txt"))
      #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
    }
  }

  @Test("malformed, noncanonical, unknown-field, and inconsistent manifests are rejected")
  func malformedManifests() throws {
    try withExportedBundle { directory in
      try Data("{".utf8).write(to: directory.appendingPathComponent("manifest.json"))
      #expect(throws: (any Error).self) { try SealedBundleReader.read(directory) }
    }
    try withExportedBundle { directory in
      let path = directory.appendingPathComponent("manifest.json")
      var data = try Data(contentsOf: path)
      data.append(0x0A)
      try data.write(to: path)
      #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
    }
    let mutations: [(inout [String: Any]) -> Void] = [
      { $0["schemaVersion"] = 2 }, { $0["bundleID"] = "not-a-uuid" },
      { $0["localOnly"] = false }, { $0["retention"] = "invented-retention" },
      { $0["supportCaseLink"] = "https://synthetic.invalid/private" },
      { $0["unknown"] = "unclassified" }, { $0["dataClasses"] = [String]() }
    ]
    for mutation in mutations {
      try withExportedBundle { directory in
        var manifest = try manifestObject(directory)
        mutation(&manifest)
        try writeManifest(manifest, directory: directory)
        #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
      }
    }
  }

  @Test("relative traversal, absolute paths, nested paths, and duplicate entries are rejected")
  func unsafeMemberPaths() throws {
    for path in ["../outside.txt", "/tmp/outside.txt", "nested/document-000.txt", "%2e%2e/outside.txt"] {
      try withExportedBundle { directory in
        var manifest = try manifestObject(directory)
        var files = try #require(manifest["files"] as? [[String: Any]])
        files[0]["path"] = path
        manifest["files"] = files
        try writeManifest(manifest, directory: directory)
        #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
      }
    }
    try withExportedBundle { directory in
      var manifest = try manifestObject(directory)
      var files = try #require(manifest["files"] as? [[String: Any]])
      files.append(files[0])
      manifest["files"] = files
      try writeManifest(manifest, directory: directory)
      #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
    }
  }

  @Test("symlinked roots, manifests, and payloads are rejected even with identical bytes")
  func symlinksRejected() throws {
    for filename in ["manifest.json", "events.json", "document-000.txt"] {
      try withExportedBundle { directory in
        let original = directory.appendingPathComponent(filename)
        let target = directory.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.moveItem(at: original, to: target)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
        #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
      }
    }
    try withExportedBundle { directory in
      let link = directory.deletingLastPathComponent().appendingPathComponent("bundle-link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
      #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(link) }
    }
  }

  @Test("rewritten hashes cannot make known sensitive text or event fields acceptable")
  func resealedSensitivePayloadRejected() throws {
    try withExportedBundle { directory in
      try replacePayload(
        Data("api_key=resealed_document_private_value".utf8), path: "document-000.txt", directory: directory
      )
      #expect(throws: BundleError.unsafeContent) { try SealedBundleReader.read(directory) }
    }
    try withExportedBundle { directory in
      let unsafe = try bundleTestEvent(fields: [
        EventField(name: "outcome", value: "/Users/resealed-private-player/log.txt", dataClass: .runtimeOutcome)
      ])
      try replacePayload(try DiagnosticsJSON.encode([unsafe]), path: "events.json", directory: directory)
      #expect(throws: BundleError.unsafeContent) { try SealedBundleReader.read(directory) }
    }
  }

  @Test("construction and reading enforce file, aggregate, and entry limits")
  func boundedLimits() throws {
    let event = try bundleTestEvent(fields: [])
    let document = BundleDocument(data: Data("bounded text".utf8), dataClasses: [.runtimeOutcome])
    #expect(throws: BundleError.exceededLimit) {
      try BundleBuilder.prepare(events: Array(repeating: event, count: 1_025))
    }
    #expect(throws: BundleError.exceededLimit) {
      try BundleBuilder.prepare(events: [], documents: Array(repeating: document, count: 31))
    }
    let capture = try bundleCapture()
    #expect(throws: BundleError.exceededLimit) {
      try BundleBuilder.prepare(events: [], captures: Array(repeating: capture, count: 33))
    }
    let oversized = BundleDocument(data: Data(repeating: 0x61, count: 1_048_577), dataClasses: [.runtimeOutcome])
    #expect(throws: RedactionError.inputTooLarge(limit: 1_048_576)) {
      try BundleBuilder.prepare(events: [], documents: [oversized])
    }
    let boundary = BundleDocument(data: Data(repeating: 0x61, count: 1_048_576), dataClasses: [.runtimeOutcome])
    #expect(try BundleBuilder.prepare(events: [], documents: [boundary]).preview.totalBytes == 1_048_578)
    #expect(throws: BundleError.exceededLimit) {
      try BundleBuilder.prepare(events: [], documents: Array(repeating: boundary, count: 8))
    }
    try withExportedBundle { directory in
      try Data(repeating: 0x20, count: 1_048_577).write(to: directory.appendingPathComponent("manifest.json"))
      #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
    }
    try withExportedBundle { directory in
      var manifest = try manifestObject(directory)
      var files = try #require(manifest["files"] as? [[String: Any]])
      files[0]["bytes"] = Int.max
      manifest["files"] = files
      try writeManifest(manifest, directory: directory)
      #expect(throws: BundleError.invalidSeal) { try SealedBundleReader.read(directory) }
    }
  }

  @Test("library sources use no network APIs and package declares no external dependencies")
  func offlineSourceBoundary() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let sources = package.appendingPathComponent("Sources")
    let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    let allowedImports: Set<String> = ["Foundation", "Darwin", "CryptoKit", "AlloyDiagnostics"]
    let forbidden = #"\b(URLSession|URLRequest|URLProtocol|NWConnection|NWListener|"#
      + #"CFHTTPMessage|CFNetwork|socket|connect|getaddrinfo|sendto|recvfrom|curl|wget)\b"#
    var checked = 0
    while let file = enumerator.nextObject() as? URL {
      guard file.pathExtension == "swift" else { continue }
      checked += 1
      let source = try String(contentsOf: file, encoding: .utf8)
      #expect(source.range(of: forbidden, options: .regularExpression) == nil)
      for line in source.components(separatedBy: .newlines) where line.hasPrefix("import ") {
        #expect(allowedImports.contains(String(line.dropFirst("import ".count))))
      }
    }
    #expect(checked >= 10)
    let manifest = try String(contentsOf: package.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(manifest.range(of: #"\.package\s*\("#, options: .regularExpression) == nil)
  }
}

private func bundleFixture(_ name: String, extension fileExtension: String) throws -> Data {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

private func bundleTestEvent(fields: [EventField]) throws -> StructuredEvent {
  try StructuredEvent(
    eventCode: "runtime.synthetic.bundle", timestampUnixMilliseconds: 0,
    correlation: modelTestCorrelation(), fields: fields
  )
}

private func bundleCapture() throws -> NativeCaptureReport {
  try NativeCaptureReport(
    kind: .crash, correlation: modelTestCorrelation(), tool: "Xcode LLDB",
    reason: "fatal-error-at-seededNativeCrash",
    symbolicatedText: "RAW_STACK_PRIVATE_SENTINEL /Users/capture-private-player/stack token=capture_stack_token",
    elapsedSeconds: 0.5
  )
}

private func withBundleScratch(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diag-bundle-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func withExportedBundle(_ body: (URL) throws -> Void) throws {
  try withBundleScratch { scratch in
    let event = try bundleTestEvent(fields: [])
    let prepared = try BundleBuilder.prepare(events: [event], documents: [
      BundleDocument(data: Data("clean synthetic document".utf8), dataClasses: [.runtimeOutcome])
    ])
    let destination = try prepared.export(to: scratch.appendingPathComponent("report"))
    try body(destination)
  }
}

private func permissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

private func verifyExportedFiles(_ directory: URL, preview: PrivacyPreview, secrets: [String]) throws {
  let members = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
  #expect(Set(members.map(\.lastPathComponent)) == Set(preview.files.map(\.path) + ["manifest.json"]))
  #expect(try permissions(directory) == 0o700)
  var actualPayloadBytes = 0
  for member in members {
    #expect(try permissions(member) == 0o600)
    let data = try Data(contentsOf: member)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(secrets.filter(text.contains).isEmpty)
    if let file = preview.files.first(where: { $0.path == member.lastPathComponent }) {
      actualPayloadBytes += data.count
      #expect(file.bytes == data.count)
      #expect(file.sha256 == testDigest(data))
    }
  }
  #expect(preview.totalBytes == actualPayloadBytes)
}

private func testDigest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func manifestObject(_ directory: URL) throws -> [String: Any] {
  let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func writeManifest(_ object: [String: Any], directory: URL) throws {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    .write(to: directory.appendingPathComponent("manifest.json"))
}

private func replacePayload(_ data: Data, path: String, directory: URL) throws {
  try data.write(to: directory.appendingPathComponent(path))
  var manifest = try manifestObject(directory)
  var files = try #require(manifest["files"] as? [[String: Any]])
  let index = try #require(files.firstIndex { $0["path"] as? String == path })
  files[index]["bytes"] = data.count
  files[index]["sha256"] = testDigest(data)
  manifest["files"] = files
  try writeManifest(manifest, directory: directory)
}
