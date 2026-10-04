// Author: Timur Isaev

import Foundation

public enum DiagnosticCause: String, Codable, CaseIterable, Sendable {
  case profileMismatch = "profile_mismatch"
  case wrongProvider = "wrong_provider"
  case shaderCompilerCrash = "shader_compiler_crash"
  case permissionDenial = "permission_denial"
  case corruptCache = "corrupt_cache"
  case memoryPressure = "memory_pressure"
  case guestCrash = "guest_crash"
  case insufficientEvidence = "insufficient_evidence"
}

/// Classification consumes only already-verified bundle bytes. It never probes
/// the machine or receives the injection plan, fixture name, or expected answer.
public enum FailureClassifier {
  public static func classify(_ bundle: SealedBundle) -> DiagnosticCause {
    guard let identity = bundle.events.first?.correlation,
          bundle.events.allSatisfy({ $0.correlation == identity }) else { return .insufficientEvidence }
    let candidates = Set(bundle.events.compactMap(classifyEvent))
    return candidates.count == 1 ? candidates.first ?? .insufficientEvidence : .insufficientEvidence
  }

  private static func classifyEvent(_ event: StructuredEvent) -> DiagnosticCause? {
    switch event.eventCode {
    case "profile_resolution":
      return differs(event, "expected_profile", "resolved_profile", .gameProfileIdentifiers) ? .profileMismatch : nil
    case "provider_verification":
      return differs(event, "expected_digest", "loaded_digest", .componentVersions) ? .wrongProvider : nil
    case "cache_verification":
      return differs(event, "expected_digest", "observed_digest", .metadataVerification) ? .corruptCache : nil
    case "file_access":
      return value(event, "operation", .runtimeOutcome) == "read"
        && value(event, "errno", .errorCode) == "13" ? .permissionDenial : nil
    case "allocation":
      guard value(event, "result", .runtimeOutcome) == "quota_exhausted",
            let requested = value(event, "requested_bytes", .runtimeOutcome).flatMap(Int.init),
            let available = value(event, "available_bytes", .runtimeOutcome).flatMap(Int.init),
            available >= 0, requested > available else { return nil }
      return .memoryPressure
    case "native_termination":
      return nativeCause(event)
    default: return nil
    }
  }

  private static func nativeCause(_ event: StructuredEvent) -> DiagnosticCause? {
    guard value(event, "observed", .runtimeOutcome) == "symbolicated_fatal_error",
          value(event, "site", .runtimeOutcome) == "seededNativeCrash" else { return nil }
    switch value(event, "process_role", .runtimeOutcome) {
    case "shader_compiler": return .shaderCompilerCrash
    case "guest": return .guestCrash
    default: return nil
    }
  }

  private static func differs(_ event: StructuredEvent, _ first: String, _ second: String, _ kind: DataClass) -> Bool {
    guard let expected = value(event, first, kind), let actual = value(event, second, kind),
          !expected.isEmpty, !actual.isEmpty, !expected.contains("[REDACTED]"), !actual.contains("[REDACTED]") else {
      return false
    }
    return expected != actual
  }

  private static func value(_ event: StructuredEvent, _ name: String, _ kind: DataClass) -> String? {
    event.fields.first { $0.name == name && $0.dataClass == kind }?.value
  }
}
