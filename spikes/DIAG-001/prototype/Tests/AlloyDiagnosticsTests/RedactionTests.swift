// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyDiagnostics

@Suite("Offline redaction controls")
struct RedactionTests {
  @Test("literal seeded fixture has twenty secrets and no survivors after redaction")
  func seededFixture() throws {
    let source = try redactionFixture("redaction-seeded", extension: "txt")
    let secrets = try JSONDecoder().decode(
      [String].self, from: redactionFixture("redaction-secrets", extension: "json")
    )
    #expect(secrets.count == 20)
    let original = try #require(String(data: source, encoding: .utf8))
    #expect(secrets.allSatisfy(original.contains))
    let result = try DocumentRedactor.redact(source, declaredClasses: [.runtimeOutcome])
    let output = try #require(result.data.flatMap { String(data: $0, encoding: .utf8) })
    let survivors = secrets.filter(output.contains)
    #expect(survivors.isEmpty)
    #expect(result.retainedClasses == [.runtimeOutcome])
    #expect(result.removedClasses == [
      .credentials, .homePaths, .tokensCookies, .sensitiveURLs,
      .saveGameContent, .chatVoiceContent, .usernames
    ])
    #expect(result.findings.allSatisfy { $0.count >= 1 })
    let audit = try #require(String(data: DiagnosticsJSON.encode(result.findings), encoding: .utf8))
    #expect(secrets.filter(audit.contains).isEmpty)
    print("redaction-fixture planted=\(secrets.count) survivors=\(survivors.count)")
  }

  @Test("clean fixture remains byte identical including Unicode and digest data")
  func cleanFixtureUnchanged() throws {
    let source = try redactionFixture("redaction-clean", extension: "txt")
    let result = try DocumentRedactor.redact(source, declaredClasses: [.runtimeOutcome, .componentVersions])
    #expect(result.data == source)
    #expect(result.findings.isEmpty)
    #expect(result.removedClasses.isEmpty)
    #expect(result.retainedClasses == [.runtimeOutcome, .componentVersions])
    let output = try #require(result.data)
    let changedBytes = zip(source, output).filter { $0 != $1 }.count + abs(source.count - output.count)
    print("redaction-clean bytes=\(source.count) changed_bytes=\(changedBytes)")
  }

  @Test("all ten sensitive classes exclude entire fields and opaque documents")
  func classAwareExclusion() throws {
    let sensitive: Set<DataClass> = [
      .credentials, .homePaths, .chatVoiceContent, .sensitiveURLs, .saveGameContent,
      .tokensCookies, .moduleProcessFileInventory, .gameplayVideo, .screenshots, .usernames
    ]
    #expect(sensitive.count == 10)
    for dataClass in sensitive {
      let field = try EventField(name: "private", value: "unrecognizable private bytes", dataClass: dataClass)
      let event = try redactionEvent(fields: [field])
      let result = try EventRedactor.redact(event)
      #expect(result.event.fields.isEmpty)
      #expect(result.removedClasses == [dataClass])
      #expect(result.findings.isEmpty)
      let document = try DocumentRedactor.redact(Data([0xFF, 0x00, 0xFE]), declaredClasses: [dataClass])
      #expect(document.data == nil)
      #expect(document.retainedClasses.isEmpty)
      #expect(document.removedClasses == [dataClass])
    }
    let mixed = try DocumentRedactor.redact(
      Data("arbitrary text".utf8), declaredClasses: [.runtimeOutcome, .saveGameContent]
    )
    #expect(mixed.data == nil)
    #expect(mixed.removedClasses == [.runtimeOutcome, .saveGameContent])
  }

  @Test("otherwise permitted fields cannot hide a known secret pattern")
  func benignClassStillScanned() throws {
    let fields = try [
      EventField(name: "detail", value: "failed at /Users/private-player/log.txt", dataClass: .runtimeOutcome),
      EventField(name: "error", value: "api_key=fake_secret_inside_error_code", dataClass: .errorCode),
      EventField(name: "status", value: "ALLOY_OK", dataClass: .metadataVerification)
    ]
    let source = try redactionEvent(fields: fields)
    let result = try EventRedactor.redact(source)
    #expect(result.event.correlation == source.correlation)
    #expect(result.event.fields.count == 3)
    #expect(result.event.fields.last == fields.last)
    #expect(result.removedClasses == [.homePaths, .credentials])
    let output = try #require(String(data: DiagnosticsJSON.encode(result.event), encoding: .utf8))
    #expect(!output.contains("private-player"))
    #expect(!output.contains("fake_secret_inside_error_code"))
    #expect(try EventRedactor.redact(result.event).event == result.event)
  }

  @Test("unsafe values in every correlation slot and provider map fail before export")
  func correlationMetadataScanned() throws {
    let event = try redactionEvent(fields: [])
    let original = try eventObject(event)
    let identities = try #require(original["correlation"] as? [String: Any])
    for key in identities.keys where key != "provider_build_digests" {
      var changed = identities
      changed[key] = "/Users/metadata-private-player/secret"
      var object = original
      object["correlation"] = changed
      let unredacted = try decodeEvent(object)
      #expect(throws: RedactionError.unsafeMetadata(field: key)) { try EventRedactor.redact(unredacted) }
    }
    for (map, expected) in [
      (["/Users/provider-private-player/module": "digest"], "provider_build_digests.key"),
      (["cpu": "api_key=provider_metadata_secret"], "provider_build_digests.value")
    ] {
      var changed = identities
      changed["provider_build_digests"] = map
      var object = original
      object["correlation"] = changed
      let unredacted = try decodeEvent(object)
      #expect(throws: RedactionError.unsafeMetadata(field: expected)) { try EventRedactor.redact(unredacted) }
    }
  }

  @Test("event codes and field names also fail when they contain a known secret pattern")
  func eventMetadataScanned() throws {
    let correlation = try modelTestCorrelation()
    let unsafeCode = try StructuredEvent(
      eventCode: "api_key=event_code_secret", timestampUnixMilliseconds: 0, correlation: correlation, fields: []
    )
    #expect(throws: RedactionError.unsafeMetadata(field: "event_code")) { try EventRedactor.redact(unsafeCode) }
    let unsafeName = try redactionEvent(fields: [
      EventField(name: "/Users/field-name-private-player/path", value: "value", dataClass: .credentials)
    ])
    #expect(throws: RedactionError.unsafeMetadata(field: "fields.name")) { try EventRedactor.redact(unsafeName) }
  }

  @Test("bounded scanning rejects oversized or invalid text without lossy decoding")
  func inputLimits() throws {
    #expect(throws: RedactionError.inputTooLarge(limit: 3)) { try RedactionScanner.scan("🎮", maxUTF8Bytes: 3) }
    #expect(throws: RedactionError.invalidLimit) { try RedactionScanner.scan("", maxUTF8Bytes: 0) }
    #expect(throws: RedactionError.invalidUTF8) {
      try DocumentRedactor.redact(Data([0xFF, 0xFE]), declaredClasses: [.errorCode])
    }
    #expect(throws: RedactionError.missingClassification) {
      try DocumentRedactor.redact(Data("text".utf8), declaredClasses: [])
    }
    #expect(throws: RedactionError.inputTooLarge(limit: 3)) {
      try DocumentRedactor.redact(Data("text".utf8), declaredClasses: [.screenshots], maxUTF8Bytes: 3)
    }
    #expect(throws: RedactionError.outputTooLarge(limit: 5)) { try RedactionScanner.scan("pwd=x", maxUTF8Bytes: 5) }
    let event = try redactionEvent(fields: [])
    #expect(throws: RedactionError.inputTooLarge(limit: 1)) { try EventRedactor.redact(event, maxUTF8Bytes: 1) }
  }

  @Test("overlapping Unicode findings merge safely and a second scan is unchanged")
  func overlappingMatchesAndUnicode() throws {
    let text = "🎮 https://synthetic.invalid/path?api_key=overlapping_secret_suffix Пример"
    let result = try RedactionScanner.scan(text)
    #expect(result.text == "🎮 [REDACTED] Пример")
    #expect(Set(result.findings.map(\.dataClass)) == [.credentials, .sensitiveURLs])
    #expect(try RedactionScanner.scan(result.text).findings.isEmpty)
    #expect(try RedactionScanner.scan(result.text).text == result.text)
  }

  @Test("scanner failure control distinguishes unclassified arbitrary private text")
  func classificationBoundaryIsExplicit() throws {
    let text = "unmarked ordinary-language private conversation"
    #expect(try RedactionScanner.scan(text).findings.isEmpty)
    let removed = try DocumentRedactor.redact(Data(text.utf8), declaredClasses: [.chatVoiceContent])
    #expect(removed.data == nil)
  }

  @Test("three logged seeds catch every randomized synthetic insertion")
  func threeSeedFuzzer() throws {
    for seed: UInt64 in [0xD1A6_0001, 0xD1A6_0002, 0xD1A6_0003] {
      let report = try RedactionFuzzer.run(seed: seed, iterations: 360)
      #expect(report.plantedCount == 360)
      #expect(report.survivingCount == 0)
      #expect(report.catchRate == 1)
      #expect(report.findingCount >= report.plantedCount)
      #expect(try RedactionFuzzer.run(seed: seed, iterations: 360) == report)
      print(
        "redaction-fuzz seed=\(seed) planted=\(report.plantedCount)"
          + " survivors=\(report.survivingCount) catch_rate=\(report.catchRate)"
      )
    }
  }
}

private func redactionFixture(_ name: String, extension fileExtension: String) throws -> Data {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

private func redactionEvent(fields: [EventField]) throws -> StructuredEvent {
  try StructuredEvent(
    eventCode: "runtime.synthetic.event", timestampUnixMilliseconds: 0,
    correlation: modelTestCorrelation(), fields: fields
  )
}

private func eventObject(_ event: StructuredEvent) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: DiagnosticsJSON.encode(event)) as? [String: Any])
}

private func decodeEvent(_ object: [String: Any]) throws -> StructuredEvent {
  try JSONDecoder().decode(StructuredEvent.self, from: JSONSerialization.data(withJSONObject: object))
}
