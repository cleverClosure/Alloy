// Author: Timur Isaev

import Foundation
@testable import AlloyProfileCompiler

/// One step into a parsed JSON tree (`[String: Any]` / `[Any]`, straight
/// from `JSONSerialization`).
enum PathStep {
    case key(String)
    case index(Int)
}

/// Rebuilds `node` with `mutate` applied to the `[String: Any]` container
/// found by walking `path`. Swift's `Dictionary`/`Array` are value types, so
/// this is a plain bottom-up recursive rebuild: no node outside the target
/// container's ancestry is ever touched.
func withContainer(_ node: Any, at path: [PathStep], mutate: ([String: Any]) -> [String: Any]) -> Any {
    guard let step = path.first else {
        guard let dict = node as? [String: Any] else { return node }
        return mutate(dict)
    }
    let rest = Array(path.dropFirst())
    switch step {
    case let .key(key):
        guard var dict = node as? [String: Any] else { return node }
        dict[key] = withContainer(dict[key] as Any, at: rest, mutate: mutate)
        return dict
    case let .index(index):
        guard var array = node as? [Any], array.indices.contains(index) else { return node }
        array[index] = withContainer(array[index], at: rest, mutate: mutate)
        return array
    }
}

/// One candidate structural mutation, already paired with the exact
/// `ValidationFailure` dropping/adding/changing that one field must produce.
/// "Known by construction": the expectation is computed from the schema and
/// the mutation applied, never from running the validator and recording
/// whatever it happened to say.
struct Mutation: CustomStringConvertible {
    let label: String
    let apply: (Any) -> Any
    let expected: ValidationFailure
    var description: String { label }
}

/// Walks `fixture` in lockstep with `schema` (resolving `$ref` the same way
/// SchemaDriftTests does) and collects every mutation the schema admits at
/// that exact fixture: a required key present and droppable, an object node
/// an unknown key can be slipped into, a scalar property whose declared type
/// can be swapped for an incompatible one, and an `enum` property whose
/// value can be replaced by one outside the list.
func collectMutations(
    fixture: Any, schema: SchemaNode, path: [PathStep] = [], renderedPath: String = "$"
) -> [Mutation] {
    guard let object = fixture as? [String: Any] else {
        return collectArrayMutations(fixture: fixture, schema: schema, path: path, renderedPath: renderedPath)
    }

    var mutations = requiredKeyDropMutations(object: object, schema: schema, path: path, renderedPath: renderedPath)
    mutations.append(unknownKeyMutation(path: path, renderedPath: renderedPath))

    for key in object.keys.sorted() {
        guard let propertySchema = schema.property(key) else { continue }
        let fieldPath = "\(renderedPath).\(key)"
        mutations.append(contentsOf: leafMutations(key: key, schema: propertySchema, path: path, fieldPath: fieldPath))
        mutations.append(contentsOf: collectMutations(
            fixture: object[key] as Any, schema: propertySchema, path: path + [.key(key)], renderedPath: fieldPath
        ))
    }

    return mutations
}

private func collectArrayMutations(
    fixture: Any,
    schema: SchemaNode,
    path: [PathStep],
    renderedPath: String
) -> [Mutation] {
    guard let array = fixture as? [Any], let itemSchema = schema.items() else { return [] }
    return array.enumerated().flatMap { index, element in
        collectMutations(
            fixture: element,
            schema: itemSchema,
            path: path + [.index(index)],
            renderedPath: "\(renderedPath)[\(index)]"
        )
    }
}

/// `.sorted()`: `schema.required` is a `Set<String>`, and Swift randomizes a
/// process's `String` hash seed on every launch. Without sorting, the pool
/// would list "drop required key …" mutations in a different order each
/// run, and `.shuffled(using:)` a differently-ordered input with the same
/// seed produces a different sample — the fixed seed would stop actually
/// fixing anything. `samplingIsDeterministic()` in MutationTests.swift
/// exists to catch exactly this.
private func requiredKeyDropMutations(
    object: [String: Any],
    schema: SchemaNode,
    path: [PathStep],
    renderedPath: String
) -> [Mutation] {
    schema.required.sorted().filter { object[$0] != nil }.map { key in
        Mutation(
            label: "drop required key \(renderedPath).\(key)",
            apply: { root in withContainer(root, at: path) { object in object.removingValue(forKey: key) } },
            expected: .missingRequiredKey(path: renderedPath, key: key)
        )
    }
}

private func unknownKeyMutation(path: [PathStep], renderedPath: String) -> Mutation {
    Mutation(
        label: "add unknown key to \(renderedPath)",
        apply: { root in
            withContainer(root, at: path) { object in object.settingValue(true, forKey: "__mutation_unknown_key__") }
        },
        expected: .unknownKey(path: renderedPath, key: "__mutation_unknown_key__")
    )
}

/// The two single-field mutations admissible at a scalar leaf: a declared
/// `type` can be swapped for an incompatible JSON type, and a declared
/// `enum` can be given a value outside its list.
private func leafMutations(key: String, schema: SchemaNode, path: [PathStep], fieldPath: String) -> [Mutation] {
    var mutations: [Mutation] = []

    if let declaredType = schema.raw["type"] as? String, let replacement = incompatibleValue(for: declaredType) {
        mutations.append(Mutation(
            label: "change type of \(fieldPath) away from \(declaredType)",
            apply: { root in
                withContainer(root, at: path) { object in object.settingValue(replacement, forKey: key) }
            },
            expected: .wrongType(path: fieldPath, expected: declaredType)
        ))
    }

    if let enumValues = schema.raw["enum"] as? [String] {
        let bogusValue = "__not_a_real_enum_value__"
        mutations.append(Mutation(
            label: "put an out-of-enum value at \(fieldPath)",
            apply: { root in withContainer(root, at: path) { object in object.settingValue(bogusValue, forKey: key) } },
            expected: .enumMismatch(path: fieldPath, allowed: enumValues.sorted(), actual: bogusValue)
        ))
    }

    return mutations
}

/// A JSON value of a type incompatible with `declaredType`, guaranteeing a
/// cross-category swap (string<->bool, integer/number<->string) that always
/// fails to decode as the original type.
private func incompatibleValue(for declaredType: String) -> Any? {
    switch declaredType {
    case "string": true
    case "integer", "number": "mutated"
    case "boolean": 12345
    default: nil
    }
}

private extension Dictionary where Key == String, Value == Any {
    func removingValue(forKey key: String) -> [String: Any] {
        var copy = self
        copy.removeValue(forKey: key)
        return copy
    }

    func settingValue(_ value: Any, forKey key: String) -> [String: Any] {
        var copy = self
        copy[key] = value
        return copy
    }
}

/// splitmix64 — a small, dependency-free, fully reproducible PRNG. Conforming
/// to `RandomNumberGenerator` lets the mutation tests deterministically
/// `.shuffled(using:)` a candidate list with the standard library's own
/// algorithm instead of a hand-rolled one.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// The fixed seed every mutation test run uses. Changing it is fine (it only
/// changes which admissible mutations get sampled out of a larger pool) but
/// it must stay a literal constant, not derived from the clock or the
/// environment, or "deterministic" stops being true.
let mutationSeed: UInt64 = 0x5EED_C0FF_EE42

/// Deterministically samples up to `perFixtureBudget` mutations from the
/// full admissible set and applies each to a decoded copy of `data`. One
/// result per sampled mutation, checking both halves of the
/// mutation-testing contract at once: the mutant must be rejected (never
/// silently accepted) and rejected for exactly the reason the mutation
/// implies (never some other, unrelated failure masking a gap in the
/// validator) — with no case ever reaching an uncaught trap, since every
/// path here is a plain `throws`/`catch`, never a force-unwrap.
func runMutationSuite(
    schema: SchemaNode,
    data: Data,
    perFixtureBudget: Int = 40,
    validate: (Data) throws -> Void
) throws -> [(mutation: Mutation, result: Result<Void, MutationTestingError>)] {
    let root = try JSONSerialization.jsonObject(with: data)
    var generator = SeededGenerator(seed: mutationSeed)
    let sampled = Array(
        collectMutations(fixture: root, schema: schema)
            .shuffled(using: &generator)
            .prefix(perFixtureBudget)
    )

    return try sampled.map { mutation in
        let mutated = mutation.apply(root)
        let mutatedData = try JSONSerialization.data(withJSONObject: mutated)
        do {
            try validate(mutatedData)
            return (mutation, .failure(.wasAccepted))
        } catch let failure as ValidationFailure {
            guard failure == mutation.expected else {
                return (mutation, .failure(.wrongReason(got: failure, wanted: mutation.expected)))
            }
            return (mutation, .success(()))
        } catch {
            return (mutation, .failure(.nonValidationError(error)))
        }
    }
}

enum MutationTestingError: Error, CustomStringConvertible {
    case wasAccepted
    case wrongReason(got: ValidationFailure, wanted: ValidationFailure)
    case nonValidationError(Error)

    var description: String {
        switch self {
        case .wasAccepted:
            "mutant was accepted instead of rejected"
        case let .wrongReason(got, wanted):
            "rejected for the wrong reason: got \(got), wanted \(wanted)"
        case let .nonValidationError(error):
            "threw a non-ValidationFailure error: \(error)"
        }
    }
}
