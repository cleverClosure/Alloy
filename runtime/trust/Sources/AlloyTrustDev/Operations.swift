// Author: Timur Isaev

import AlloyTrust
import Foundation

extension DevelopmentRepository {
    func rotate(role: TrustRole, now: Date) throws {
        let old = try metadata("root.json")
        var next = old
        next.version += 1
        next.expiresAt = expiry(now, days: 365)
        let oldRootKeys = try signingKeys(.root, root: old)
        for identifier in old.roles![role.rawValue]!.keyIds { next.keys?.removeValue(forKey: identifier) }
        let generated = try generateKeys()
        let identifiers = generated.map { SignedEnvelope.keyID($0.publicKey.rawRepresentation) }.sorted()
        for key in generated {
            next.keys?[SignedEnvelope.keyID(key.publicKey.rawRepresentation)] =
                key.publicKey.rawRepresentation.base64EncodedString()
        }
        next.roles?[role.rawValue] = RoleRule(keyIds: identifiers, threshold: 2)
        let bytes = try sign(next, keys: oldRootKeys + (role == .root ? generated : []))
        try write(bytes, name: "\(next.version).root.json")
        try write(bytes, name: "root.json")
        // Renew metadata with a version bump under the new role keys. Old
        // artifact signatures deliberately remain invalid after their key rotates.
        for name in ["targets.json", "revocation.json"] {
            var item = try metadata(name)
            item.version += 1
            item.expiresAt = expiry(now, days: 7)
            try write(sign(item, root: next), name: name)
        }
        try timestamp(now: now)
    }

    func revoke(kind: String, value: String, revision: Int?, now: Date) throws {
        let root = try metadata("root.json")
        var item = try metadata("revocation.json")
        switch kind {
        case "profile":
            guard let revision, revision > 0 else { throw TrustError.malformed("profile revision required") }
            item.revokedProfiles?.append(ProfileRevision(profileId: value, revision: revision))
        case "key":
            let allowed = [TrustRole.profiles, .manifests, .releases, .evidence].flatMap {
                root.roles?[$0.rawValue]?.keyIds ?? []
            }
            guard allowed.contains(value) else { throw TrustError.wrongRole }
            item.revokedKeys?.append(value)
        case "digest": item.revokedDigests?.append(value)
        default: throw TrustError.malformed("revoke kind")
        }
        item.version += 1
        item.expiresAt = expiry(now, days: 7)
        try write(sign(item, root: root), name: "revocation.json")
        try timestamp(now: now)
    }
}
