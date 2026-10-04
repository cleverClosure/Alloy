// Author: Timur Isaev

import CryptoKit
import Foundation

enum SemanticValidation {
    static func validateEvidence(
        _ evidence: LaunchEvidence, candidate: ProfileCandidate, input: SelectionInput, vendorKeys: [String: Data]
    ) throws -> FeatureMaskRegistry {
        guard evidence.profileDigest == candidate.profilePayload.digest,
              evidence.manifestDigest == candidate.manifestPayload.digest,
              evidence.metadataDigest == candidate.metadataPayload.digest,
              evidence.gameBuildDigest == (try input.gameBuild.digest()),
              evidence.launcherBuildDigest == (try input.launcherBuild?.digest()),
              evidence.hostClassId == (try input.host.localClassId()),
              evidence.matrixDigest == candidate.profile.certification.matrixDigest else {
            throw CompilerFailure.rejected("certification evidence is not bound to the exact launch inputs")
        }
        try validateLifecycle(evidence, candidate: candidate, now: input.now)
        if candidate.profile.certification.level == .competitiveCertified {
            try validateVendor(evidence, input: input, keys: vendorKeys)
        }
        try validateWorkarounds(evidence, profile: candidate.profile, input: input)
        var registry = try FeatureMaskRegistry(ceilings: evidence.ceilings, fixtureOnly: evidence.fixtureCeilingsOnly)
        for mask in evidence.masks {
            try registry.register(mask)
            guard !mask.workaroundIds.isEmpty,
                  Set(mask.workaroundIds).isSubset(of: Set(evidence.workarounds.map(\.id))) else {
                throw CompilerFailure.rejected("feature mask requires scoped workaround evidence")
            }
        }
        try validateComponents(candidate, evidence: evidence)
        return registry
    }

    static func validatePolicy(
        _ policy: ResolvedProcessPolicy, evidence: LaunchEvidence, registry: FeatureMaskRegistry
    ) throws {
        let providers = [policy.cpuProvider, policy.graphicsProvider, policy.syncProvider]
            + Array(policy.services.values)
        guard providers.allSatisfy({ evidence.providers[$0] != nil }) else {
            throw CompilerFailure.rejected("selected provider does not exist in runtime bindings")
        }
        if let identifier = policy.featureMask {
            guard let mask = registry.masks[identifier], mask.provider == policy.graphicsProvider,
                  mask.workaroundIds.contains(where: { identifier in
                      evidence.workarounds.contains { $0.id == identifier && policy.ruleIds.contains($0.processPolicy) }
                  }) else { throw CompilerFailure.rejected("missing or mismatched feature mask") }
        }
    }

    private static func validateLifecycle(_ evidence: LaunchEvidence, candidate: ProfileCandidate, now: Date) throws {
        let profile = candidate.profile
        let expected: [String: ReleaseRing] = [
            "draft": .development, "review": .development, "lab": .lab, "canary": .canary, "stable": .stable
        ]
        guard expected[evidence.lifecycle] == candidate.metadata.releaseRing else {
            throw CompilerFailure.rejected("withdrawn lifecycle or release-ring mismatch")
        }
        guard let tested = parseTimestamp(profile.certification.testedAt), tested <= now else {
            throw CompilerFailure.rejected("certification test date is in the future")
        }
        guard let evidenceExpiry = parseTimestamp(evidence.certificationExpiresAt),
              evidenceExpiry > now, evidenceExpiry > tested else {
            throw CompilerFailure.rejected("expired certification")
        }
        if let expiry = profile.certification.expiresAt {
            guard let expires = parseTimestamp(expiry), expires > now, expires > tested else {
                throw CompilerFailure.rejected("expired certification")
            }
            guard evidenceExpiry <= expires else {
                throw CompilerFailure.rejected("evidence cannot extend profile certification expiry")
            }
        }
        if candidate.profilePayload.verification == "unsigned-development" {
            guard candidate.metadata.releaseRing == .development,
                  candidate.manifest.activation?.releaseRing ?? .development == .development,
                  profile.certification.level == .experimental else {
                throw CompilerFailure.rejected("unsigned changes cannot claim stable or certified status")
            }
        }
    }

    private static func validateVendor(_ evidence: LaunchEvidence, input: SelectionInput, keys: [String: Data]) throws {
        guard let approval = evidence.vendorApproval, !approval.vendorId.isEmpty,
              approval.scope == "competitive-certified", approval.gameBuildDigest == evidence.gameBuildDigest,
              approval.profileDigest == evidence.profileDigest, approval.hostClassId == evidence.hostClassId,
              approval.matrixDigest == evidence.matrixDigest,
              parseTimestamp(approval.expiresAt).map({ $0 > input.now }) == true,
              let keyData = keys[approval.keyId], let signature = Data(base64Encoded: approval.signature) else {
            throw CompilerFailure.rejected("competitive certification requires scoped vendor approval")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard try key.isValidSignature(signature, for: CanonicalJSON.encode(approval.claims)) else {
            throw CompilerFailure.rejected("invalid vendor scope signature")
        }
    }

    private static func validateWorkarounds(
        _ evidence: LaunchEvidence, profile: GameProfileDocument, input: SelectionInput
    ) throws {
        guard Set(evidence.workarounds.map(\.id)).count == evidence.workarounds.count else {
            throw CompilerFailure.rejected("duplicate workaround identity")
        }
        for record in evidence.workarounds {
            let required = [record.id, record.owner, record.reason, record.removalCondition, record.performanceRisk]
            guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  record.gameBuild == input.gameBuild.id, profile.processPolicies.contains(where: {
                      $0.id == record.processPolicy
                  }), record.introducedInProfileRevision > 0, record.introducedInProfileRevision <= profile.revision,
                  !record.testEvidence.isEmpty, record.testEvidence.allSatisfy(validDigest),
                  parseTimestamp(record.expiresAt).map({ $0 > input.now }) == true else {
                throw CompilerFailure.rejected("incomplete, expired, or incorrectly scoped workaround")
            }
        }
        for policy in profile.processPolicies where nonDefaultBehavior(policy, runtime: profile.runtime) {
            guard evidence.workarounds.contains(where: { $0.processPolicy == policy.id }) else {
                throw CompilerFailure.rejected("non-default process behavior requires a workaround record")
            }
        }
    }

    private static func nonDefaultBehavior(_ policy: ProcessPolicy, runtime: RuntimeConfiguration) -> Bool {
        let execution = policy.execution
        let changes = [
            (execution.cpuProvider?.rawValue, runtime.cpuProvider.rawValue),
            (execution.graphicsProvider?.rawValue, runtime.defaultGraphicsProvider.rawValue),
            (execution.syncProvider?.rawValue, runtime.syncProvider?.rawValue ?? "conservative")
        ]
        return changes.contains { value, baseline in value != nil && value != "inherit" && value != baseline }
            || execution.featureMask != nil || !(execution.dllOverrides ?? [:]).isEmpty
    }

    private static func validateComponents(_ candidate: ProfileCandidate, evidence: LaunchEvidence) throws {
        let components = candidate.manifest.components
        guard Set(components.map(\.name)).count == components.count else {
            throw CompilerFailure.rejected("duplicate runtime component name")
        }
        let digests = Set(components.map(\.digest))
        guard candidate.profile.runtime.layers.allSatisfy({ digests.contains($0.digest) }),
              evidence.providers.values.allSatisfy({ binding in
                  components.contains { $0.name == binding.component }
              }) else {
            throw CompilerFailure.rejected("runtime layer or provider component is missing")
        }
        for dependency in candidate.profile.dependencies ?? [] {
            guard let digest = dependency.digest, validDigest(digest), digests.contains(digest),
                  evidence.approvedDependencyDigests.contains(digest), dependency.licenseGate?.isEmpty == false else {
                throw CompilerFailure.rejected("dependency lacks immutable provenance or license approval")
            }
        }
    }
}

func validDigest(_ value: String) -> Bool {
    value.hasPrefix("sha256:") && isHexDigest(String(value.dropFirst(7)))
}
