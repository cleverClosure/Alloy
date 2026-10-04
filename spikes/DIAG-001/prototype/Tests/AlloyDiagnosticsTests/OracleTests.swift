// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyDiagnostics

@Suite("Sealed-bundle failure oracle", .serialized)
struct OracleTests {
  private let expected: [DiagnosticCause] = [
    .profileMismatch, .wrongProvider, .shaderCompilerCrash, .permissionDenial,
    .corruptCache, .memoryPressure, .guestCrash, .insufficientEvidence
  ]

  private func subject() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".build/debug/AlloyDiagnosticsSubject")
  }

  private func temporary() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }

  @Test("Eight fixtures come from actual scripted operations and survive relocation")
  func generatedOracle() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("generated")
    let rows = try SyntheticLaboratory.generateEight(at: output, subject: subject())
    #expect(rows.map(\.observed) == expected)
    #expect(rows.map(\.expected) == expected)
    #expect(rows.allSatisfy { $0.matched })
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent(".injection").path))
    for (index, row) in rows.enumerated() {
      let renamed = root.appendingPathComponent(UUID().uuidString)
      try FileManager.default.moveItem(at: output.appendingPathComponent(row.fixture), to: renamed)
      let sealed = try SealedBundleReader.read(renamed)
      #expect(FailureClassifier.classify(sealed) == expected[index])
      #expect(!sealed.events.contains { $0.fields.contains { $0.name == "expected_cause" } })
      print("DIAG_ORACLE fixture=\(row.fixture) observed=\(row.observed.rawValue) matched=\(row.matched)")
    }
  }

  @Test("Committed sealed examples reproduce the literal eight-answer oracle")
  func committedFixtures() throws {
    let directory = try #require(Bundle.module.url(forResource: "oracle", withExtension: nil, subdirectory: "Fixtures"))
    for (index, cause) in expected.enumerated() {
      let path = directory.appendingPathComponent(String(format: "bundle-%02d", index))
      #expect(FailureClassifier.classify(try SealedBundleReader.read(path)) == cause)
    }
  }

  @Test("Disabling each injection yields no diagnosis, including native clean exits")
  func disabledControls() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    for cause in expected where cause != .insufficientEvidence {
      let event = try SyntheticLaboratory.inject(
        cause, enabled: false, subject: subject(), scratch: root.appendingPathComponent("operation")
      )
      let destination = root.appendingPathComponent(UUID().uuidString)
      try BundleBuilder.prepare(events: [event]).export(to: destination)
      #expect(FailureClassifier.classify(try SealedBundleReader.read(destination)) == .insufficientEvidence)
    }
  }

  @Test("Removing any distinguishing signal prevents classification")
  func missingSignalControls() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let required = ["resolved_profile", "loaded_digest", "process_role", "errno",
                    "observed_digest", "requested_bytes", "process_role"]
    for (index, cause) in expected.dropLast().enumerated() {
      let observed = try SyntheticLaboratory.inject(
        cause, subject: subject(), scratch: root.appendingPathComponent("operation")
      )
      let stripped = try StructuredEvent(
        eventCode: observed.eventCode, timestampUnixMilliseconds: 0, correlation: observed.correlation,
        fields: observed.fields.filter { $0.name != required[index] }
      )
      #expect(stripped.fields.count == observed.fields.count - 1)
      let destination = root.appendingPathComponent(UUID().uuidString)
      try BundleBuilder.prepare(events: [stripped]).export(to: destination)
      #expect(FailureClassifier.classify(try SealedBundleReader.read(destination)) == .insufficientEvidence)
    }
  }

  @Test("Contradictory diagnoses, mixed identities, and empty evidence never guess")
  func ambiguityControls() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try SyntheticLaboratory.inject(
      .profileMismatch, subject: subject(), scratch: root.appendingPathComponent("operation")
    )
    let cache = try SyntheticLaboratory.inject(
      .corruptCache, subject: subject(), scratch: root.appendingPathComponent("operation")
    )
    let sameIdentityCache = try StructuredEvent(
      eventCode: cache.eventCode, timestampUnixMilliseconds: 0, correlation: profile.correlation, fields: cache.fields
    )
    for events in [[profile, cache], [profile, sameIdentityCache], []] {
      let destination = root.appendingPathComponent(UUID().uuidString)
      try BundleBuilder.prepare(events: events).export(to: destination)
      #expect(FailureClassifier.classify(try SealedBundleReader.read(destination)) == .insufficientEvidence)
    }
  }
}
