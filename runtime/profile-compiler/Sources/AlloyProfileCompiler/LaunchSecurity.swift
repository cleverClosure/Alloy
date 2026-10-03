// Author: Timur Isaev

import Foundation

enum LaunchSecurity {
    static func validate(
        candidate: ProfileCandidate, evidence: LaunchEvidence, grants: [LocalGrant], volumes: [String: String],
        availableGenerations: Set<String>
    ) throws -> [String] {
        let profile = candidate.profile
        let requiredVolumes: Set<String> = ["runtime", "game", "saves", "settings", "cache", "temp"]
        guard Set(volumes.keys) == requiredVolumes, volumes.values.allSatisfy(opaqueLocalId),
              Set(grants.map(\.id)).count == grants.count, grants.allSatisfy({ opaqueLocalId($0.id) }) else {
            throw CompilerFailure.rejected("invalid local volumes or ambiguous grants")
        }
        if candidate.metadata.releaseRing == .stable {
            guard let rollback = candidate.manifest.activation?.rollbackGenerationId,
                  rollback != candidate.manifest.generationId, availableGenerations.contains(rollback) else {
                throw CompilerFailure.rejected("stable runtime requires an available rollback generation")
            }
        }
        let usedGrants = try validateDrives(profile, grants: grants)
        try validateProcesses(profile, evidence: evidence)
        for binding in evidence.providers.values {
            let path = try windowsPath(binding.directory)
            guard !path.hasPrefix("z:"), path.utf8.count > 3 else {
                throw CompilerFailure.rejected("provider directory must be a scoped runtime drive")
            }
        }
        try validateRegistry(profile.registry)
        return usedGrants
    }

    private static func validateDrives(_ profile: GameProfileDocument, grants: [LocalGrant]) throws -> [String] {
        if profile.filesystem?.denyHostRoot == false {
            throw CompilerFailure.rejected("host-root access cannot be enabled")
        }
        var usedGrants = Set<String>()
        var drives = Set<String>()
        for mapping in profile.filesystem?.driveMappings ?? [] {
            guard mapping.letter != "Z", drives.insert(mapping.letter).inserted,
                  mapping.target != .runtime || mapping.access == .readOnly else {
                throw CompilerFailure.rejected("unsafe or duplicate drive mapping")
            }
            if mapping.target == .userGrant {
                guard let identifier = mapping.grantId,
                      let grant = grants.first(where: { $0.id == identifier }),
                      grant.gameId == profile.game.canonicalId,
                      ["saves", "settings", "game", "media-import"].contains(grant.purpose),
                      mapping.access != .readWrite || grant.access == .readWrite else {
                    throw CompilerFailure.rejected("user grant does not authorize this game, purpose, and access")
                }
                usedGrants.insert(identifier)
            } else if mapping.grantId != nil {
                throw CompilerFailure.rejected("grant attached to a non-grant volume")
            }
        }
        return usedGrants.sorted()
    }

    private static func validateProcesses(_ profile: GameProfileDocument, evidence: LaunchEvidence) throws {
        for policy in profile.processPolicies {
            try validateEnvironment(policy.execution.environment ?? [:])
            if let directory = policy.execution.workingDirectory { _ = try windowsPath(directory) }
            // A path or product alone cannot authorize expanded network or native-DLL access.
            let expandsAccess = policy.execution.networkPolicy == .allow
                || policy.execution.networkPolicy == .publisherOnly
                || (policy.execution.dllOverrides ?? [:]).values.contains(where: {
                    $0 == .native || $0 == .nativeBuiltin || $0 == .builtinNative
                })
            let signedDigest = evidence.processDigests[policy.id]
            guard !expandsAccess || policy.match.sha256 != nil || signedDigest.map(isHexDigest) == true else {
                throw CompilerFailure.rejected("access-expanding rule requires an exact executable digest")
            }
        }
    }

    private static func validateEnvironment(_ values: [String: String]) throws {
        for (key, value) in values {
            let allowed: [String: String] = [
                "LANG": #"\A[a-z]{2,3}(_[A-Z]{2})?(\.[A-Za-z0-9-]{1,12})?\z"#,
                "LC_ALL": #"\A(C|POSIX|[a-z]{2,3}(_[A-Z]{2})?(\.[A-Za-z0-9-]{1,12})?)\z"#,
                "TZ": #"\A(UTC|[A-Za-z_]{1,32}/[A-Za-z_]{1,32})\z"#
            ]
            guard let pattern = allowed[key], value.range(of: pattern, options: .regularExpression) != nil else {
                throw CompilerFailure.rejected("environment key or value is outside the public-profile allowlist")
            }
        }
    }

    private static func validateRegistry(_ registry: RegistryPolicy?) throws {
        let paths = (registry?.sets ?? []).map(\.key) + (registry?.deletes ?? [])
        guard paths.allSatisfy({ $0.uppercased().hasPrefix("HKCU\\SOFTWARE\\") && !$0.contains("..") }) else {
            throw CompilerFailure.rejected("registry operation is outside the allowed hive")
        }
        let secretNames = ["password", "secret", "token", "credential", "authorization", "privatekey"]
        guard (registry?.sets ?? []).allSatisfy({ mutation in
            !secretNames.contains { mutation.name.lowercased().contains($0) }
        }) else { throw CompilerFailure.rejected("secret-bearing registry values cannot be public profile data") }
    }

    private static func opaqueLocalId(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
}
