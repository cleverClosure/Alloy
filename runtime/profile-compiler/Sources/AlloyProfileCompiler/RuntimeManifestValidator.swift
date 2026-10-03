// Author: Tim Isaev

import Foundation

/// Validates a runtime-manifest document against
/// `docs/schemas/runtime-manifest.schema.json`. See `GameProfileValidator`
/// for why this wrapper exists alongside `RuntimeManifestDocument.init(from:)`.
public enum RuntimeManifestValidator {
    public static func validate(_ data: Data) throws -> RuntimeManifestDocument {
        do {
            return try JSONDecoder().decode(RuntimeManifestDocument.self, from: data)
        } catch let failure as ValidationFailure {
            throw failure
        } catch {
            throw ValidationFailure.malformed(path: "$", reason: "not valid JSON: \(error)")
        }
    }
}
