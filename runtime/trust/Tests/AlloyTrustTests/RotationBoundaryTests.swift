// Author: Timur Isaev

import CryptoKit
import Foundation
import Testing
@testable import AlloyTrust

@Suite struct RotationBoundaryTests {
    @Test func disjointMaximumRootThresholdsFitOneEnvelope() throws {
        var fixture = try TrustFixture()
        defer { fixture.cleanup() }
        fixture.keys[.root] = (0..<32).map { _ in .init() }
        var first = try fixture.root()
        first.roles?["root"]?.threshold = 32
        let firstBytes = try fixture.signed(first, count: 32)
        let store = try TrustStore.bootstrap(directory: fixture.directory, root: firstBytes,
                                             pinnedRootDigest: TrustCanonicalJSON.digest(firstBytes), now: fixture.now)
        let previous = fixture.keys[.root]!
        fixture.keys[.root] = (0..<32).map { _ in .init() }
        var next = try fixture.root(version: 2)
        next.roles?["root"]?.threshold = 32
        let crossSigned = try TrustCanonicalJSON.encode(SignedEnvelope.sign(
            TrustCanonicalJSON.encode(next), type: TrustRole.root.payloadType, keys: previous + fixture.keys[.root]!
        ))
        #expect(try SignedEnvelope.decode(crossSigned).signatures.count == 64)
        try store.rotate([crossSigned], now: fixture.now)
        try store.refresh(fixture.bundle(), now: fixture.now)
        _ = try store.verify(fixture.profile(), type: fixture.type, now: fixture.now)
    }

    @Test func preRotationStateMigratesWithoutResettingCounters() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        try store.refresh(fixture.bundle(version: 2), now: fixture.now)
        let path = fixture.directory.appendingPathComponent("state.json")
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        legacy.removeValue(forKey: "rotations")
        try JSONSerialization.data(withJSONObject: legacy).write(to: path)
        #expect(try store.currentRootVersion(now: fixture.now) == 1)
        #expect(throws: TrustError.rollback("timestamp")) { try store.refresh(fixture.bundle(), now: fixture.now) }
        _ = try store.verify(fixture.profile(), type: fixture.type, now: fixture.now)
    }

    @Test func expiredRootCanAuthenticateFreshRecovery() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }
        let store = try fixture.bootstrap()
        try store.refresh(fixture.bundle(), now: fixture.now)
        let later = try trustDate("2031-01-01T00:00:00Z")
        #expect(throws: TrustError.expired("root")) {
            try store.verify(fixture.profile(), type: fixture.type, now: later)
        }
        var next = try fixture.root(version: 2)
        #expect(throws: TrustError.expired("root")) { try store.rotate([fixture.signed(next)], now: later) }
        next.expiresAt = "2040-01-01T00:00:00Z"
        try store.rotate([fixture.signed(next)], now: later)
        try store.refresh(fixture.bundle(version: 2) {
            $0.expiresAt = "2040-01-01T00:00:00Z"
            if let targets = $0.targets {
                $0.targets = targets.mapValues {
                    var target = $0
                    target.expiresAt = "2040-01-01T00:00:00Z"
                    return target
                }
            }
        }, now: later)
        _ = try store.verify(fixture.profile(), type: fixture.type, now: later)
    }
}
