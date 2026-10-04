// Author: Timur Isaev

import Darwin
import Foundation

public enum LaboratoryError: Error, Equatable {
  case unsupportedScenario
  case injectionDidNotFire
  case oracleMismatch(expected: DiagnosticCause, observed: DiagnosticCause)
}

public struct OracleRow: Codable, Equatable, Sendable {
  public let fixture: String
  public let expected: DiagnosticCause
  public let observed: DiagnosticCause
  public var matched: Bool { expected == observed }
}

public enum SyntheticLaboratory {
  public static func inject(
    _ cause: DiagnosticCause, enabled: Bool = true, subject: URL, scratch: URL
  ) throws -> StructuredEvent {
    guard cause != .insufficientEvidence else { throw LaboratoryError.unsupportedScenario }
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let identity = try correlation()
    switch cause {
    case .profileMismatch:
      let selected = scratch.appendingPathComponent("selected-profile")
      try Data((enabled ? "profile-alternative" : "profile-required").utf8).write(to: selected)
      return try event("profile_resolution", identity, [
        field("expected_profile", "profile-required", .gameProfileIdentifiers),
        field("resolved_profile", String(contentsOf: selected, encoding: .utf8), .gameProfileIdentifiers)
      ])
    case .wrongProvider:
      let required = Data("synthetic-provider-required".utf8)
      let provider = scratch.appendingPathComponent("provider-image")
      try (enabled ? Data("synthetic-provider-alternative".utf8) : required).write(to: provider)
      return try event("provider_verification", identity, [
        field("expected_digest", fingerprint(required), .componentVersions),
        field("loaded_digest", fingerprint(Data(contentsOf: provider)), .componentVersions)
      ])
    case .corruptCache:
      return try cacheEvent(enabled: enabled, identity: identity, scratch: scratch)
    case .permissionDenial:
      return try permissionEvent(enabled: enabled, identity: identity, scratch: scratch)
    case .memoryPressure:
      return try allocationEvent(enabled: enabled, identity: identity)
    case .shaderCompilerCrash, .guestCrash:
      let report = try NativeCapture(executable: subject).crash(mode: enabled ? .crash : .clean, correlation: identity)
      guard (report != nil) == enabled else { throw LaboratoryError.injectionDidNotFire }
      return try event("native_termination", identity, [
        field("process_role", cause == .shaderCompilerCrash ? "shader_compiler" : "guest", .runtimeOutcome),
        field("observed", report == nil ? "clean_exit" : "symbolicated_fatal_error", .runtimeOutcome),
        field("site", report == nil ? "none" : "seededNativeCrash", .runtimeOutcome)
      ])
    case .insufficientEvidence:
      throw LaboratoryError.unsupportedScenario
    }
  }

  /// Exports seven injected failures, then removes only the role field from the
  /// actually observed guest crash to produce the eighth ambiguous fixture.
  public static func generateEight(at output: URL, subject: URL) throws -> [OracleRow] {
    guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path) else { throw BundleError.invalidInput }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    var complete = false
    defer { if !complete { try? FileManager.default.removeItem(at: output) } }
    var rows: [OracleRow] = []
    var guest: StructuredEvent?
    for (index, cause) in DiagnosticCause.allCases.filter({ $0 != .insufficientEvidence }).enumerated() {
      let observation = try inject(cause, subject: subject, scratch: output.appendingPathComponent(".injection"))
      if cause == .guestCrash { guest = observation }
      rows.append(try export(observation, index: index, expected: cause, output: output))
    }
    guard let guest else { throw LaboratoryError.injectionDidNotFire }
    let ambiguous = try StructuredEvent(
      eventCode: guest.eventCode, timestampUnixMilliseconds: guest.timestampUnixMilliseconds,
      correlation: guest.correlation, fields: guest.fields.filter { $0.name != "process_role" }
    )
    rows.append(try export(ambiguous, index: 7, expected: .insufficientEvidence, output: output))
    for row in rows where !row.matched {
      throw LaboratoryError.oracleMismatch(expected: row.expected, observed: row.observed)
    }
    try DiagnosticsJSON.encode(rows).write(to: output.appendingPathComponent("oracle.json"))
    complete = true
    return rows
  }

  private static func export(
    _ event: StructuredEvent, index: Int, expected: DiagnosticCause, output: URL
  ) throws -> OracleRow {
    let name = String(format: "bundle-%02d", index)
    let destination = output.appendingPathComponent(name)
    try BundleBuilder.prepare(events: [event]).export(to: destination)
    let observed = FailureClassifier.classify(try SealedBundleReader.read(destination))
    return OracleRow(fixture: name, expected: expected, observed: observed)
  }

  private static func cacheEvent(enabled: Bool, identity: CorrelationID, scratch: URL) throws -> StructuredEvent {
    let original = Data("known-cache-object".utf8)
    let cache = scratch.appendingPathComponent("cache-object")
    try original.write(to: cache)
    if enabled {
      let handle = try FileHandle(forWritingTo: cache)
      defer { try? handle.close() }
      try handle.write(contentsOf: Data([0xff]))
    }
    return try event("cache_verification", identity, [
      field("expected_digest", fingerprint(original), .metadataVerification),
      field("observed_digest", fingerprint(Data(contentsOf: cache)), .metadataVerification)
    ])
  }

  private static func permissionEvent(enabled: Bool, identity: CorrelationID, scratch: URL) throws -> StructuredEvent {
    let file = scratch.appendingPathComponent("permission-object")
    try Data("synthetic access probe".utf8).write(to: file)
    guard chmod(file.path, enabled ? 0 : 0o600) == 0 else { throw LaboratoryError.injectionDidNotFire }
    defer { chmod(file.path, 0o600) }
    let descriptor = open(file.path, O_RDONLY)
    let error = descriptor < 0 ? errno : 0
    if descriptor >= 0 { close(descriptor) }
    guard error == (enabled ? EACCES : 0) else { throw LaboratoryError.injectionDidNotFire }
    return try event("file_access", identity, [
      field("operation", "read", .runtimeOutcome), field("errno", String(error), .errorCode)
    ])
  }

  private static func allocationEvent(
    enabled: Bool, identity: CorrelationID
  ) throws -> StructuredEvent {
    let available = 32_768
    let requested = enabled ? 65_536 : 8_192
    let allocation: Data? = requested <= available ? Data(repeating: 0xa5, count: requested) : nil
    guard (allocation == nil) == enabled else { throw LaboratoryError.injectionDidNotFire }
    return try event("allocation", identity, [
      field("requested_bytes", String(requested), .runtimeOutcome),
      field("available_bytes", String(available), .runtimeOutcome),
      field("result", allocation == nil ? "quota_exhausted" : "granted", .runtimeOutcome)
    ])
  }

  private static func event(
    _ code: String, _ identity: CorrelationID, _ fields: [EventField]
  ) throws -> StructuredEvent {
    try StructuredEvent(eventCode: code, timestampUnixMilliseconds: 0, correlation: identity, fields: fields)
  }

  private static func field(
    _ name: String, _ value: String, _ kind: DataClass
  ) throws -> EventField {
    try EventField(name: name, value: value, dataClass: kind)
  }

  private static func fingerprint(_ data: Data) -> String {
    // Fixed groups preserve the full digest without resembling a card-shaped run.
    let characters = Array(BundleRules.digest(data))
    return "sha256:" + stride(from: 0, to: characters.count, by: 8).map {
      String(characters[$0..<min($0 + 8, characters.count)])
    }.joined(separator: ":")
  }

  private static func correlation() throws -> CorrelationID {
    let alphabet = Array("abcdefghijklmnop")
    let opaque = String(UUID().uuidString.compactMap(\.hexDigitValue).map { alphabet[$0] })
    return try CorrelationID(
      requestID: "request-" + opaque,
      operationID: "operation-local", sessionID: "session-local",
      gameID: "synthetic-game", buildID: "synthetic-build", hostClassID: "mac-arm64",
      runtimeGenerationID: "synthetic-generation", profileID: "synthetic-profile", profileRevision: "1",
      processPolicyID: "synthetic-local", providerBuildDigests: ["synthetic": "synthetic-build-v1"],
      testPlan: "diagnostics-oracle", scenario: "controlled-operation", runner: "local"
    )
  }
}
