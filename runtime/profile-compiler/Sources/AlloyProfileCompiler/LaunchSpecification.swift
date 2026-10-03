// Author: Timur Isaev

import Foundation

public struct LaunchSpecification: Codable, Equatable, Sendable {
    public struct ProfileReference: Codable, Equatable, Sendable {
        public let id: String
        public let revision: Int
        public let payloadDigest: String
    }
    public struct CompilerReference: Codable, Equatable, Sendable {
        public let version: String
        public let snapshotDigest: String
    }
    public struct Certification: Codable, Equatable, Sendable {
        public let level: CertificationLevel
        public let matrixDigest: String
    }
    public let schemaVersion: String
    public let localFormatVersion: String
    public let launchSpecId: String
    public let gameId: String
    public let gameBuildId: String
    public let launcherBuildId: String?
    public let hostClassId: String
    public let runtimeGenerationId: String
    public let profile: ProfileReference
    public let policyCompiler: CompilerReference
    public let volumes: [String: String]
    public let grants: [String]
    public let certification: Certification
    public let createdAt: String
    public let verification: String
    public let productionEligible: Bool
    public let runtimeReady: Bool
    public let notYetLowered: [SnapshotCoverageGap]
    public let inputDigests: [String: String]
    public let componentDigests: [String: String]
    public let cacheEpochs: [String: String]
    public let processes: [LaunchProcess]
    public let defaultProcessPolicy: ResolvedProcessPolicy
}

public struct LaunchProcess: Codable, Equatable, Sendable {
    public let identity: ProcessIdentity
    public let policy: ResolvedProcessPolicy
}

public struct CandidateEnvelopes: Codable, Sendable {
    public var profile: Data
    public var manifest: Data
    public var metadata: Data

    public init(profile: Data, manifest: Data, metadata: Data) {
        self.profile = profile
        self.manifest = manifest
        self.metadata = metadata
    }
}

public struct LaunchCompilationInput: Sendable {
    public var candidates: [CandidateEnvelopes]
    public var selection: SelectionInput
    public var evidenceEnvelope: Data
    public var verificationMode: VerificationMode
    public var vendorKeys: [String: Data]
    public var processes: [ProcessIdentity]
    public var volumes: [String: String]
    public var grants: [LocalGrant]
    public var availableRuntimeGenerations: Set<String>

    public init(
        candidates: [CandidateEnvelopes], selection: SelectionInput, evidenceEnvelope: Data,
        verificationMode: VerificationMode, vendorKeys: [String: Data] = [:], processes: [ProcessIdentity],
        volumes: [String: String], grants: [LocalGrant] = [], availableRuntimeGenerations: Set<String> = []
    ) {
        self.candidates = candidates
        self.selection = selection
        self.evidenceEnvelope = evidenceEnvelope
        self.verificationMode = verificationMode
        self.vendorKeys = vendorKeys
        self.processes = processes
        self.volumes = volumes
        self.grants = grants
        self.availableRuntimeGenerations = availableRuntimeGenerations
    }
}

public struct CompiledLaunch: Sendable {
    public let specification: LaunchSpecification
    public let canonicalJSON: Data
    public let snapshot: PolicySnapshotExport
}
