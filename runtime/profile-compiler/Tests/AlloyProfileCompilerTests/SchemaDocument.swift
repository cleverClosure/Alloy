// Author: Timur Isaev

import Foundation

/// A read-only view over one node of a parsed JSON Schema document, used
/// only to walk `docs/schemas/*.json` for SchemaDriftTests. It understands
/// exactly the subset of JSON Schema the two Alloy schemas use: `$ref` into
/// `$defs`, `properties`/`required`, `items`, `enum`/`const`, and an
/// `additionalProperties` sub-schema. It is not a general JSON Schema engine
/// and never validates a document — `GameProfileModels.swift` and
/// `RuntimeManifestModels.swift` do that, by hand, which is exactly the
/// thing this type lets the drift tests check has not fallen behind.
/// `@unchecked`: holds `[String: Any]` straight from `JSONSerialization`,
/// which cannot itself be `Sendable`. Safe here because every `SchemaNode`
/// is built once, from a static `let`, and only ever read afterwards.
struct SchemaNode: @unchecked Sendable {
    let raw: [String: Any]
    let defs: [String: Any]

    var properties: Set<String> {
        guard let properties = raw["properties"] as? [String: Any] else { return [] }
        return Set(properties.keys)
    }

    var required: Set<String> {
        Set((raw["required"] as? [String]) ?? [])
    }

    func property(_ name: String) -> SchemaNode? {
        guard
            let properties = raw["properties"] as? [String: Any],
            let child = properties[name] as? [String: Any]
        else {
            return nil
        }
        return resolve(child)
    }

    /// The schema for one element of an array-typed node.
    func items() -> SchemaNode? {
        guard let child = raw["items"] as? [String: Any] else { return nil }
        return resolve(child)
    }

    /// `enum` as a string list, or a `const` string lifted into a
    /// single-element list — the two are interchangeable for drift-checking
    /// a fixed vocabulary.
    func enumValues() -> [String]? {
        if let values = raw["enum"] as? [String] {
            return values
        }
        if let constant = raw["const"] as? String {
            return [constant]
        }
        return nil
    }

    /// `additionalProperties: {"enum": [...]}` — an open string-keyed map
    /// whose values are constrained to an enum (only `execution.dllOverrides`
    /// uses this shape in either schema).
    func additionalPropertiesEnumValues() -> [String]? {
        guard let additional = raw["additionalProperties"] as? [String: Any] else { return nil }
        return additional["enum"] as? [String]
    }

    private func resolve(_ node: [String: Any]) -> SchemaNode {
        guard
            let ref = node["$ref"] as? String,
            ref.hasPrefix("#/$defs/"),
            let target = defs[String(ref.dropFirst("#/$defs/".count))] as? [String: Any]
        else {
            return SchemaNode(raw: node, defs: defs)
        }
        return SchemaNode(raw: target, defs: defs)
    }
}

enum SchemaDocument {
    static func load(_ url: URL) throws -> SchemaNode {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let defs = object["$defs"] as? [String: Any] ?? [:]
        return SchemaNode(raw: object, defs: defs)
    }
}

let repositoryRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let gameProfileSchemaURL = repositoryRoot.appendingPathComponent("docs/schemas/game-profile.schema.json")
let runtimeManifestSchemaURL = repositoryRoot.appendingPathComponent("docs/schemas/runtime-manifest.schema.json")

/// Loaded once and shared by SchemaDriftTests and MutationTests, which both
/// need the live schema's shape — the former to compare it against the
/// validator, the latter to compute which structural mutations a given
/// fixture even admits.
let gameProfileSchema = loadSchemaOrFail(gameProfileSchemaURL)
let runtimeManifestSchema = loadSchemaOrFail(runtimeManifestSchemaURL)

/// A committed schema file failing to load makes every test in this target
/// meaningless, so this fails immediately and loudly rather than limping
/// along with a stale or missing schema.
private func loadSchemaOrFail(_ url: URL) -> SchemaNode {
    guard let schema = try? SchemaDocument.load(url) else {
        fatalError("could not load schema at \(url.path)")
    }
    return schema
}
