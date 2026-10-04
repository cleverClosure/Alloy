// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyDiagnostics

@Suite("Document-derived privacy taxonomy")
struct TaxonomyTests {
  @Test("every category in security doc sections 17.1 and 18 has exactly one case")
  func exhaustiveDocumentCoverage() throws {
    let document = try String(contentsOf: securityDocumentURL(), encoding: .utf8)
    let categories = try documentedCategories(document)
    let assignments = DataClass.allCases.flatMap { dataClass in
      dataClass.references.map { (reference: $0, dataClass: dataClass) }
    }
    #expect(!categories.isEmpty)
    #expect(Set(categories).count == categories.count)
    for category in categories {
      let matches = assignments.filter { $0.reference == category }
      #expect(matches.count == 1, "Expected exactly one mapping for §\(category.section): \(category.category)")
    }
    #expect(Set(assignments.map(\.reference)) == Set(categories))
    for dataClass in DataClass.allCases {
      #expect(!dataClass.references.isEmpty, "Missing source citation for \(dataClass.rawValue)")
    }
    #expect(DataClass.allCases.count == 17)
    #expect(categories.count == 21)
  }

  @Test("adding a document category exposes missing taxonomy coverage")
  func coverageHasPositiveFailureControl() throws {
    let document = try String(contentsOf: securityDocumentURL(), encoding: .utf8)
    let changed = document.replacingOccurrences(of: "- screenshots;", with: "- screenshots;\n- synthetic new category;")
    let references = Set(DataClass.allCases.flatMap(\.references))
    let missing = try documentedCategories(changed).filter { !references.contains($0) }
    #expect(missing == [.init(section: "17.1", category: "synthetic new category")])
  }

  @Test("the issue's seven privacy groups and documented visual/identity classes are represented")
  func requiredPrivacyGroups() {
    let required: Set<DataClass> = [
      .credentials, .homePaths, .chatVoiceContent, .sensitiveURLs,
      .saveGameContent, .tokensCookies, .moduleProcessFileInventory,
      .gameplayVideo, .screenshots, .usernames
    ]
    #expect(required.isSubset(of: Set(DataClass.allCases)))
  }
}

private func securityDocumentURL() throws -> URL {
  var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  for _ in 0..<8 {
    let candidate = directory.appendingPathComponent(DataCategoryReference.document)
    if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    directory.deleteLastPathComponent()
  }
  throw CocoaError(.fileNoSuchFile)
}

private func documentedCategories(_ document: String) throws -> [DataCategoryReference] {
  let minimization = try section(document, start: "### 17.1 ", end: "### 17.2 ")
  let bundle = try section(document, start: "## 18. ", end: "## 19. ")
  var result = bulletItems(minimization).map {
    DataCategoryReference(section: "17.1", category: $0)
  }
  let knownActions: Set<String> = [
    "generate locally", "enumerate files and data classes", "truncate/bound logs",
    "encrypt in transit and at rest", "display retention/support case link",
    "allow local-only export", "allow user deletion where applicable"
  ]
  for item in bulletItems(bundle) {
    if item.hasPrefix("redact ") {
      result += item.dropFirst("redact ".count).components(separatedBy: ", ").map {
        DataCategoryReference(section: "18", category: $0)
      }
    } else if item.hasPrefix("exclude ") {
      result.append(.init(section: "18", category: String(item.dropFirst("exclude ".count))))
    } else {
      #expect(knownActions.contains(item), "Review new §18 instruction for data categories: \(item)")
    }
  }
  return result
}

private func section(_ document: String, start: String, end: String) throws -> String {
  let startRange = try #require(document.range(of: start))
  let endRange = try #require(document.range(of: end, range: startRange.upperBound..<document.endIndex))
  return String(document[startRange.upperBound..<endRange.lowerBound])
}

private func bulletItems(_ section: String) -> [String] {
  section.components(separatedBy: .newlines).filter { $0.hasPrefix("- ") }.map {
    String($0.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: ";."))
  }
}
