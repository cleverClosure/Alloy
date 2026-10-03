// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyProfileCompiler

@Suite("Profile selection and precedence")
struct ProfileResolverTests {
    @Test func pairedPrecedenceGoldens() throws {
        let rows = try #require(JSONSerialization.jsonObject(
            with: extraFixture("Resolver/profile-precedence.json")
        ) as? [[String: Any]])
        #expect(rows.count == 5)
        for row in rows {
            let name = try #require(row["name"] as? String)
            for variant in ["clean", "counterfactual"] {
                let scenario = try #require(row[variant] as? [String: Any])
                let definitions = try #require(scenario["candidates"] as? [[String: Any]])
                let candidates = try definitions.map { definition in
                    let ringName = try #require(definition["ring"] as? String)
                    return try candidate(
                        profile: compilerProfile(try #require(definition["patch"] as? [String: Any])),
                        ring: try #require(ReleaseRing(rawValue: ringName))
                    )
                }
                let expected = try #require(scenario["winner"] as? Int)
                for iteration in 0..<10 {
                    let ordered = iteration.isMultiple(of: 2) ? candidates : candidates.reversed()
                    let result = try ProfileResolver.resolve(ordered, input: selectionInput())
                    if expected < 0 {
                        #expect(result.outcome == .conflict, "\(name) \(variant)")
                        #expect(throws: CompilerFailure.rejected("profile-conflict")) { try result.requireSelected() }
                    } else {
                        #expect(result.selected?.profilePayload.digest == candidates[expected].profilePayload.digest,
                                "\(name) \(variant)")
                        #expect(result.selected?.metadata.releaseRing == candidates[expected].metadata.releaseRing)
                        #expect(result.outcome == .exact)
                    }
                }
            }
        }
    }

    @Test func revisionsDoNotCrossFamiliesAndLowerTrustCannotSupersede() throws {
        let first = try candidate(profile: compilerProfile(["profileId": "first.game", "revision": 999]))
        let second = try candidate(profile: compilerProfile(["profileId": "second.game", "revision": 1]))
        #expect(try ProfileResolver.resolve([first, second], input: selectionInput()).outcome == .conflict)
        let lowerTrust = try candidate(
            profile: compilerProfile(["profileId": "canary.game", "supersedes": ["first.game"]]), ring: .canary
        )
        #expect(try ProfileResolver.resolve([first, lowerTrust], input: selectionInput())
            .selected?.profile.profileId == "first.game")
        var canaryInput = selectionInput()
        canaryInput.client.canaryClient = true
        #expect(try ProfileResolver.resolve([first, lowerTrust], input: canaryInput).outcome == .conflict)
        let cycleA = try candidate(profile: compilerProfile(["profileId": "aaa.game", "supersedes": ["bbb.game"]]))
        let cycleB = try candidate(profile: compilerProfile(["profileId": "bbb.game", "supersedes": ["aaa.game"]]))
        #expect(try ProfileResolver.resolve([cycleA, cycleB], input: selectionInput()).outcome == .conflict)
    }

    @Test func exactAliasStaleUnknownAndLauncher() throws {
        let profile = try compilerProfile()
        let clean = try candidate(profile: profile)
        var input = selectionInput()
        #expect(try ProfileResolver.resolve([clean], input: input).outcome == .exact)
        input.gameBuild.version = "2.0.0"
        #expect(try ProfileResolver.resolve([clean], input: input).outcome == .unknown)
        input.previouslyMatchedDigests = [clean.profilePayload.digest]
        #expect(try ProfileResolver.resolve([clean], input: input).outcome == .stale)
        let alias = try candidate(profile: profile) { $0.gameAliases = [try input.gameBuild.digest()] }
        #expect(try ProfileResolver.resolve([alias], input: input).outcome == .compatibleAlias)
        input.gameBuild.manifestId = "not-authorized"
        #expect(try ProfileResolver.resolve([alias], input: input).selected == nil)
        input = selectionInput()
        let withLauncher = try compilerProfile(["selectors.launcherBuild": ["version": "3.0"]])
        let requiredLauncher = try candidate(profile: withLauncher)
        #expect(try ProfileResolver.resolve([requiredLauncher], input: input).outcome == .unknown)
        input.launcherBuild = BuildIdentity(id: "lb_fixture", version: "3.0")
        #expect(try ProfileResolver.resolve([requiredLauncher], input: input).outcome == .exact)
        input.launcherBuild?.version = "3.1"
        let launcherAlias = try candidate(profile: withLauncher) {
            $0.launcherAliases = [try #require(input.launcherBuild).digest()]
        }
        #expect(try ProfileResolver.resolve([launcherAlias], input: input).outcome == .compatibleAlias)
    }

    @Test func everyEligibilityGateHasPairedCleanInput() throws {
        let profile = try compilerProfile([
            "selectors.host.macos": ["min": "15.0", "maxExclusive": "16.0", "allowedBuilds": ["24B1"]],
            "selectors.host.gpuFamilies": ["apple8"], "selectors.host.memoryClassesGiB": [16]
        ])
        let clean = try candidate(profile: profile)
        let changes: [(inout SelectionInput) -> Void] = [
            { $0.gameId = "other" }, { $0.appId = "other" }, { $0.storefront = .steam },
            { $0.host.architecture = "x64" }, { $0.host.macOS = "14.9" }, { $0.host.macOS = "16.0" },
            { $0.host.macOSBuild = "different" }, { $0.host.gpuFamilies = ["apple7"] },
            { $0.host.memoryGiB = 32 }, { $0.client.allowedRings = [.development] }
        ]
        for change in changes {
            var input = selectionInput()
            #expect(try ProfileResolver.resolve([clean], input: input).outcome == .exact)
            change(&input)
            #expect(try ProfileResolver.resolve([clean], input: input).outcome == .unknown)
        }
        let metadataChanges: [(inout CandidateMetadata) -> Void] = [
            { $0.deniedMacOSBuilds = ["24B1"] }, { $0.requiredFeatures = ["missing-service"] },
            { $0.eligibleClientIds = ["different"] }, { $0.minimumClientVersion = "2.0" },
            { $0.releaseRing = .quarantined }
        ]
        for change in metadataChanges {
            let denied = try candidate(profile: profile, metadataEdit: change)
            #expect(try ProfileResolver.resolve([clean], input: selectionInput()).outcome == .exact)
            #expect(try ProfileResolver.resolve([denied], input: selectionInput()).outcome == .unknown)
        }
        var later = selectionInput()
        later.now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(throws: CompilerFailure.rejected("expired candidate")) {
            try ProfileResolver.resolve([clean], input: later)
        }
    }

    @Test func metadataBindingAndExactFileIdentity() throws {
        #expect(throws: (any Error).self) {
            try candidate(profile: compilerProfile()) { $0.profileDigest = "sha256:wrong" }
        }
        let digest = String(repeating: "a", count: 64)
        let profile = try compilerProfile(["selectors.gameBuild": ["requiredFiles": [
            ["path": "Bin/Game.exe", "sha256": digest, "size": 123, "peTimestamp": 42]
        ]]])
        let clean = try candidate(profile: profile)
        var input = selectionInput()
        input.gameBuild.files = [ObservedFile(path: "BIN\\GAME.EXE", sha256: digest, size: 123, peTimestamp: 42)]
        #expect(try ProfileResolver.resolve([clean], input: input).outcome == .exact)
        input.gameBuild.files[0].size = 124
        #expect(try ProfileResolver.resolve([clean], input: input).outcome == .unknown)
        input.gameBuild.files[0].path = "Bin/../Game.exe"
        #expect(throws: (any Error).self) { try ProfileResolver.resolve([clean], input: input) }
    }
}
