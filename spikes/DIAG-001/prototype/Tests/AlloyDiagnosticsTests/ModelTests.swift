// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyDiagnostics

@Suite("Diagnostics model")
struct ModelTests {
  @Test("literal event fixture pins every wire key and value")
  func goldenFixture() throws {
    let fixture = try modelFixtureBytes()
    let event = try modelTestEvent()
    #expect(try DiagnosticsJSON.encode(event) == fixture)
    let decoded = try JSONDecoder().decode(StructuredEvent.self, from: fixture)
    #expect(decoded == event)
    #expect(try DiagnosticsJSON.encode(decoded) == fixture)
  }

  @Test("correlation groups round trip without optional lab context")
  func standaloneCorrelationRoundTrip() throws {
    let correlation = try modelTestCorrelation(includeLab: false)
    let bytes = try DiagnosticsJSON.encode(correlation)
    #expect(try JSONDecoder().decode(CorrelationID.self, from: bytes) == correlation)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(Set(object.keys) == Set([
      "request_id", "operation_id", "session_id", "game_id", "build_id", "host_class_id",
      "runtime_generation_id", "profile_id", "profile_revision", "process_policy_id", "provider_build_digests"
    ]))
  }

  @Test("each required correlation member is necessary when decoding")
  func requiredIdentities() throws {
    let bytes = try DiagnosticsJSON.encode(modelTestCorrelation(includeLab: false))
    let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    for key in original.keys {
      var missing = original
      missing.removeValue(forKey: key)
      let changed = try JSONSerialization.data(withJSONObject: missing)
      #expect(throws: (any Error).self) { try JSONDecoder().decode(CorrelationID.self, from: changed) }
    }
  }

  @Test("missing classification and invented classifications fail closed")
  func fieldClassificationRequired() throws {
    for fixture in [
      #"{"name":"sample","value":"text"}"#,
      #"{"name":"sample","value":"text","data_class":"public"}"#,
      #"{"name":"sample","value":"text","data_class":"credentials","unchecked":"secret"}"#
    ] {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(EventField.self, from: Data(fixture.utf8))
      }
    }
    for dataClass in DataClass.allCases {
      let field = try EventField(name: "sample", value: "", dataClass: dataClass)
      #expect(try JSONDecoder().decode(EventField.self, from: DiagnosticsJSON.encode(field)) == field)
    }
  }

  @Test("unknown envelope and nested identity fields are not silently discarded")
  func unknownFieldsRejected() throws {
    var event = try #require(JSONSerialization.jsonObject(with: modelFixtureBytes()) as? [String: Any])
    event["unclassified"] = "sensitive value"
    let unknownEnvelope = try JSONSerialization.data(withJSONObject: event)
    #expect(throws: DiagnosticModelError.unknownField("unclassified")) {
      try JSONDecoder().decode(StructuredEvent.self, from: unknownEnvelope)
    }
    event.removeValue(forKey: "unclassified")
    var correlation = try #require(event["correlation"] as? [String: Any])
    correlation["unclassified"] = "sensitive value"
    event["correlation"] = correlation
    let unknownIdentity = try JSONSerialization.data(withJSONObject: event)
    #expect(throws: DiagnosticModelError.unknownField("unclassified")) {
      try JSONDecoder().decode(StructuredEvent.self, from: unknownIdentity)
    }
  }

  @Test("unsupported schemas and invalid fields are rejected on decode")
  func malformedModelsRejected() throws {
    var event = try #require(JSONSerialization.jsonObject(with: modelFixtureBytes()) as? [String: Any])
    event["schema_version"] = 2
    let changedVersion = try JSONSerialization.data(withJSONObject: event)
    #expect(throws: DiagnosticModelError.unsupportedSchemaVersion(2)) {
      try JSONDecoder().decode(StructuredEvent.self, from: changedVersion)
    }
    event["schema_version"] = 1
    event["timestamp_unix_milliseconds"] = -1
    let changedTime = try JSONSerialization.data(withJSONObject: event)
    #expect(throws: DiagnosticModelError.invalidValue(field: "timestamp_unix_milliseconds")) {
      try JSONDecoder().decode(StructuredEvent.self, from: changedTime)
    }
    #expect(throws: DiagnosticModelError.invalidValue(field: "fields.name")) {
      try EventField(name: "\n", value: "irrelevant", dataClass: .credentials)
    }
    let field = try EventField(name: "same", value: "value", dataClass: .runtimeOutcome)
    #expect(throws: DiagnosticModelError.invalidValue(field: "fields.duplicate_name")) {
      try StructuredEvent(
        eventCode: "test", timestampUnixMilliseconds: 0,
        correlation: modelTestCorrelation(), fields: [field, field]
      )
    }
  }

  @Test("invalid correlation values cannot bypass construction through decoding")
  func invalidCorrelationRejected() throws {
    let bytes = try DiagnosticsJSON.encode(modelTestCorrelation(includeLab: false))
    let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    for key in original.keys where key != "provider_build_digests" {
      for invalid in ["", "   ", "injected\nline"] {
        var changed = original
        changed[key] = invalid
        let data = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: DiagnosticModelError.invalidValue(field: key)) {
          try JSONDecoder().decode(CorrelationID.self, from: data)
        }
      }
    }
    var changed = original
    changed["provider_build_digests"] = [String: String]()
    let emptyDigests = try JSONSerialization.data(withJSONObject: changed)
    #expect(throws: DiagnosticModelError.invalidValue(field: "provider_build_digests")) {
      try JSONDecoder().decode(CorrelationID.self, from: emptyDigests)
    }
  }

  @Test("consent levels preserve all four mechanisms without selecting a default")
  func consentLevels() throws {
    #expect(ConsentLevel.allCases.map(\.rawValue) == ["off", "essential", "diagnostic", "lab"])
    for level in ConsentLevel.allCases {
      #expect(try JSONDecoder().decode(ConsentLevel.self, from: DiagnosticsJSON.encode(level)) == level)
    }
  }
}

func modelTestCorrelation(includeLab: Bool = true) throws -> CorrelationID {
  try CorrelationID(
    requestID: "request-0001", operationID: "operation-0002", sessionID: "session-0003",
    gameID: "game-synthetic", buildID: "build-42", hostClassID: "apple-silicon-16gb",
    runtimeGenerationID: "generation-4", profileID: "profile-synthetic", profileRevision: "3",
    processPolicyID: "process-policy-7",
    providerBuildDigests: [
      "cpu": "sha256:" + String(repeating: "1", count: 64),
      "graphics": "sha256:" + String(repeating: "2", count: 64)
    ],
    testPlan: includeLab ? "diagnostics-model-v1" : nil,
    scenario: includeLab ? "synthetic-launch" : nil,
    runner: includeLab ? "runner-offline" : nil,
    releaseRing: includeLab ? "lab" : nil
  )
}

private func modelTestEvent() throws -> StructuredEvent {
  try StructuredEvent(
    eventCode: "runtime.synthetic.complete", timestampUnixMilliseconds: 1_791_072_000_123,
    correlation: modelTestCorrelation(),
    fields: [
      EventField(name: "outcome", value: "clean_exit", dataClass: .runtimeOutcome),
      EventField(name: "code", value: "ALLOY_OK", dataClass: .errorCode)
    ]
  )
}

private func modelFixtureBytes() throws -> Data {
  let location = try #require(
    Bundle.module.url(forResource: "event-v1", withExtension: "json", subdirectory: "Fixtures")
  )
  let fixture = try Data(contentsOf: location)
  #expect(fixture.last == 0x0A)
  return fixture.dropLast()
}
