// Author: Tim Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

/// Takes every valid fixture, deterministically samples single structural
/// mutations the live schema admits at that exact document (drop a required
/// key, add an unknown key, change a leaf's JSON type, swap an enum value
/// for a bogus one), and checks each mutant is rejected for the specific
/// reason that mutation implies. The seed is fixed (`mutationSeed` in
/// MutationSupport.swift), so which mutations get sampled out of the full
/// admissible set never changes between runs.
@Suite("Seeded structural mutation")
struct MutationTests {
    @Test(
        "game profile fixtures reject every sampled mutation for its exact reason",
        arguments: validGameProfileFixtureNames
    )
    func gameProfileMutations(name: String) throws {
        let data = try fixtureData(.gameProfile, "valid/\(name)")
        let results = try runMutationSuite(schema: gameProfileSchema, data: data) { data in
            _ = try GameProfileValidator.validate(data)
        }
        // A fixture with no admissible mutation would make the rest of this
        // test vacuously true; every valid fixture here has required keys,
        // nested objects, and enum fields, so this must never be empty.
        #expect(!results.isEmpty)
        for (mutation, result) in results {
            if case let .failure(reason) = result {
                Issue.record("\(name): \(mutation) — \(reason)")
            }
        }
    }

    @Test(
        "runtime manifest fixtures reject every sampled mutation for its exact reason",
        arguments: validRuntimeManifestFixtureNames
    )
    func runtimeManifestMutations(name: String) throws {
        let data = try fixtureData(.runtimeManifest, "valid/\(name)")
        let results = try runMutationSuite(schema: runtimeManifestSchema, data: data) { data in
            _ = try RuntimeManifestValidator.validate(data)
        }
        #expect(!results.isEmpty)
        for (mutation, result) in results {
            if case let .failure(reason) = result {
                Issue.record("\(name): \(mutation) — \(reason)")
            }
        }
    }

    @Test("the sampled mutation set is a fixed point of the seed: resampling twice gives the same labels")
    func samplingIsDeterministic() throws {
        let data = try fixtureData(.gameProfile, "valid/maximal.json")
        let first = try runMutationSuite(schema: gameProfileSchema, data: data) { _ in }.map(\.mutation.label)
        let second = try runMutationSuite(schema: gameProfileSchema, data: data) { _ in }.map(\.mutation.label)
        #expect(first == second)
    }
}
