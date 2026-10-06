// Author: Timur Isaev

import CryptoKit
import Foundation
import Testing
@testable import AlloyTrust

@Suite struct RotationTests {
    @Test func compromisedRootAndArtifactKeyDrill() throws {
        var fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        let oldBundle = try fixture.bundle()
        try store.refresh(oldBundle, now: fixture.now)
        let oldRootSigners = fixture.keys[.root]!
        let oldArtifact = try fixture.profile()
        fixture.keys[.root] = [.init(), .init()]
        fixture.keys[.profiles] = [.init(), .init()]
        let next = try fixture.root(version: 2)
        let nextPayload = try TrustCanonicalJSON.encode(next)
        let oldOnly = try TrustCanonicalJSON.encode(SignedEnvelope.sign(
            nextPayload, type: TrustRole.root.payloadType, keys: oldRootSigners
        ))
        let newOnly = try fixture.signed(next)
        #expect(throws: TrustError.belowThreshold) { try store.rotate([oldOnly], now: fixture.now) }
        #expect(throws: TrustError.belowThreshold) { try store.rotate([newOnly], now: fixture.now) }
        let crossSigned = try TrustCanonicalJSON.encode(SignedEnvelope.sign(
            nextPayload, type: TrustRole.root.payloadType, keys: oldRootSigners + fixture.keys[.root]!
        ))
        try store.rotate([crossSigned], now: fixture.now)
        #expect(throws: TrustError.rollback("root")) { try store.rotate([crossSigned], now: fixture.now) }
        #expect(throws: TrustError.state("metadata not initialized")) {
            try store.verify(oldArtifact, type: fixture.type, now: fixture.now)
        }
        // The compromised old artifact signatures remain listed but cannot pass
        // the new root's artifact threshold.
        try store.refresh(fixture.bundle(version: 2, artifact: oldArtifact), now: fixture.now)
        #expect(throws: TrustError.belowThreshold) {
            try store.verify(oldArtifact, type: fixture.type, now: fixture.now)
        }
        let replacement = try fixture.profile(revision: 2)
        try store.refresh(fixture.bundle(version: 3, artifact: replacement), now: fixture.now)
        let reopened = TrustStore(directory: fixture.directory, pinnedRootDigest: store.pinnedRootDigest)
        #expect(try reopened.verify(replacement, type: fixture.type, now: fixture.now).scope == .development)
        #expect(throws: TrustError.rollback("timestamp")) { try reopened.refresh(oldBundle, now: fixture.now) }
    }

    @Test func profileAndKeyRevocationBeatCachedSelection() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        let original = try fixture.profile()
        try store.refresh(fixture.bundle(artifact: original), now: fixture.now)
        let cachedBytes = try store.verify(original, type: fixture.type, now: fixture.now).bytes
        #expect(!cachedBytes.isEmpty)
        let revokeProfile = try fixture.bundle(version: 2, artifact: original) {
            if $0.role == .revocation { $0.revokedProfiles = [.init(profileId: "gp_test", revision: 1)] }
        }
        try store.refresh(revokeProfile, now: fixture.now)
        #expect(throws: TrustError.revokedTarget) { try store.verify(original, type: fixture.type, now: fixture.now) }
        // Omitting a previous withdrawal cannot undo persisted revocation.
        try store.refresh(fixture.bundle(version: 3, artifact: original), now: fixture.now)
        #expect(throws: TrustError.revokedTarget) { try store.verify(original, type: fixture.type, now: fixture.now) }
        let next = try fixture.profile(revision: 2)
        try store.refresh(fixture.bundle(version: 4, artifact: next), now: fixture.now)
        _ = try store.verify(next, type: fixture.type, now: fixture.now)
        let key = SignedEnvelope.keyID(fixture.keys[.profiles]![0].publicKey.rawRepresentation)
        let revokeKey = try fixture.bundle(version: 5, artifact: next) {
            if $0.role == .revocation { $0.revokedKeys = [key] }
        }
        try store.refresh(revokeKey, now: fixture.now)
        let reopened = TrustStore(directory: fixture.directory, pinnedRootDigest: store.pinnedRootDigest)
        #expect(throws: TrustError.revokedKey) { try reopened.verify(next, type: fixture.type, now: fixture.now) }
        let attemptRootRevocation = try fixture.bundle(version: 6, artifact: next) {
            if $0.role == .revocation {
                $0.revokedKeys = [SignedEnvelope.keyID(fixture.keys[.root]![0].publicKey.rawRepresentation)]
            }
        }
        #expect(throws: TrustError.wrongRole) { try store.refresh(attemptRootRevocation, now: fixture.now) }
    }

    @Test func skippedRootAndScopeChangeRejected() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        #expect(throws: TrustError.rollback("root")) {
            try store.rotate([fixture.signed(fixture.root(version: 3))], now: fixture.now)
        }
        var next = try fixture.root(version: 2)
        next.scope = .lab
        #expect(throws: TrustError.wrongRole) { try store.rotate([fixture.signed(next)], now: fixture.now) }
        next.scope = .development
        try store.rotate([fixture.signed(next)], now: fixture.now)
        try store.refresh(fixture.bundle(), now: fixture.now)
        _ = try store.verify(fixture.profile(), type: fixture.type, now: fixture.now)
    }
}
