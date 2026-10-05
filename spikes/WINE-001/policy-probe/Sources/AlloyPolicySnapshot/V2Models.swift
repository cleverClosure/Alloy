// Author: Timur Isaev

import Foundation

/// Runtime v2 is separate from the historical v1 encoder and oracle.
public enum PolicySnapshotV2Error: String, Error, CustomStringConvertible {
    case legacyVersion = "policy-legacy-version"
    case layout = "policy-layout"
    case integrity = "policy-integrity"
    case expectedDigest = "policy-expected-digest"
    case noncanonical = "policy-noncanonical"
    case invalidField = "policy-invalid-field"
    case source = "policy-source"

    public var description: String { rawValue }
}

public enum SnapshotCPUProvider: String, Codable, Sendable {
    case nativeArm64ec = "native-arm64ec"
    case fexArm64ec = "fex-arm64ec"

    var code: UInt32 { self == .nativeArm64ec ? 1 : 2 }
}

struct V2Source: Codable, Equatable {
    var schemaVersion: Int
    var defaultPolicy: V2Policy
    var processPolicies: [V2Process]
}

struct V2Process: Codable, Equatable {
    var imageSHA256: String
    var policy: V2Policy
}

struct V2Policy: Codable, Equatable {
    var id: String
    var graphicsProvider: String?
    var providerDirectory: String?
    var cpuProvider: SnapshotCPUProvider?
    var environment: [String: String]?
    var workingDirectory: String?
    var dllRoutes: [V2Route]?

    var presence: UInt32 {
        (graphicsProvider == nil ? 0 : 1) | (cpuProvider == nil ? 0 : 2) |
            (environment == nil ? 0 : 4) | (workingDirectory == nil ? 0 : 8) | (dllRoutes == nil ? 0 : 16)
    }
}

struct V2Route: Codable, Equatable {
    var module: String
    var loadOrder: LoadOrder
}

enum V2Format {
    static let magic = Data("ALLOYP02".utf8)
    static let header = 96
    static let entry = 7472
    static let maxEntries = 1024
    static let maxRoutes = 32
    static let maxEnvironment = 16
    static let maxBytes = header + entry * maxEntries
}

public struct PolicySnapshotV2Inspection: Codable, Equatable, Sendable {
    public let version: Int
    public let sourceDigest: String
    public let contentDigest: String
    public let entries: [PolicySnapshotV2Entry]
}

public struct PolicySnapshotV2Entry: Codable, Equatable, Sendable {
    public let imageSHA256: String?
    public let policyID: String
    public let defaultPolicy: Bool
    public let graphicsProvider: String?
    public let providerDirectory: String?
    public let cpuProvider: SnapshotCPUProvider?
    public let environment: [String: String]?
    public let workingDirectory: String?
    public let dllRoutes: [PolicySnapshotRouteInspection]?
}
