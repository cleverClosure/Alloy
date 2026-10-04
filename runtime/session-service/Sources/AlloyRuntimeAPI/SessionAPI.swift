// Author: Timur Isaev
import AlloyContentStore
import AlloyProfileCompiler
import Foundation

public struct DevelopmentLaunchInput: Codable, Sendable {
    public let profile: Data
    public let manifest: Data
    public let metadata: Data
    public let evidence: Data
    public let build: BuildIdentity
    public let processes: [ProcessIdentity]
    public let volumes: [String: String]
    public let validForSeconds: Int
}

public struct LaunchPreview: Codable, Sendable {
    public let previewID: String
    public let expiresAt: TimeInterval
    public let specification: LaunchSpecification
    public let canonicalExport: Data
    public let generation: GenerationReference
    public init(previewID: String, expiresAt: TimeInterval, specification: LaunchSpecification,
                canonicalExport: Data, generation: GenerationReference) {
        self.previewID = previewID
        self.expiresAt = expiresAt
        self.specification = specification
        self.canonicalExport = canonicalExport
        self.generation = generation
    }
}

public enum FixtureScenario: String, Codable, Sendable {
    case normal, hang, ignoreTermination, startupFailure
}

public struct FixtureStart: Codable, Sendable {
    public let previewID: String
    public let key: String
    public let scenario: FixtureScenario
    public init(previewID: String, key: String, scenario: FixtureScenario) {
        self.previewID = previewID
        self.key = key
        self.scenario = scenario
    }
}

public struct FixtureSessionRecord: Codable, Sendable {
    public let sessionID: String
    public let request: FixtureStart
    public let preview: LaunchPreview
    public let fixtureDigest: String
    public init(sessionID: String, request: FixtureStart, preview: LaunchPreview, fixtureDigest: String) {
        self.sessionID = sessionID
        self.request = request
        self.preview = preview
        self.fixtureDigest = fixtureDigest
    }
}

public struct FixtureNode: Codable, Sendable {
    public let name: String
    public let state: String
    public let lease: GenerationLease
    public init(name: String, state: String, lease: GenerationLease) {
        self.name = name
        self.state = state
        self.lease = lease
    }
}

public struct SessionSnapshot: Codable, Sendable {
    public let record: FixtureSessionRecord
    public let state: String
    public let nodes: [FixtureNode]
    public let liveNodes: [String]
    public let exitCode: Int32?
    public init(record: FixtureSessionRecord, state: String, nodes: [FixtureNode],
                liveNodes: [String], exitCode: Int32?) {
        self.record = record
        self.state = state
        self.nodes = nodes
        self.liveNodes = liveNodes
        self.exitCode = exitCode
    }
}
