// Author: Timur Isaev

import Foundation

public struct RedactionFuzzReport: Codable, Equatable, Sendable {
  public let seed: UInt64
  public let plantedCount: Int
  public let survivingCount: Int
  public let findingCount: Int
  public var catchRate: Double { Double(plantedCount - survivingCount) / Double(plantedCount) }
}

/// Reproducible grammar fuzzing of synthetic secrets, without returning generated secret values.
public enum RedactionFuzzer {
  public static func run(seed: UInt64, iterations: Int = 240) throws -> RedactionFuzzReport {
    guard (1...2_000).contains(iterations) else { throw RedactionError.invalidLimit }
    var random = RedactionRandom(state: seed)
    var secrets: [String] = []
    var members: [String] = []
    for index in 0..<iterations {
      let secret = syntheticSecret(index: index, random: &random)
      let padding = random.string(length: 40 + Int(random.next() % 180), alphabet: Array("abcdefghXYZ ._-/\t"))
      let offset = Int(random.next() % UInt64(padding.utf8.count + 1))
      let insertion = padding.index(padding.startIndex, offsetBy: offset)
      members.append(String(padding[..<insertion]) + secret.payload + String(padding[insertion...]))
      secrets.append(secret.value)
    }
    let result = try RedactionScanner.scan(members.joined(separator: "\n"))
    return RedactionFuzzReport(
      seed: seed, plantedCount: secrets.count,
      survivingCount: secrets.filter { result.text.contains($0) }.count,
      findingCount: result.findings.reduce(0) { $0 + $1.count }
    )
  }

  private static func syntheticSecret(index: Int, random: inout RedactionRandom) -> (payload: String, value: String) {
    let token = "fuzz_" + random.string(
      length: 32, alphabet: Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    )
    switch index % 12 {
    case 0:
      return ("api_key=" + token, token)
    case 1:
      let digits = random.string(length: 16, alphabet: Array("0123456789"))
      return (digits, digits)
    case 2:
      let value = "/Users/" + token + "/Documents/save.bin"
      return (value, value)
    case 3:
      let value = "C:\\Users\\" + token + "\\SavedGames\\state.bin"
      return (value, value)
    case 4:
      let value = "%2FUsers%2F" + token + "%2FDocuments%2Fstate.bin"
      return (value, value)
    case 5:
      let value = "C%3A%5CUsers%5C" + token + "%5CSavedGames%5Cstate.bin"
      return (value, value)
    default:
      return syntheticContent(index: index, token: token)
    }
  }

  private static func syntheticContent(index: Int, token: String) -> (payload: String, value: String) {
    switch index % 12 {
    case 6:
      let value = "https://synthetic.invalid/report?secret=" + token
      return (value, value)
    case 7:
      return ("Bearer " + token, token)
    case 8:
      return ("Cookie: session=" + token, token)
    case 9:
      return ("<save>" + token + "</save>", token)
    case 10:
      return ("<chat>" + token + "</chat>", token)
    default:
      return ("user_name=" + token, token)
    }
  }
}

private struct RedactionRandom {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9e3779b97f4a7c15
    var value = state
    value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
    value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
    return value ^ (value >> 31)
  }

  mutating func string(length: Int, alphabet: [Character]) -> String {
    String((0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
  }
}
