// Author: Timur Isaev

import AlloyTrust
import Foundation
import Testing
@testable import AlloyProfileCompiler

@Suite struct TrustIntegrationTests {
    @Test(arguments: [TrustScope.development, .lab])
    func byteIdenticalLaunchAndIndependentProvenance(scope: TrustScope) throws {
        let fixture = IntegrationTrust(scope: scope)
        defer { fixture.cleanup() }
        let testInput = try labLaunchFixture(scope: scope)
        let baseline = try LaunchCompiler.compile(testInput)
        let store = try fixture.bootstrap(now: testInput.selection.now)
        let trustedInput = try fixture.convert(testInput, store: store)
        try store.refresh(fixture.bundle(trustedInput), now: testInput.selection.now)
        let actual = try LaunchCompiler.compile(trustedInput)
        #expect(actual.canonicalJSON == baseline.canonicalJSON)
        #expect(actual.snapshot.bytes == baseline.snapshot.bytes)
        #expect(actual.verificationProvenance == "trust-chain-" + scope.rawValue)
        #expect(baseline.verificationProvenance == "test-only")
        #expect(actual.specification.verification == "verified-local")
        #expect(!actual.specification.productionEligible)
        #expect(try LaunchCompiler.verifyExport(baseline.canonicalJSON, input: trustedInput) == actual.specification)
    }

    @Test func staleExpiredRevokedAndCachedCandidates() throws {
        let fixture = IntegrationTrust()
        defer { fixture.cleanup() }
        let testInput = try labLaunchFixture()
        let store = try fixture.bootstrap(now: testInput.selection.now)
        let input = try fixture.convert(testInput, store: store)
        try store.refresh(fixture.bundle(input), now: input.selection.now)
        let baseline = try LaunchCompiler.compile(input)
        let cached = try ProfileCandidate(profile: input.candidates[0].profile, manifest: input.candidates[0].manifest,
                                          metadata: input.candidates[0].metadata, mode: input.verificationMode,
                                          now: input.selection.now)
        var stale = input
        stale.selection.previouslyMatchedDigests.insert(cached.profilePayload.digest)
        stale.selection.gameBuild.version = "different"
        #expect(throws: CompilerFailure.rejected("profile-stale")) { try LaunchCompiler.compile(stale) }
        let revision = ProfileRevision(profileId: cached.profile.profileId, revision: cached.profile.revision)
        try store.refresh(fixture.bundle(input, version: 2) {
            if $0.role == .revocation { $0.revokedProfiles = [revision] }
        }, now: input.selection.now)
        #expect(throws: TrustError.revokedTarget) { try LaunchCompiler.compile(input) }
        #expect(throws: TrustError.revokedTarget) {
            try LaunchCompiler.verifyExport(baseline.canonicalJSON, input: input)
        }
        #expect(throws: TrustError.revokedTarget) { try ProfileResolver.resolve([cached], input: input.selection) }
        #expect(throws: TrustError.rollback("timestamp")) {
            try store.refresh(fixture.bundle(input), now: input.selection.now)
        }
        #expect(throws: TrustError.expired("timestamp")) {
            try store.refresh(fixture.bundle(input, version: 3) {
                if $0.role == .timestamp { $0.expiresAt = "2020-01-01T00:00:00Z" }
            }, now: input.selection.now)
        }
    }

    @Test func cachedCandidateUsesRenewedMetadataExpiry() throws {
        let fixture = IntegrationTrust()
        defer { fixture.cleanup() }
        let testInput = try labLaunchFixture()
        let now = testInput.selection.now
        let store = try fixture.bootstrap(now: now)
        let input = try fixture.convert(testInput, store: store)
        try store.refresh(fixture.bundle(input) {
            if $0.role == .timestamp {
                $0.expiresAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(1))
            }
        }, now: now)
        let candidate = try ProfileCandidate(profile: input.candidates[0].profile,
                                             manifest: input.candidates[0].manifest,
                                             metadata: input.candidates[0].metadata,
                                             mode: input.verificationMode, now: now)
        var selection = input.selection
        selection.now = now.addingTimeInterval(2)
        #expect(throws: TrustError.expired("timestamp")) {
            try ProfileResolver.resolve([candidate], input: selection)
        }
        try store.refresh(fixture.bundle(input, version: 2), now: selection.now)
        #expect(try ProfileResolver.resolve([candidate], input: selection).outcome == .exact)
    }

    @Test func tamperEachEnvelopeAndRejectStableClaims() throws {
        let fixture = IntegrationTrust()
        defer { fixture.cleanup() }
        let testInput = try labLaunchFixture()
        let store = try fixture.bootstrap(now: testInput.selection.now)
        let input = try fixture.convert(testInput, store: store)
        try store.refresh(fixture.bundle(input), now: input.selection.now)
        let mutations: [(inout LaunchCompilationInput) -> Void] = [
            { $0.candidates[0].profile.append(32) }, { $0.candidates[0].manifest.append(32) },
            { $0.candidates[0].metadata.append(32) }, { $0.evidenceEnvelope.append(32) }
        ]
        for mutate in mutations {
            _ = try LaunchCompiler.compile(input)
            var altered = input
            mutate(&altered)
            #expect(throws: TrustError.mixAndMatch) { try LaunchCompiler.compile(altered) }
        }
        let stable = try fixture.convert(launchFixture(), store: store)
        try store.refresh(fixture.bundle(stable, version: 2), now: input.selection.now)
        #expect(throws: CompilerFailure.rejected("development/lab root cannot authorize this release ring")) {
            try LaunchCompiler.compile(stable)
        }
    }
}
