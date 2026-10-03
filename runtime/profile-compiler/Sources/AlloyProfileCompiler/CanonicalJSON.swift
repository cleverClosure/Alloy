// Author: Timur Isaev

import CryptoKit
import Foundation

public enum CompilerFailure: Error, Equatable, Sendable {
    case rejected(String)
}

/// Bounded, duplicate-aware JSON canonicalization. See Specs/CANONICALIZATION_V1.md.
public enum CanonicalJSON {
    public static let version = "alloy-jcs-v1"

    public static func encode(_ input: Data) throws -> Data {
        guard input.count <= 4 * 1024 * 1024 else { throw CompilerFailure.rejected("JSON exceeds 4 MiB") }
        var parser = CanonicalParser(bytes: Array(input))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else { throw CompilerFailure.rejected("trailing JSON input") }
        return Data(result.utf8)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encode(JSONEncoder().encode(value))
    }

    public static func digest(_ bytes: Data) -> String {
        "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func quote(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 8: output += "\\b"
            case 9: output += "\\t"
            case 10: output += "\\n"
            case 12: output += "\\f"
            case 13: output += "\\r"
            case 34: output += "\\\""
            case 92: output += "\\\\"
            case 0..<32: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    // Swift supplies the shortest round-tripping binary64 digits; ECMAScript
    // differs in the decimal/scientific threshold and exponent punctuation.
    static func number(_ number: Double) throws -> String {
        guard number.isFinite else { throw CompilerFailure.rejected("non-finite JSON number") }
        if number == 0 { return "0" }
        let sign = number < 0 ? "-" : ""
        let parts = String(abs(number)).lowercased().split(separator: "e")
        let exponent = parts.count == 2 ? Int(parts[1])! : 0
        let mantissa = parts[0].split(separator: ".")
        var digits = mantissa.joined()
        var point = mantissa[0].count + exponent
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        if point > 0 && point <= 21 {
            if point >= digits.count {
                return sign + digits + String(repeating: "0", count: point - digits.count)
            }
            let split = digits.index(digits.startIndex, offsetBy: point)
            return sign + digits[..<split] + "." + digits[split...]
        }
        if point <= 0 && point > -6 {
            return sign + "0." + String(repeating: "0", count: -point) + digits
        }
        let tail = digits.dropFirst()
        let fraction = tail.isEmpty ? "" : "." + tail
        let power = point - 1
        return sign + digits.prefix(1) + fraction + "e" + (power >= 0 ? "+" : "") + String(power)
    }
}

private struct CanonicalParser {
    let bytes: [UInt8]
    var offset = 0

    mutating func whitespace() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else { throw CompilerFailure.rejected("invalid JSON at byte \(offset)") }
    }

    mutating func value(depth: Int) throws -> String {
        guard depth <= 64 else { throw CompilerFailure.rejected("JSON nesting exceeds 64") }
        whitespace()
        guard offset < bytes.count else { throw CompilerFailure.rejected("truncated JSON") }
        switch bytes[offset] {
        case 123: return try object(depth: depth + 1)
        case 91: return try array(depth: depth + 1)
        case 34: return CanonicalJSON.quote(try string())
        case 116: return try literal("true")
        case 102: return try literal("false")
        case 110: return try literal("null")
        default: return try number()
        }
    }

    mutating func object(depth: Int) throws -> String {
        offset += 1
        if consume(125) { return "{}" }
        var members: [(String, String)] = []
        var keys = Set<String>()
        repeat {
            let key = try string()
            guard keys.insert(key).inserted else {
                throw CompilerFailure.rejected("duplicate or Unicode-equivalent JSON key: \(key)")
            }
            try require(58)
            members.append((key, try value(depth: depth)))
        } while consume(44)
        try require(125)
        let sorted = members.sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }
        return "{" + sorted.map { CanonicalJSON.quote($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    mutating func array(depth: Int) throws -> String {
        offset += 1
        if consume(93) { return "[]" }
        var elements: [String] = []
        repeat { elements.append(try value(depth: depth)) } while consume(44)
        try require(93)
        return "[" + elements.joined(separator: ",") + "]"
    }

    mutating func string() throws -> String {
        whitespace()
        let start = offset
        try require(34)
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 92 {
                offset += 1
            } else if byte == 34 {
                // Foundation checks UTF-8, escape syntax, and surrogate pairing.
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
        }
        throw CompilerFailure.rejected("unterminated JSON string")
    }

    mutating func literal(_ literal: String) throws -> String {
        let expected = Array(literal.utf8)
        guard offset + expected.count <= bytes.count,
              Array(bytes[offset..<(offset + expected.count)]) == expected else {
            throw CompilerFailure.rejected("invalid JSON literal")
        }
        offset += expected.count
        return literal
    }

    mutating func number() throws -> String {
        let start = offset
        while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
        guard let token = String(bytes: bytes[start..<offset], encoding: .utf8) else {
            throw CompilerFailure.rejected("invalid UTF-8 in number")
        }
        let pattern = #"\A-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?\z"#
        guard token.range(of: pattern, options: .regularExpression) != nil, let number = Double(token) else {
            throw CompilerFailure.rejected("invalid JSON number at byte \(start)")
        }
        return try CanonicalJSON.number(number)
    }
}
