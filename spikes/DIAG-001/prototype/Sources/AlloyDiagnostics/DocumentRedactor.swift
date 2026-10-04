// Author: Timur Isaev

import Foundation

public struct DocumentRedactionResult: Equatable, Sendable {
  public let data: Data?
  public let retainedClasses: Set<DataClass>
  public let removedClasses: Set<DataClass>
  public let findings: [RedactionFinding]
}

public enum DocumentRedactor {
  public static func redact(
    _ data: Data,
    declaredClasses: Set<DataClass>,
    maxUTF8Bytes: Int = RedactionLimits.defaultMaxUTF8Bytes
  ) throws -> DocumentRedactionResult {
    try RedactionSupport.checkSize(data.count, limit: maxUTF8Bytes)
    guard !declaredClasses.isEmpty else { throw RedactionError.missingClassification }
    let sensitive = declaredClasses.intersection(RedactionSupport.sensitiveClasses)
    if !sensitive.isEmpty {
      return DocumentRedactionResult(
        data: nil, retainedClasses: [], removedClasses: declaredClasses, findings: []
      )
    }
    guard let text = String(data: data, encoding: .utf8) else { throw RedactionError.invalidUTF8 }
    let result = try RedactionScanner.scan(text, maxUTF8Bytes: maxUTF8Bytes)
    return DocumentRedactionResult(
      data: result.findings.isEmpty ? data : Data(result.text.utf8),
      retainedClasses: declaredClasses,
      removedClasses: Set(result.findings.map(\.dataClass)),
      findings: result.findings
    )
  }
}
