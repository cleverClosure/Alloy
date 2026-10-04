// Author: Timur Isaev

import Foundation

/// The nine identity groups in operations doc §5, plus its optional lab and release context.
public struct CorrelationID: Codable, Equatable, Sendable {
  public let requestID: String
  public let operationID: String
  public let sessionID: String
  public let gameID: String
  public let buildID: String
  public let hostClassID: String
  public let runtimeGenerationID: String
  public let profileID: String
  public let profileRevision: String
  public let processPolicyID: String
  public let providerBuildDigests: [String: String]
  public let testPlan: String?
  public let scenario: String?
  public let runner: String?
  public let releaseRing: String?

  public init(
    requestID: String,
    operationID: String,
    sessionID: String,
    gameID: String,
    buildID: String,
    hostClassID: String,
    runtimeGenerationID: String,
    profileID: String,
    profileRevision: String,
    processPolicyID: String,
    providerBuildDigests: [String: String],
    testPlan: String? = nil,
    scenario: String? = nil,
    runner: String? = nil,
    releaseRing: String? = nil
  ) throws {
    let identifiers = [
      "request_id": requestID, "operation_id": operationID, "session_id": sessionID,
      "game_id": gameID, "build_id": buildID, "host_class_id": hostClassID,
      "runtime_generation_id": runtimeGenerationID, "profile_id": profileID,
      "profile_revision": profileRevision, "process_policy_id": processPolicyID
    ]
    for (field, value) in identifiers {
      try ModelValidation.identifier(value, field: field)
    }
    guard !providerBuildDigests.isEmpty else {
      throw DiagnosticModelError.invalidValue(field: "provider_build_digests")
    }
    for (provider, digest) in providerBuildDigests {
      try ModelValidation.identifier(provider, field: "provider_build_digests.provider")
      try ModelValidation.identifier(digest, field: "provider_build_digests.digest")
    }
    for (field, value) in [
      "test_plan": testPlan, "scenario": scenario, "runner": runner, "release_ring": releaseRing
    ] {
      if let value { try ModelValidation.identifier(value, field: field) }
    }
    self.requestID = requestID
    self.operationID = operationID
    self.sessionID = sessionID
    self.gameID = gameID
    self.buildID = buildID
    self.hostClassID = hostClassID
    self.runtimeGenerationID = runtimeGenerationID
    self.profileID = profileID
    self.profileRevision = profileRevision
    self.processPolicyID = processPolicyID
    self.providerBuildDigests = providerBuildDigests
    self.testPlan = testPlan
    self.scenario = scenario
    self.runner = runner
    self.releaseRing = releaseRing
  }

  public init(from decoder: any Decoder) throws {
    try ModelValidation.rejectUnknownKeys(decoder, allowed: CodingKeys.self)
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      requestID: values.decode(String.self, forKey: .requestID),
      operationID: values.decode(String.self, forKey: .operationID),
      sessionID: values.decode(String.self, forKey: .sessionID),
      gameID: values.decode(String.self, forKey: .gameID),
      buildID: values.decode(String.self, forKey: .buildID),
      hostClassID: values.decode(String.self, forKey: .hostClassID),
      runtimeGenerationID: values.decode(String.self, forKey: .runtimeGenerationID),
      profileID: values.decode(String.self, forKey: .profileID),
      profileRevision: values.decode(String.self, forKey: .profileRevision),
      processPolicyID: values.decode(String.self, forKey: .processPolicyID),
      providerBuildDigests: values.decode([String: String].self, forKey: .providerBuildDigests),
      testPlan: values.decodeIfPresent(String.self, forKey: .testPlan),
      scenario: values.decodeIfPresent(String.self, forKey: .scenario),
      runner: values.decodeIfPresent(String.self, forKey: .runner),
      releaseRing: values.decodeIfPresent(String.self, forKey: .releaseRing)
    )
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case requestID = "request_id"
    case operationID = "operation_id"
    case sessionID = "session_id"
    case gameID = "game_id"
    case buildID = "build_id"
    case hostClassID = "host_class_id"
    case runtimeGenerationID = "runtime_generation_id"
    case profileID = "profile_id"
    case profileRevision = "profile_revision"
    case processPolicyID = "process_policy_id"
    case providerBuildDigests = "provider_build_digests"
    case testPlan = "test_plan"
    case scenario
    case runner
    case releaseRing = "release_ring"
  }
}

public enum DiagnosticModelError: Error, Equatable, Sendable {
  case invalidValue(field: String)
  case unknownField(String)
  case unsupportedSchemaVersion(Int)
}

enum ModelValidation {
  static func identifier(_ value: String, field: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw DiagnosticModelError.invalidValue(field: field)
    }
  }

  static func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(
    _ decoder: any Decoder,
    allowed: Keys.Type
  ) throws {
    let container = try decoder.container(keyedBy: AnyKey.self)
    let known = Set(allowed.allCases.map(\.stringValue))
    for key in container.allKeys where !known.contains(key.stringValue) {
      throw DiagnosticModelError.unknownField(key.stringValue)
    }
  }

  private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
}

public enum DiagnosticsJSON {
  /// Stable JSON for fixtures and local records, without changing caller string values.
  public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}
