// Author: Timur Isaev

import Foundation

extension ChainValidation {
    static func nextRoot(_ bytes: Data, after previous: TrustMetadata, now: Date) throws -> TrustMetadata {
        let envelope = try SignedEnvelope.decode(bytes)
        let candidate = try root(bytes, now: now, allowExpired: true)
        guard candidate.version == previous.version + 1 else { throw TrustError.rollback("root") }
        guard candidate.scope == previous.scope else { throw TrustError.wrongRole }
        let (keys, threshold) = try previous.authorized(.root)
        _ = try envelope.verify(type: TrustRole.root.payloadType, keys: keys, threshold: threshold)
        return candidate
    }

    static func currentRoot(_ state: TrustState, now: Date, allowExpired: Bool = false) throws -> TrustMetadata {
        var current = try root(state.root, now: now, allowExpired: true)
        guard state.rotations.count <= 128 else { throw TrustError.invalidRoot }
        for bytes in state.rotations { current = try nextRoot(bytes, after: current, now: now) }
        if !allowExpired { try requireFresh(current.expiresAt, now: now, role: "root") }
        return current
    }
}

extension TrustStore {
    /// Each successor is authorized by both old and new root thresholds.
    /// Expired historical roots may authenticate recovery; the final root is fresh.
    public func rotate(_ successors: [Data], now: Date) throws {
        guard !successors.isEmpty else { throw TrustError.invalidRoot }
        try locked {
            var state = try load(now: now)
            guard state.rotations.count + successors.count <= 128 else { throw TrustError.invalidRoot }
            var root = try ChainValidation.currentRoot(state, now: now, allowExpired: true)
            for bytes in successors {
                root = try ChainValidation.nextRoot(bytes, after: root, now: now)
                guard Set(root.keys!.keys).isDisjoint(with: state.revokedKeys) else { throw TrustError.revokedKey }
                state.rotations.append(bytes)
            }
            try requireFresh(root.expiresAt, now: now, role: "root")
            // A fresh bundle must meet the new key policy. Retain all version
            // and revocation high-water marks across the rotation.
            state.bundle = nil
            try save(state)
        }
    }
}
