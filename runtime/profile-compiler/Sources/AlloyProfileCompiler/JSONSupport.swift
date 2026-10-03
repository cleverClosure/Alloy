// Author: Timur Isaev

import Foundation

/// A rejection always names the exact offending location and the exact rule
/// it broke. "Invalid" is never a sufficient reason on its own: every case
/// here is specific enough to write the fixture that is known, by
/// construction, to trigger it.
public enum ValidationFailure: Error, CustomStringConvertible, Equatable, Sendable {
    /// The document (or a nested value) is not a JSON object where one is required.
    case notAnObject(path: String)
    /// A key present in the JSON has no corresponding schema property
    /// (`additionalProperties: false`).
    case unknownKey(path: String, key: String)
    /// A key listed in the schema's `required` array is absent.
    case missingRequiredKey(path: String, key: String)
    /// A value decoded to the wrong JSON type (e.g. a number where a string,
    /// or an object where an array, was required).
    case wrongType(path: String, expected: String)
    /// A `const` field did not hold its one fixed value.
    case constMismatch(path: String, expected: String, actual: String)
    /// A value fell outside the schema's `enum` list.
    case enumMismatch(path: String, allowed: [String], actual: String)
    /// A string failed its schema `pattern`.
    case patternMismatch(path: String, pattern: String, actual: String)
    /// A string failed a named `format` check (only `date-time` in these schemas).
    case formatMismatch(path: String, format: String, actual: String)
    /// A number fell below its schema `minimum`.
    case belowMinimum(path: String, minimum: Double, actual: Double)
    /// A number exceeded its schema `maximum`.
    case aboveMaximum(path: String, maximum: Double, actual: Double)
    /// An array held fewer entries than `minItems`.
    case tooFewItems(path: String, minimum: Int, actual: Int)
    /// An array marked `uniqueItems` held a repeated value.
    case duplicateItems(path: String)
    /// An object held fewer present properties than `minProperties`.
    case tooFewProperties(path: String, minimum: Int, actual: Int)
    /// None of an `anyOf` group's required keys were present.
    case noSelectorPresent(path: String, oneOf: [String])
    /// The payload could not be parsed as JSON at all, or some other
    /// decode failure occurred that none of the above cases name directly.
    case malformed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .notAnObject(path):
            "\(path): must be a JSON object"
        case let .unknownKey(path, key):
            "\(path): unknown key \"\(key)\" (additionalProperties: false)"
        case let .missingRequiredKey(path, key):
            "\(path): missing required key \"\(key)\""
        case let .wrongType(path, expected):
            "\(path): expected \(expected)"
        case let .constMismatch(path, expected, actual):
            "\(path): must equal \"\(expected)\", found \"\(actual)\""
        case let .enumMismatch(path, allowed, actual):
            "\(path): \"\(actual)\" is not one of \(allowed.sorted())"
        case let .patternMismatch(path, pattern, actual):
            "\(path): \"\(actual)\" does not match pattern \(pattern)"
        case let .formatMismatch(path, format, actual):
            "\(path): \"\(actual)\" is not a valid \(format)"
        case let .belowMinimum(path, minimum, actual):
            "\(path): \(actual) is below minimum \(minimum)"
        case let .aboveMaximum(path, maximum, actual):
            "\(path): \(actual) is above maximum \(maximum)"
        case let .tooFewItems(path, minimum, actual):
            "\(path): has \(actual) item(s), needs at least \(minimum)"
        case let .duplicateItems(path):
            "\(path): contains a duplicate item (uniqueItems: true)"
        case let .tooFewProperties(path, minimum, actual):
            "\(path): has \(actual) propert(y/ies), needs at least \(minimum)"
        case let .noSelectorPresent(path, oneOf):
            "\(path): must set at least one of \(oneOf)"
        case let .malformed(path, reason):
            "\(path): \(reason)"
        }
    }
}

/// Accepts any string as a coding key. Decoding a JSON object through this
/// key type and reading `allKeys` recovers every key actually present,
/// independent of which keys a specific `CodingKeys` enum declares. That is
/// the only reliable way to detect an `additionalProperties: false`
/// violation from inside a `Decodable.init(from:)` — `KeyedDecodingContainer`
/// never reports keys it was not asked about.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
}

/// Renders a `Decoder`'s `codingPath` as the `$.a.b[2].c` form every
/// `ValidationFailure` reports. Array indices arrive as `CodingKey`s whose
/// `intValue` is set; Foundation's `JSONDecoder` appends one automatically
/// for every element of an unkeyed (array) container.
func renderPath(_ codingPath: [CodingKey]) -> String {
    var result = "$"
    for key in codingPath {
        if let index = key.intValue {
            result += "[\(index)]"
        } else {
            result += ".\(key.stringValue)"
        }
    }
    return result
}

func renderPath(_ codingPath: [CodingKey], appending key: String) -> String {
    renderPath(codingPath) + "." + key
}

/// Looks up every key the JSON object at `decoder`'s current position
/// actually holds, checks it against `K`'s declared cases
/// (`additionalProperties: false`), checks every member of `required` is
/// present, and only then hands back a normal keyed container over `K`.
///
/// This is the strict-decoding core every schema-conformant `init(from:)`
/// in this package opens with.
func strictContainer<K>(
    _ decoder: Decoder,
    keyedBy keyType: K.Type,
    required: Set<K> = []
) throws -> KeyedDecodingContainer<K>
    where K: CodingKey & CaseIterable & RawRepresentable, K.RawValue == String {
    let discovery: KeyedDecodingContainer<AnyCodingKey>
    do {
        discovery = try decoder.container(keyedBy: AnyCodingKey.self)
    } catch {
        throw ValidationFailure.notAnObject(path: renderPath(decoder.codingPath))
    }
    let actualKeys = Set(discovery.allKeys.map(\.stringValue))
    let expectedKeys = Set(K.allCases.map(\.rawValue))
    // .min(), not .sorted().first: same result, SwiftLint's preferred spelling.
    if let unknown = actualKeys.subtracting(expectedKeys).min() {
        throw ValidationFailure.unknownKey(path: renderPath(decoder.codingPath), key: unknown)
    }
    let requiredNames = Set(required.map(\.rawValue))
    if let missing = requiredNames.subtracting(actualKeys).min() {
        throw ValidationFailure.missingRequiredKey(path: renderPath(decoder.codingPath), key: missing)
    }
    return try decoder.container(keyedBy: K.self)
}

extension KeyedDecodingContainer {
    /// Decodes a required value, translating any Foundation `DecodingError`
    /// (wrong JSON type, null where a value was required, …) into a typed
    /// `ValidationFailure`. A `ValidationFailure` thrown by a nested type's
    /// own `init(from:)` passes through unchanged, already naming its exact
    /// path.
    func requiredValue<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        at codingPath: [CodingKey],
        expected: String
    ) throws -> T {
        do {
            return try decode(type, forKey: key)
        } catch let failure as ValidationFailure {
            throw failure
        } catch {
            throw ValidationFailure.wrongType(
                path: renderPath(codingPath, appending: key.stringValue),
                expected: expected
            )
        }
    }

    /// Like `requiredValue`, but absence of the key is not an error — the
    /// caller has already decided the key is optional (it is not in
    /// `required`). A present `null` is still a type error: these schemas
    /// never declare `"type": "null"`.
    func optionalValue<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        at codingPath: [CodingKey],
        expected: String
    ) throws -> T? {
        guard contains(key) else { return nil }
        do {
            return try decode(type, forKey: key)
        } catch let failure as ValidationFailure {
            throw failure
        } catch {
            throw ValidationFailure.wrongType(
                path: renderPath(codingPath, appending: key.stringValue),
                expected: expected
            )
        }
    }

    func requiredConstString(
        _ expected: String,
        forKey key: Key,
        at codingPath: [CodingKey]
    ) throws -> String {
        let value = try requiredValue(String.self, forKey: key, at: codingPath, expected: "string")
        guard value == expected else {
            throw ValidationFailure.constMismatch(
                path: renderPath(codingPath, appending: key.stringValue),
                expected: expected,
                actual: value
            )
        }
        return value
    }

    func requiredPatternString(
        _ pattern: String,
        forKey key: Key,
        at codingPath: [CodingKey]
    ) throws -> String {
        let value = try requiredValue(String.self, forKey: key, at: codingPath, expected: "string")
        try checkPattern(pattern, value: value, path: renderPath(codingPath, appending: key.stringValue))
        return value
    }

    func optionalPatternString(
        _ pattern: String,
        forKey key: Key,
        at codingPath: [CodingKey]
    ) throws -> String? {
        guard let value = try optionalValue(String.self, forKey: key, at: codingPath, expected: "string") else {
            return nil
        }
        try checkPattern(pattern, value: value, path: renderPath(codingPath, appending: key.stringValue))
        return value
    }

    func requiredDateTimeString(
        forKey key: Key,
        at codingPath: [CodingKey]
    ) throws -> String {
        let value = try requiredValue(String.self, forKey: key, at: codingPath, expected: "string")
        try checkDateTime(value, path: renderPath(codingPath, appending: key.stringValue))
        return value
    }

    func optionalDateTimeString(
        forKey key: Key,
        at codingPath: [CodingKey]
    ) throws -> String? {
        guard let value = try optionalValue(String.self, forKey: key, at: codingPath, expected: "string") else {
            return nil
        }
        try checkDateTime(value, path: renderPath(codingPath, appending: key.stringValue))
        return value
    }

    func requiredEnum<E>(
        forKey key: Key,
        at codingPath: [CodingKey]
    ) throws -> E where E: RawRepresentable & CaseIterable, E.RawValue == String {
        let raw = try requiredValue(String.self, forKey: key, at: codingPath, expected: "string")
        guard let value = E(rawValue: raw) else {
            throw ValidationFailure.enumMismatch(
                path: renderPath(codingPath, appending: key.stringValue),
                allowed: E.allCases.map(\.rawValue).sorted(),
                actual: raw
            )
        }
        return value
    }

    func optionalEnum<E>(
        forKey key: Key,
        at codingPath: [CodingKey]
    ) throws -> E? where E: RawRepresentable & CaseIterable, E.RawValue == String {
        guard let raw = try optionalValue(String.self, forKey: key, at: codingPath, expected: "string") else {
            return nil
        }
        guard let value = E(rawValue: raw) else {
            throw ValidationFailure.enumMismatch(
                path: renderPath(codingPath, appending: key.stringValue),
                allowed: E.allCases.map(\.rawValue).sorted(),
                actual: raw
            )
        }
        return value
    }

    func requiredInt(
        forKey key: Key,
        at codingPath: [CodingKey],
        minimum: Int? = nil,
        maximum: Int? = nil
    ) throws -> Int {
        let value = try requiredValue(Int.self, forKey: key, at: codingPath, expected: "integer")
        try checkBounds(
            Double(value),
            minimum: minimum.map(Double.init),
            maximum: maximum.map(Double.init),
            path: renderPath(codingPath, appending: key.stringValue)
        )
        return value
    }

    func optionalInt(
        forKey key: Key,
        at codingPath: [CodingKey],
        minimum: Int? = nil,
        maximum: Int? = nil
    ) throws -> Int? {
        guard let value = try optionalValue(Int.self, forKey: key, at: codingPath, expected: "integer") else {
            return nil
        }
        try checkBounds(
            Double(value),
            minimum: minimum.map(Double.init),
            maximum: maximum.map(Double.init),
            path: renderPath(codingPath, appending: key.stringValue)
        )
        return value
    }

    func optionalDouble(
        forKey key: Key,
        at codingPath: [CodingKey],
        minimum: Double? = nil,
        maximum: Double? = nil
    ) throws -> Double? {
        guard let value = try optionalValue(Double.self, forKey: key, at: codingPath, expected: "number") else {
            return nil
        }
        try checkBounds(
            value, minimum: minimum, maximum: maximum, path: renderPath(codingPath, appending: key.stringValue)
        )
        return value
    }

    func optionalBool(
        forKey key: Key,
        at codingPath: [CodingKey]
    ) throws -> Bool? {
        try optionalValue(Bool.self, forKey: key, at: codingPath, expected: "boolean")
    }

    /// Decodes an `additionalProperties: {"enum": [...]}` map: arbitrary
    /// string keys (a DLL basename, here) whose values must each be one of a
    /// fixed enum. Reports a bad value against the specific map key, not the
    /// map as a whole.
    func optionalEnumMap<E>(
        forKey key: Key,
        at codingPath: [CodingKey]
    ) throws -> [String: E]? where E: RawRepresentable & CaseIterable, E.RawValue == String {
        guard let raw = try optionalValue(
            [String: String].self,
            forKey: key,
            at: codingPath,
            expected: "object of string"
        ) else {
            return nil
        }
        var result: [String: E] = [:]
        for mapKey in raw.keys.sorted() {
            let rawValue = raw[mapKey]!
            guard let value = E(rawValue: rawValue) else {
                throw ValidationFailure.enumMismatch(
                    path: renderPath(codingPath, appending: key.stringValue) + ".\(mapKey)",
                    allowed: E.allCases.map(\.rawValue).sorted(),
                    actual: rawValue
                )
            }
            result[mapKey] = value
        }
        return result
    }
}

/// Every regular-expression `pattern` used by the two schemas, named once so
/// the validator and its tests never retype a magic string inconsistently.
enum SchemaPattern {
    static let profileId = "^[a-z0-9][a-z0-9._-]{2,127}$"
    static let digestWithAlgorithm = "^sha256:[0-9a-f]{64}$"
    static let hexDigest64 = "^[0-9a-f]{64}$"
    static let driveLetter = "^[A-Z]$"
    static let generationId = "^rtg_[a-zA-Z0-9_-]{16,96}$"
}

private func checkPattern(_ pattern: String, value: String, path: String) throws {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        throw ValidationFailure.malformed(path: path, reason: "internal: bad pattern \(pattern)")
    }
    let range = NSRange(value.startIndex..., in: value)
    // Every pattern in these two schemas is anchored with ^...$, but ICU's
    // `$` (unlike ECMA-262's, which is what JSON Schema `pattern` means) still
    // matches just before a single trailing line terminator even without the
    // multiline option. So "found a match" is not "the whole string matches":
    // "abc\n" matches ^[a-z]+$ at range {0,3}, not the full {0,4}. Requiring
    // the match to span the entire string closes that gap.
    guard let match = regex.firstMatch(in: value, range: range), match.range == range else {
        throw ValidationFailure.patternMismatch(path: path, pattern: pattern, actual: value)
    }
}

private func checkDateTime(_ value: String, path: String) throws {
    let strict = ISO8601DateFormatter()
    strict.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard strict.date(from: value) != nil || fractional.date(from: value) != nil else {
        throw ValidationFailure.formatMismatch(path: path, format: "date-time", actual: value)
    }
}

private func checkBounds(
    _ value: Double,
    minimum: Double?,
    maximum: Double?,
    path: String
) throws {
    if let minimum, value < minimum {
        throw ValidationFailure.belowMinimum(path: path, minimum: minimum, actual: value)
    }
    if let maximum, value > maximum {
        throw ValidationFailure.aboveMaximum(path: path, maximum: maximum, actual: value)
    }
}

/// Checks a decoded array against `minItems`/`uniqueItems`, given a key that
/// identifies each element for duplicate detection (the elements in both
/// schemas needing `uniqueItems` are always strings or integers, so the
/// caller supplies their own `String` form).
func checkArrayConstraints<Element>(
    _ items: [Element],
    path: String,
    minItems: Int = 0,
    uniqueBy: ((Element) -> String)? = nil
) throws {
    guard items.count >= minItems else {
        throw ValidationFailure.tooFewItems(path: path, minimum: minItems, actual: items.count)
    }
    if let uniqueBy {
        var seen = Set<String>()
        for item in items {
            let key = uniqueBy(item)
            guard seen.insert(key).inserted else {
                throw ValidationFailure.duplicateItems(path: path)
            }
        }
    }
}

/// A minimal recursive JSON value, used only for `registryMutation.value`,
/// whose schema is the empty object `{}` — valid JSON of any shape.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unrecognized JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
