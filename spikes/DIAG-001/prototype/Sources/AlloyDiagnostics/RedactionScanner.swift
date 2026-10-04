// Author: Timur Isaev

import Foundation

public enum RedactionError: Error, Equatable, Sendable {
  case invalidLimit
  case inputTooLarge(limit: Int)
  case outputTooLarge(limit: Int)
  case invalidUTF8
  case missingClassification
  case unsafeMetadata(field: String)
}

public enum RedactionLimits {
  public static let defaultMaxUTF8Bytes = 1_048_576
}

/// Aggregate detections only. No original value, location, or surrounding source is retained.
public struct RedactionFinding: Codable, Equatable, Sendable {
  public let dataClass: DataClass
  public let count: Int

  public init(dataClass: DataClass, count: Int) {
    self.dataClass = dataClass
    self.count = count
  }
}

public struct RedactionScanResult: Equatable, Sendable {
  public let text: String
  public let findings: [RedactionFinding]
}

/// Recognizes a documented, bounded set of textual patterns; classification remains required.
public enum RedactionScanner {
  public static func scan(
    _ text: String,
    maxUTF8Bytes: Int = RedactionLimits.defaultMaxUTF8Bytes
  ) throws -> RedactionScanResult {
    try RedactionSupport.checkSize(text.utf8.count, limit: maxUTF8Bytes)
    let source = text as NSString
    let fullRange = NSRange(location: 0, length: source.length)
    var counts: [DataClass: Int] = [:]
    var ranges: [NSRange] = []
    for rule in rules {
      let expression = try NSRegularExpression(pattern: rule.pattern)
      let matches = expression.matches(in: text, range: fullRange)
      if !matches.isEmpty {
        counts[rule.dataClass, default: 0] += matches.count
        ranges += matches.map(\.range)
      }
    }
    guard !ranges.isEmpty else { return RedactionScanResult(text: text, findings: []) }
    let redacted = replacingRanges(ranges, in: source)
    guard redacted.utf8.count <= maxUTF8Bytes else { throw RedactionError.outputTooLarge(limit: maxUTF8Bytes) }
    return RedactionScanResult(text: redacted, findings: RedactionSupport.findings(counts))
  }

  private struct Rule {
    let dataClass: DataClass
    let pattern: String
  }

  private static var rules: [Rule] {
    let separator = #"(?:\\*/+|\\+|%2f|%5c)"#
    let home = "(?:" + encodedWord("users") + "|" + encodedWord("home") + ")"
    return [
      Rule(
        dataClass: .credentials,
        pattern: #"(?i)["']?(?:api[_-]?key|password|passwd|pwd|client[_-]?secret|secret|access[_-]?key)"#
          + #"["']?\s*[:=]\s*["']?[^\s"'&,;<>{}\[\]\\]+"#
      ),
      Rule(
        dataClass: .credentials,
        pattern: #"(?:sk_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[A-Z0-9]{16}|AIza[0-9A-Za-z_-]{30,}|"#
          + #"gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,})"#
      ),
      Rule(dataClass: .credentials, pattern: #"(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![0-9])"#),
      Rule(
        dataClass: .tokensCookies,
        pattern: #"(?i)bearer\s+[A-Za-z0-9._~+/-]+=*"#
      ),
      Rule(
        dataClass: .tokensCookies,
        pattern: #"(?i)["']?(?:access[_-]?token|refresh[_-]?token|id[_-]?token|token|session[_-]?id)"#
          + #"["']?\s*[:=]\s*["']?[^\s"'&,;<>{}\[\]\\]+"#
      ),
      Rule(dataClass: .tokensCookies, pattern: #"(?i)(?:set-cookie|cookie)\s*:\s*[^\r\n]+"#),
      Rule(dataClass: .tokensCookies, pattern: #"eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}"#),
      Rule(
        dataClass: .homePaths,
        pattern: "(?i)(?:[a-z](?::|%3a))?" + separator + home + separator + #"[^\s"'<>;,]+"#
      ),
      Rule(dataClass: .sensitiveURLs, pattern: #"(?i)https?://[^\s"'<>]*[?#][^\s"'<>]+"#),
      Rule(dataClass: .sensitiveURLs, pattern: #"(?i)https?://[^\s"'<>/@]+@[^\s"'<>]+"#),
      Rule(dataClass: .saveGameContent, pattern: #"(?is)<(save(?:[_-]content)?)>.*?</\1>"#),
      Rule(dataClass: .saveGameContent, pattern: #"SAVE_CONTENT\[[^\]]+\]"#),
      Rule(dataClass: .chatVoiceContent, pattern: #"(?is)<chat>.*?</chat>"#),
      Rule(dataClass: .chatVoiceContent, pattern: #"CHAT_CONTENT\[[^\]]+\]"#),
      Rule(
        dataClass: .usernames,
        pattern: #"(?i)["']?user[_-]?name["']?\s*[:=]\s*["']?[^\s"'&,;<>{}\[\]\\]+"#
      )
    ]
  }

  private static func encodedWord(_ word: String) -> String {
    word.unicodeScalars.map { scalar in
      let lower = String(format: "%%%02x", scalar.value)
      let upper = String(format: "%%%02x", scalar.value - 32)
      return "(?:\(scalar)|\(lower)|\(upper))"
    }.joined()
  }

  private static func replacingRanges(_ ranges: [NSRange], in source: NSString) -> String {
    let ordered = ranges.sorted { $0.location < $1.location }
    var merged: [NSRange] = []
    for range in ordered {
      if let last = merged.last, range.location <= NSMaxRange(last) {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    var fragments: [String] = []
    var cursor = 0
    for range in merged {
      fragments.append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
      fragments.append("[REDACTED]")
      cursor = NSMaxRange(range)
    }
    fragments.append(source.substring(from: cursor))
    return fragments.joined()
  }
}

enum RedactionSupport {
  static let sensitiveClasses: Set<DataClass> = [
    .saveGameContent, .chatVoiceContent, .gameplayVideo, .screenshots, .homePaths,
    .credentials, .moduleProcessFileInventory, .usernames, .tokensCookies, .sensitiveURLs
  ]

  static func checkSize(_ count: Int, limit: Int) throws {
    guard limit > 0 else { throw RedactionError.invalidLimit }
    guard count <= limit else { throw RedactionError.inputTooLarge(limit: limit) }
  }

  static func findings(_ counts: [DataClass: Int]) -> [RedactionFinding] {
    counts.keys.sorted { $0.rawValue < $1.rawValue }.map {
      RedactionFinding(dataClass: $0, count: counts[$0, default: 0])
    }
  }
}
