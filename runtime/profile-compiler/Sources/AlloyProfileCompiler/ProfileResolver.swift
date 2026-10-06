// Author: Timur Isaev

import Foundation

public enum MatchOutcome: String, Codable, Sendable {
    case exact, compatibleAlias, stale, unknown, conflict
}

public struct ProfileResolution: Sendable {
    public let outcome: MatchOutcome
    public let selected: ProfileCandidate?
    public let rejectedCandidates: [String: String]

    public func requireSelected() throws -> ProfileCandidate {
        guard let selected else { throw CompilerFailure.rejected("profile-\(outcome.rawValue)") }
        return selected
    }
}

public enum ProfileResolver {
    public static func resolve(_ candidates: [ProfileCandidate], input: SelectionInput) throws -> ProfileResolution {
        let refreshed = try candidates.map { candidate in
            if let binding = candidate.trustBinding {
                return try ProfileCandidate(profile: binding.envelopes.profile, manifest: binding.envelopes.manifest,
                                            metadata: binding.envelopes.metadata,
                                            mode: .trustChain(store: binding.store), now: input.now)
            }
            return candidate
        }
        return try resolveValidated(refreshed, input: input)
    }

    static func resolveValidated(_ candidates: [ProfileCandidate], input: SelectionInput) throws -> ProfileResolution {
        var matches: [(candidate: ProfileCandidate, alias: Bool)] = []
        var rejections: [String: String] = [:]
        var stale = false
        for candidate in candidates {
            let evaluation = try evaluate(candidate, input: input)
            if let reason = evaluation.reason {
                rejections[candidate.profilePayload.digest] = reason
                if reason == "game-build", input.previouslyMatchedDigests.contains(candidate.profilePayload.digest) {
                    stale = true
                }
            } else {
                // Repeated copies of the same payload + metadata + manifest are one candidate.
                if !matches.contains(where: {
                    $0.candidate.profilePayload.digest == candidate.profilePayload.digest
                        && $0.candidate.metadataPayload.digest == candidate.metadataPayload.digest
                        && $0.candidate.manifestPayload.digest == candidate.manifestPayload.digest
                }) { matches.append((candidate, evaluation.alias)) }
            }
        }
        if matches.isEmpty {
            return ProfileResolution(outcome: stale ? .stale : .unknown, selected: nil, rejectedCandidates: rejections)
        }
        let maximumSpecificity = matches.map { Self.specificity($0.candidate.profile, input: input) }.max()!
        matches = matches.filter { Self.specificity($0.candidate.profile, input: input) == maximumSpecificity }
        let certification = matches.map { certificationRank($0.candidate.metadata.approvedCertification) }.max()!
        matches = matches.filter { certificationRank($0.candidate.metadata.approvedCertification) == certification }
        matches = newestWithinFamily(matches)
        let beforeSupersession = matches
        matches = matches.filter { target in
            !beforeSupersession.contains { source in
                source.candidate.profile.profileId != target.candidate.profile.profileId
                    && source.candidate.profile.supersedes?.contains(target.candidate.profile.profileId) == true
                    && trustRank(source.candidate.metadata.releaseRing)
                        >= trustRank(target.candidate.metadata.releaseRing)
            }
        }
        let hasStable = matches.contains { $0.candidate.metadata.releaseRing == .stable }
        if !input.client.canaryClient, hasStable {
            matches.removeAll { $0.candidate.metadata.releaseRing == .canary }
        }
        guard matches.count == 1, let winner = matches.first else {
            return ProfileResolution(outcome: .conflict, selected: nil, rejectedCandidates: rejections)
        }
        return ProfileResolution(
            outcome: winner.alias ? .compatibleAlias : .exact, selected: winner.candidate,
            rejectedCandidates: rejections
        )
    }

    private static func newestWithinFamily(
        _ matches: [(candidate: ProfileCandidate, alias: Bool)]
    ) -> [(candidate: ProfileCandidate, alias: Bool)] {
        var revisions: [String: Int] = [:]
        for entry in matches {
            let profile = entry.candidate.profile
            revisions[profile.profileId] = max(revisions[profile.profileId] ?? 0, profile.revision)
        }
        return matches.filter { $0.candidate.profile.revision == revisions[$0.candidate.profile.profileId] }
    }

    private static func evaluate(
        _ candidate: ProfileCandidate, input: SelectionInput
    ) throws -> (reason: String?, alias: Bool) {
        let profile = candidate.profile
        let metadata = candidate.metadata
        try validateTime(candidate, now: input.now)
        guard profile.game.canonicalId == input.gameId, profile.game.storefronts.contains(where: {
            $0.kind == input.storefront && $0.appId == input.appId && ($0.branch == nil || $0.branch == input.branch)
        }) else { return ("game-storefront", false) }
        let exactGame = try input.gameBuild.matches(profile.selectors.gameBuild)
        guard try exactGame || metadata.gameAliases.contains(input.gameBuild.digest()) else {
            return ("game-build", false)
        }
        var alias = !exactGame
        if let selector = profile.selectors.launcherBuild {
            guard let launcher = input.launcherBuild else { return ("launcher-build", false) }
            if try !launcher.matches(selector) {
                guard metadata.launcherAliases.contains(try launcher.digest()) else { return ("launcher-build", false) }
                alias = true
            }
        }
        guard try input.host.matches(profile.selectors.host),
              try input.host.matches(candidate.manifest.hostRequirements),
              !metadata.deniedMacOSBuilds.contains(input.host.macOSBuild),
              Set(metadata.requiredFeatures).isSubset(of: Set(input.host.features)) else { return ("host", false) }
        guard metadata.releaseRing != .quarantined,
              input.client.allowedRings.contains(metadata.releaseRing),
              metadata.eligibleClientIds.map({ $0.contains(input.client.id) }) ?? true else {
            return ("eligibility", false)
        }
        return (try eligibility(candidate, input: input), alias)
    }

    private static func eligibility(_ candidate: ProfileCandidate, input: SelectionInput) throws -> String? {
        let manifestRing = candidate.manifest.activation?.releaseRing ?? .development
        guard manifestRing != .quarantined, input.client.allowedRings.contains(manifestRing) else {
            return "runtime-ring"
        }
        let minimums = [candidate.metadata.minimumClientVersion, candidate.manifest.activation?.minimumClientVersion]
        for minimum in minimums.compactMap({ $0 })
            where try SemanticVersion(input.client.version) < SemanticVersion(minimum) {
            return "client-version"
        }
        return nil
    }

    private static func validateTime(_ candidate: ProfileCandidate, now: Date) throws {
        let expiries = [candidate.profilePayload.expiresAt, candidate.manifestPayload.expiresAt,
                       candidate.metadataPayload.expiresAt, candidate.profile.certification.expiresAt].compactMap { $0 }
        guard expiries.allSatisfy({ parseTimestamp($0).map { $0 > now } == true }) else {
            throw CompilerFailure.rejected("expired candidate")
        }
    }

    private static func specificity(_ profile: GameProfileDocument, input: SelectionInput) -> Int {
        func build(_ selector: BuildSelector) -> Int {
            [selector.version, selector.manifestId].compactMap { $0 }.count
                + (selector.requiredFiles ?? []).reduce(0) { $0 + 1 + ($1.size == nil ? 0 : 1)
                    + ($1.peTimestamp == nil ? 0 : 1) }
        }
        let host = profile.selectors.host
        return build(profile.selectors.gameBuild) + (profile.selectors.launcherBuild.map(build) ?? 0)
            + [host.macos?.min, host.macos?.maxExclusive].compactMap { $0 }.count
            + (host.macos?.allowedBuilds == nil ? 0 : 1) + (host.gpuFamilies == nil ? 0 : 1)
            + (host.memoryClassesGiB == nil ? 0 : 1)
            + (profile.game.storefronts.contains(where: {
                $0.kind == input.storefront && $0.appId == input.appId && $0.branch == input.branch && $0.branch != nil
            }) ? 1 : 0)
    }
}

func certificationRank(_ level: CertificationLevel) -> Int {
    switch level {
    case .experimental: 0
    case .launches: 1
    case .playable: 2
    case .certified: 3
    case .competitiveCertified: 4
    }
}

func trustRank(_ ring: ReleaseRing) -> Int {
    switch ring {
    case .quarantined: -1
    case .development: 0
    case .lab: 1
    case .canary: 2
    case .stable: 3
    }
}
