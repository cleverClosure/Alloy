// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyTrust

@Suite struct RoleTests {
    @Test func validOfflineAndPersistentRollbackControl() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        try store.refresh(fixture.bundle(), now: fixture.now)
        let profile = try fixture.profile()
        #expect(try store.verify(profile, type: fixture.type, now: fixture.now).bytes
            == SignedEnvelope.decode(profile).decodedPayload())
        try store.refresh(fixture.bundle(version: 2), now: fixture.now)
        let reopened = TrustStore(directory: fixture.directory, pinnedRootDigest: store.pinnedRootDigest)
        #expect(throws: TrustError.rollback("timestamp")) {
            try reopened.refresh(fixture.bundle(), now: fixture.now)
        }
        #expect(try reopened.verify(profile, type: fixture.type, now: fixture.now).scope == .development)
        #expect(throws: (any Error).self) { try fixture.bootstrap() }
    }

    @Test(arguments: [TrustRole.timestamp, .snapshot, .targets, .revocation])
    func roleAttacks(role: TrustRole) throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        let valid = try fixture.bundle()
        try store.refresh(valid, now: fixture.now)
        let expired = try fixture.bundle(version: 2) {
            if $0.role == role { $0.expiresAt = "2020-01-01T00:00:00Z" }
        }
        #expect(throws: TrustError.expired(role.rawValue)) { try store.refresh(expired, now: fixture.now) }
        let wrong = try fixture.bundle(version: 2) { if $0.role == role { $0.scope = .lab } }
        #expect(throws: TrustError.wrongRole) { try store.refresh(wrong, now: fixture.now) }
        try store.refresh(valid, now: fixture.now)
    }

    @Test func wrongSignerThresholdAndMixMatch() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        let valid = try fixture.bundle()
        try store.refresh(valid, now: fixture.now)
        var attack = valid
        let stamp = try TrustMetadata.decode(SignedEnvelope.decode(valid.timestamp).decodedPayload())
        attack.timestamp = try fixture.signed(stamp, by: .targets)
        #expect(throws: TrustError.belowThreshold) { try store.refresh(attack, now: fixture.now) }
        attack.timestamp = try fixture.signed(stamp, count: 1)
        #expect(throws: TrustError.belowThreshold) { try store.refresh(attack, now: fixture.now) }
        attack = try fixture.bundle(version: 2)
        attack.snapshot = valid.snapshot
        #expect(throws: TrustError.mixAndMatch) { try store.refresh(attack, now: fixture.now) }
        // Same version with altered content is also an attack, not an update.
        attack = try fixture.bundle { if $0.role == .timestamp { $0.expiresAt = "2031-01-01T00:00:00Z" } }
        #expect(throws: TrustError.mixAndMatch) { try store.refresh(attack, now: fixture.now) }
        try store.refresh(valid, now: fixture.now)
    }

    @Test func freezeAndClockRollback() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        let expiry = fixture.now.addingTimeInterval(30)
        let valid = try fixture.bundle {
            if $0.role == .timestamp { $0.expiresAt = ISO8601DateFormatter().string(from: expiry) }
        }
        try store.refresh(valid, now: fixture.now)
        _ = try store.verify(fixture.profile(), type: fixture.type, now: expiry.addingTimeInterval(-1))
        #expect(throws: TrustError.expired("timestamp")) {
            try store.verify(fixture.profile(), type: fixture.type, now: expiry)
        }
        #expect(throws: TrustError.freeze) {
            try store.verify(fixture.profile(), type: fixture.type, now: fixture.now)
        }
        try store.refresh(fixture.bundle(version: 2), now: expiry)
        _ = try store.verify(fixture.profile(), type: fixture.type, now: expiry)
    }

    @Test func corruptMissingStateAndWrongPin() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        let valid = try fixture.bundle()
        try store.refresh(valid, now: fixture.now)
        let wrong = TrustStore(directory: fixture.directory, pinnedRootDigest: "sha256:wrong")
        #expect(throws: TrustError.invalidRoot) { try wrong.refresh(fixture.bundle(), now: fixture.now) }
        let state = fixture.directory.appendingPathComponent("state.json")
        let saved = try Data(contentsOf: state)
        try Data("corrupt".utf8).write(to: state)
        #expect(throws: (any Error).self) { try store.refresh(valid, now: fixture.now) }
        try saved.write(to: state)
        try store.refresh(valid, now: fixture.now)
        try FileManager.default.removeItem(at: state)
        #expect(throws: TrustError.state("missing state")) { try store.refresh(valid, now: fixture.now) }
    }

    @Test(arguments: [TrustRole.timestamp, .snapshot, .targets, .revocation])
    func eachRoleRejectsRollback(role: TrustRole) throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        try store.refresh(fixture.bundle(version: 2), now: fixture.now)
        let replay = try fixture.bundle(version: 3) { if $0.role == role { $0.version = 1 } }
        #expect(throws: TrustError.rollback(role.rawValue)) { try store.refresh(replay, now: fixture.now) }
        try store.refresh(fixture.bundle(version: 3), now: fixture.now)
    }

    @Test func verifierCannotOutliveTransaction() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        try store.refresh(fixture.bundle(), now: fixture.now)
        let escaped = try store.withVerifier(now: fixture.now) { verifier in
            _ = try verifier.verify(fixture.profile(), type: fixture.type)
            return verifier
        }
        #expect(throws: TrustError.state("verification transaction ended")) {
            try escaped.verify(fixture.profile(), type: fixture.type)
        }
    }

    @Test func rootAndTargetFailures() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        var root = try fixture.root()
        let rootRule = root.roles?["root"]
        root.roles?["targets"] = rootRule
        let bytes = try fixture.signed(root)
        #expect(throws: TrustError.invalidRoot) {
            try TrustStore.bootstrap(directory: fixture.directory, root: bytes,
                                     pinnedRootDigest: TrustCanonicalJSON.digest(bytes), now: fixture.now)
        }
        let store = try fixture.bootstrap()
        let weak = try fixture.profile(count: 1)
        try store.refresh(fixture.bundle(artifact: weak), now: fixture.now)
        #expect(throws: TrustError.belowThreshold) { try store.verify(weak, type: fixture.type, now: fixture.now) }
        let strong = try fixture.profile()
        #expect(throws: TrustError.mixAndMatch) { try store.verify(strong, type: fixture.type, now: fixture.now) }
        try store.refresh(fixture.bundle(version: 2), now: fixture.now)
        _ = try store.verify(strong, type: fixture.type, now: fixture.now)
        #expect(throws: TrustError.unauthorizedTarget) {
            try store.verify(fixture.profile(revision: 2), type: fixture.type, now: fixture.now)
        }
    }
}
