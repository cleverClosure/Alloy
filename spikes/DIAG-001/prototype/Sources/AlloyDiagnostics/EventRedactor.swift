// Author: Timur Isaev

import Foundation

public struct EventRedactionResult: Equatable, Sendable {
  public let event: StructuredEvent
  public let removedClasses: Set<DataClass>
  public let findings: [RedactionFinding]
}

public enum EventRedactor {
  public static func redact(
    _ event: StructuredEvent,
    maxUTF8Bytes: Int = RedactionLimits.defaultMaxUTF8Bytes
  ) throws -> EventRedactionResult {
    try RedactionSupport.checkSize(0, limit: maxUTF8Bytes)
    let metadata = metadataValues(event)
    try checkRawSize(event, metadata: metadata, limit: maxUTF8Bytes)
    try RedactionSupport.checkSize(try DiagnosticsJSON.encode(event).count, limit: maxUTF8Bytes)
    for (name, value) in metadata {
      let result = try RedactionScanner.scan(value, maxUTF8Bytes: maxUTF8Bytes)
      guard result.findings.isEmpty else { throw RedactionError.unsafeMetadata(field: name) }
    }
    var fields: [EventField] = []
    var removed: Set<DataClass> = []
    var counts: [DataClass: Int] = [:]
    for field in event.fields {
      if RedactionSupport.sensitiveClasses.contains(field.dataClass) {
        removed.insert(field.dataClass)
        continue
      }
      let result = try RedactionScanner.scan(field.value, maxUTF8Bytes: maxUTF8Bytes)
      fields.append(try EventField(name: field.name, value: result.text, dataClass: field.dataClass))
      for finding in result.findings {
        counts[finding.dataClass, default: 0] += finding.count
        removed.insert(finding.dataClass)
      }
    }
    let result = try StructuredEvent(
      eventCode: event.eventCode, timestampUnixMilliseconds: event.timestampUnixMilliseconds,
      correlation: event.correlation, fields: fields
    )
    guard try DiagnosticsJSON.encode(result).count <= maxUTF8Bytes else {
      throw RedactionError.outputTooLarge(limit: maxUTF8Bytes)
    }
    return EventRedactionResult(event: result, removedClasses: removed, findings: RedactionSupport.findings(counts))
  }

  private static func metadataValues(_ event: StructuredEvent) -> [(String, String)] {
    let correlation = event.correlation
    var metadata: [(String, String)] = [
      ("event_code", event.eventCode), ("request_id", correlation.requestID),
      ("operation_id", correlation.operationID), ("session_id", correlation.sessionID),
      ("game_id", correlation.gameID), ("build_id", correlation.buildID),
      ("host_class_id", correlation.hostClassID), ("runtime_generation_id", correlation.runtimeGenerationID),
      ("profile_id", correlation.profileID), ("profile_revision", correlation.profileRevision),
      ("process_policy_id", correlation.processPolicyID)
    ]
    for (name, value) in [
      "test_plan": correlation.testPlan, "scenario": correlation.scenario,
      "runner": correlation.runner, "release_ring": correlation.releaseRing
    ] {
      if let value { metadata.append((name, value)) }
    }
    for (name, value) in correlation.providerBuildDigests {
      metadata.append(("provider_build_digests.key", name))
      metadata.append(("provider_build_digests.value", value))
    }
    metadata += event.fields.map { ("fields.name", $0.name) }
    return metadata
  }

  private static func checkRawSize(
    _ event: StructuredEvent,
    metadata: [(String, String)],
    limit: Int
  ) throws {
    var remaining = limit
    for (_, value) in metadata {
      let count = value.utf8.count
      guard count <= remaining else { throw RedactionError.inputTooLarge(limit: limit) }
      remaining -= count
    }
    for field in event.fields {
      let count = field.value.utf8.count
      guard count <= remaining else { throw RedactionError.inputTooLarge(limit: limit) }
      remaining -= count
    }
  }
}
