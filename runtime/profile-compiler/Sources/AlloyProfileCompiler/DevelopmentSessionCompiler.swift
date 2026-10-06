// Author: Timur Isaev

import Foundation

/// Explicit synthetic input, separate from profile selection and production authorization.
public struct DevelopmentSessionInput: Codable, Sendable {
    public struct Policy: Codable, Sendable {
        public let id: String
        public let providerDirectory: String
        public let resolved: ResolvedProcessPolicy

        var snapshot: SnapshotPolicy {
            SnapshotPolicy(id: id, providerDirectory: providerDirectory, resolved: resolved)
        }
    }

    public struct Process: Codable, Sendable {
        public let path: String
        public let imageSHA256: String
        public let machine: PEMachine
        public let policy: Policy
    }

    public let schemaVersion: String
    public let syntheticOnly: Bool
    public let filesystem: String
    public let gameID: String
    public let buildID: String
    public let runtimeGenerationID: String
    public let runtimeTreeDigest: String
    public let host: HostCapabilities
    public let createdAt: String
    public let volumes: [String: String]
    public let defaultPolicy: Policy
    public let processes: [Process]

    public static func decode(_ bytes: Data) throws -> Self {
        let canonical = try CanonicalJSON.encode(bytes)
        let input = try JSONDecoder().decode(Self.self, from: canonical)
        guard try CanonicalJSON.encode(input) == canonical else {
            throw CompilerFailure.rejected("unknown or null development session field")
        }
        return input
    }
}

public enum DevelopmentSessionCompiler {
    public static let format = "alloy-synthetic-session-v1"

    public static func compile(_ bytes: Data) throws -> CompiledLaunch {
        let input = try DevelopmentSessionInput.decode(bytes)
        try validate(input)
        let processes = input.processes.sorted { $0.path < $1.path }
        let snapshot = try PolicySnapshotExporter.export(
            defaultPolicy: input.defaultPolicy.snapshot,
            processes: processes.map { SnapshotProcess(imageSHA256: $0.imageSHA256, policy: $0.policy.snapshot) }
        )
        let sourceDigest = CanonicalJSON.digest(try CanonicalJSON.encode(input))
        let resolved = processes.map {
            LaunchProcess(identity: ProcessIdentity(path: $0.path, sha256: $0.imageSHA256, peMachine: $0.machine),
                          policy: $0.policy.resolved)
        }
        let hostID = try input.host.localClassId()
        let make: (String) -> LaunchSpecification = { identifier in
            LaunchSpecification(
                schemaVersion: "1.0", localFormatVersion: format, launchSpecId: identifier,
                gameId: input.gameID, gameBuildId: input.buildID, launcherBuildId: nil, hostClassId: hostID,
                runtimeGenerationId: input.runtimeGenerationID,
                profile: .init(id: "synthetic-development", revision: 1, payloadDigest: sourceDigest),
                policyCompiler: .init(version: LaunchCompiler.version, snapshotDigest: snapshot.digest),
                volumes: input.volumes, grants: [],
                certification: .init(level: .experimental, matrixDigest: sourceDigest),
                createdAt: input.createdAt, verification: "unsigned-synthetic-development",
                productionEligible: false, runtimeReady: snapshot.runtimeReady,
                notYetLowered: snapshot.notYetLowered,
                inputDigests: ["development": sourceDigest, "host": hostID],
                componentDigests: ["runtimeTree": input.runtimeTreeDigest],
                cacheEpochs: ["runtime": input.runtimeTreeDigest, "policy": snapshot.digest],
                processes: resolved, defaultProcessPolicy: input.defaultPolicy.resolved
            )
        }
        let identifier = "ls_" + CanonicalJSON.digest(try CanonicalJSON.encode(make(""))).dropFirst(7)
        let specification = make(identifier)
        return CompiledLaunch(specification: specification, canonicalJSON: try CanonicalJSON.encode(specification),
                              snapshot: snapshot, verificationProvenance: "unsigned-synthetic-development")
    }

    public static func verifyExport(_ bytes: Data, input: Data) throws -> LaunchSpecification {
        let compiled = try compile(input)
        guard try CanonicalJSON.encode(bytes) == compiled.canonicalJSON else {
            throw CompilerFailure.rejected("development session export does not reproduce")
        }
        return compiled.specification
    }

    private static func validate(_ input: DevelopmentSessionInput) throws {
        guard input.schemaVersion == format, input.syntheticOnly,
              input.filesystem == "title-volumes-namespace-v1",
              (1...32).contains(input.processes.count),
              input.runtimeTreeDigest.hasPrefix("sha256:"), isHexDigest(String(input.runtimeTreeDigest.dropFirst(7))),
              ISO8601DateFormatter().date(from: input.createdAt) != nil,
              Set(input.volumes.keys) == ["runtime", "game", "saves", "settings", "cache", "temp"],
              Set(input.volumes.values).count == 6 else {
            throw CompilerFailure.rejected("unsupported development session contract")
        }
        for value in [input.gameID, input.buildID, input.runtimeGenerationID] + Array(input.volumes.values) {
            guard !value.isEmpty, value.utf8.count <= 128, !value.hasPrefix("."),
                  value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0)
                      || [45, 46, 95].contains($0) }) else {
                throw CompilerFailure.rejected("invalid development session identity")
            }
        }
        guard input.defaultPolicy.resolved.cpuProvider == "native-arm64ec",
              input.defaultPolicy.resolved.dllOverrides.values.contains("disabled"),
              Set(input.processes.map(\.imageSHA256)).count == input.processes.count,
              Set(input.processes.map { $0.path.lowercased() }).count == input.processes.count else {
            throw CompilerFailure.rejected(
                "development default must restrict CPU and DLL loading; identities must be unique"
            )
        }
        for process in input.processes {
            try path(process.path, drive: "G", prefix: "")
            guard process.path.lowercased().hasSuffix(".exe"), isHexDigest(process.imageSHA256),
                  [.arm64, .x64].contains(process.machine) else {
                throw CompilerFailure.rejected("unsupported synthetic executable identity")
            }
        }
        for policy in [input.defaultPolicy] + input.processes.map(\.policy) {
            try path(policy.providerDirectory, drive: "C", prefix: "alloy\\providers\\")
            if let cwd = policy.resolved.workingDirectory { try path(cwd, drive: "G", prefix: "") }
        }
    }

    private static func path(_ value: String, drive: String, prefix: String) throws {
        let start = drive + ":\\" + prefix
        let parts = value.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
        guard value.hasPrefix(start), value.utf8.count <= 240, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".")
                  && !$0.hasSuffix(" ") && $0.utf8.allSatisfy({ (32...126).contains($0)
                      && !Array("/:*?\"<>|".utf8).contains($0) }) }) else {
            throw CompilerFailure.rejected("development path is outside its drive binding")
        }
    }
}
