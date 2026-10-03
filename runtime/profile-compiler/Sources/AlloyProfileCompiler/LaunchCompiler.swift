// Author: Timur Isaev

import Foundation

public enum LaunchCompiler {
    public static let version = "0.5.0"

    public static func compile(_ input: LaunchCompilationInput) throws -> CompiledLaunch {
        guard (1...256).contains(input.candidates.count), (1...4095).contains(input.processes.count) else {
            throw CompilerFailure.rejected("candidate or process count exceeds launch bounds")
        }
        let candidates = try input.candidates.map {
            try ProfileCandidate(
                profile: $0.profile, manifest: $0.manifest, metadata: $0.metadata,
                mode: input.verificationMode, now: input.selection.now
            )
        }
        let chosen = try ProfileResolver.resolve(candidates, input: input.selection).requireSelected()
        let evidencePayload = try TestEnvelope.verify(
            input.evidenceEnvelope, type: .launchEvidence, mode: input.verificationMode, now: input.selection.now
        )
        let evidence = try LaunchEvidence.decode(evidencePayload.bytes)
        let registry = try SemanticValidation.validateEvidence(
            evidence, candidate: chosen, input: input.selection, vendorKeys: input.vendorKeys
        )
        let grants = try LaunchSecurity.validate(
            candidate: chosen, evidence: evidence, grants: input.grants, volumes: input.volumes,
            availableGenerations: input.availableRuntimeGenerations
        )
        let resolved = try resolveProcesses(input.processes, candidate: chosen, evidence: evidence, registry: registry)
        let fallback = ResolvedProcessPolicy.conservativeDefault(chosen.profile.runtime)
        try SemanticValidation.validatePolicy(fallback, evidence: evidence, registry: registry)
        let snapshot = try exportSnapshot(resolved, fallback: fallback, evidence: evidence)
        let artifacts = LaunchArtifacts(resolved: resolved, fallback: fallback, snapshot: snapshot, grants: grants)
        let specification = try makeSpecification(
            input, chosen: chosen, evidenceDigest: evidencePayload.digest, artifacts: artifacts
        )
        return CompiledLaunch(
            specification: specification, canonicalJSON: try CanonicalJSON.encode(specification), snapshot: snapshot
        )
    }

    /// Re-resolve the authoritative inputs, then compare complete canonical bytes.
    /// Unknown, missing, or changed output fields cannot be ignored by Codable.
    public static func verifyExport(_ bytes: Data, input: LaunchCompilationInput) throws -> LaunchSpecification {
        let compiled = try compile(input)
        guard try CanonicalJSON.encode(bytes) == compiled.canonicalJSON else {
            throw CompilerFailure.rejected("export does not reproduce the same launch specification")
        }
        return try JSONDecoder().decode(LaunchSpecification.self, from: bytes)
    }

    private static func resolveProcesses(
        _ processes: [ProcessIdentity], candidate: ProfileCandidate, evidence: LaunchEvidence,
        registry: FeatureMaskRegistry
    ) throws -> [LaunchProcess] {
        var pending = try processes.map { process in
            var normalized = process
            normalized.path = try windowsPath(process.path)
            normalized.moduleFingerprints = Array(Set(process.moduleFingerprints)).sorted()
            guard let digest = normalized.sha256, isHexDigest(digest) else {
                throw CompilerFailure.rejected("snapshot export requires every observed executable digest")
            }
            return normalized
        }.sorted { ($0.path, $0.sha256 ?? "") < ($1.path, $1.sha256 ?? "") }
        var parents: [String: ResolvedProcessPolicy] = [:]
        var result: [LaunchProcess] = []
        while !pending.isEmpty {
            guard let index = pending.firstIndex(where: {
                $0.parentPolicyId == nil || parents[$0.parentPolicyId!] != nil
            }) else { throw CompilerFailure.rejected("unresolved or cyclic process parent") }
            let process = pending.remove(at: index)
            let policy = try ProcessResolver.resolve(
                candidate.profile.processPolicies, runtime: candidate.profile.runtime, process: process,
                parent: process.parentPolicyId.flatMap { parents[$0] }
            )
            for identifier in policy.ruleIds {
                if let approvedDigest = evidence.processDigests[identifier], approvedDigest != process.sha256 {
                    throw CompilerFailure.rejected("observed process differs from signed evidence fingerprint")
                }
            }
            try SemanticValidation.validatePolicy(policy, evidence: evidence, registry: registry)
            for identifier in policy.ruleIds {
                if let earlier = parents[identifier], earlier != policy {
                    throw CompilerFailure.rejected("ambiguous resolved parent policy")
                }
                parents[identifier] = policy
            }
            result.append(LaunchProcess(identity: process, policy: policy))
        }
        return result.sorted {
            ($0.identity.path, $0.identity.sha256 ?? "") < ($1.identity.path, $1.identity.sha256 ?? "")
        }
    }

    private static func exportSnapshot(
        _ processes: [LaunchProcess], fallback: ResolvedProcessPolicy, evidence: LaunchEvidence
    ) throws -> PolicySnapshotExport {
        func policy(_ resolved: ResolvedProcessPolicy) throws -> SnapshotPolicy {
            guard let binding = evidence.providers[resolved.graphicsProvider] else {
                throw CompilerFailure.rejected("missing graphics binding")
            }
            let identifier = resolved.ruleIds.count == 1 ? resolved.ruleIds[0]
                : "resolved_" + CanonicalJSON.digest(try CanonicalJSON.encode(resolved)).dropFirst(7).prefix(40)
            return SnapshotPolicy(id: identifier, providerDirectory: binding.directory, resolved: resolved)
        }
        let defaultBinding = try policy(fallback)
        return try PolicySnapshotExporter.export(
            defaultPolicy: SnapshotPolicy(
                id: "unknown-restricted", providerDirectory: defaultBinding.providerDirectory, resolved: fallback
            ),
            processes: processes.map { process in
                SnapshotProcess(imageSHA256: process.identity.sha256!, policy: try policy(process.policy))
            }
        )
    }

    private struct LaunchArtifacts {
        let resolved: [LaunchProcess]
        let fallback: ResolvedProcessPolicy
        let snapshot: PolicySnapshotExport
        let grants: [String]
    }

    private static func makeSpecification(
        _ input: LaunchCompilationInput, chosen: ProfileCandidate, evidenceDigest: String, artifacts: LaunchArtifacts
    ) throws -> LaunchSpecification {
        let resolved = artifacts.resolved
        let fallback = artifacts.fallback
        let snapshot = artifacts.snapshot
        let grants = artifacts.grants
        let hostId = try input.selection.host.localClassId()
        var digests = [
            "profile": chosen.profilePayload.digest, "manifest": chosen.manifestPayload.digest,
            "metadata": chosen.metadataPayload.digest, "evidence": evidenceDigest,
            "gameBuild": try input.selection.gameBuild.digest(), "host": hostId,
            "processes": CanonicalJSON.digest(try CanonicalJSON.encode(resolved))
        ]
        if let launcher = input.selection.launcherBuild { digests["launcherBuild"] = try launcher.digest() }
        let cacheBinding = try CanonicalJSON.encode(digests)
        let epochs = [
            "shader": CanonicalJSON.digest(Data("shader-v1:".utf8) + cacheBinding),
            "cpu": CanonicalJSON.digest(Data("cpu-v1:".utf8) + cacheBinding)
        ]
        let gaps = (snapshot.notYetLowered + profileCoverage(chosen.profile)).sorted {
            ($0.policyId, $0.field) < ($1.policyId, $1.field)
        }
        let make: (String) -> LaunchSpecification = { identifier in
            LaunchSpecification(
                schemaVersion: "1.0", localFormatVersion: "alloy-launch-spec-v1", launchSpecId: identifier,
                gameId: input.selection.gameId, gameBuildId: input.selection.gameBuild.id,
                launcherBuildId: input.selection.launcherBuild?.id, hostClassId: hostId,
                runtimeGenerationId: chosen.manifest.generationId,
                profile: .init(id: chosen.profile.profileId, revision: chosen.profile.revision,
                               payloadDigest: chosen.profilePayload.digest),
                policyCompiler: .init(version: version, snapshotDigest: snapshot.digest),
                volumes: input.volumes, grants: grants,
                certification: .init(level: chosen.profile.certification.level,
                                     matrixDigest: chosen.profile.certification.matrixDigest),
                createdAt: ISO8601DateFormatter().string(from: input.selection.now),
                verification: chosen.profilePayload.verification, productionEligible: false,
                runtimeReady: gaps.isEmpty, notYetLowered: gaps, inputDigests: digests,
                componentDigests: Dictionary(uniqueKeysWithValues: chosen.manifest.components.map {
                    ($0.name, $0.digest)
                }),
                cacheEpochs: epochs, processes: resolved, defaultProcessPolicy: fallback
            )
        }
        let identifier = "ls_" + CanonicalJSON.digest(try CanonicalJSON.encode(make(""))).dropFirst(7)
        return make(identifier)
    }

    private static func profileCoverage(_ profile: GameProfileDocument) -> [SnapshotCoverageGap] {
        var fields = ["filesystem.authorization"]
        if profile.registry != nil { fields.append("registry") }
        if !(profile.dependencies ?? []).isEmpty { fields.append("dependencies.installation") }
        if !(profile.healthChecks ?? []).isEmpty { fields.append("healthChecks") }
        if profile.telemetry != nil { fields.append("telemetry") }
        if profile.runtime.windowsVersion != nil { fields.append("runtime.windowsVersion") }
        if profile.runtime.locale != nil { fields.append("runtime.locale") }
        if profile.runtime.timezoneMode != nil { fields.append("runtime.timezoneMode") }
        return fields.map {
            SnapshotCoverageGap(
                policyId: "profile", field: $0, reason: "bound to profile digest; requires runtime enforcement"
            )
        }
    }
}
