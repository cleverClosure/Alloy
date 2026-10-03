// Author: Tim Isaev

import Foundation

/// Validates a game-profile document against
/// `docs/schemas/game-profile.schema.json`. The strictness lives in
/// `GameProfileModels.swift`; this entry point exists only because a payload
/// that is not syntactically JSON at all never reaches
/// `GameProfileDocument.init(from:)` — `strictContainer` already turns a
/// syntactically-valid-but-wrong-shaped root (an array, a string, …) into
/// `ValidationFailure.notAnObject` itself.
public enum GameProfileValidator {
    public static func validate(_ data: Data) throws -> GameProfileDocument {
        do {
            return try JSONDecoder().decode(GameProfileDocument.self, from: data)
        } catch let failure as ValidationFailure {
            throw failure
        } catch {
            throw ValidationFailure.malformed(path: "$", reason: "not valid JSON: \(error)")
        }
    }
}
