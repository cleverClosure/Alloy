// Author: Timur Isaev

import Foundation

struct PolicySource: Codable {
    let schemaVersion: Int
    let defaultPolicy: PolicyDefinition
    let processPolicies: [ProcessPolicyDefinition]
}

struct ProcessPolicyDefinition: Codable {
    let imageSHA256: String
    let policy: PolicyDefinition
}

struct PolicyDefinition: Codable {
    let id: String
    let graphicsProvider: String
    let providerDirectory: String
    let dllRoutes: [DLLRouteDefinition]
}

struct DLLRouteDefinition: Codable {
    let module: String
    let loadOrder: LoadOrder
}

enum LoadOrder: String, Codable {
    case disabled
    case native
    case builtin
    case nativeBuiltin = "native,builtin"
    case builtinNative = "builtin,native"

    var binaryValue: UInt32 {
        switch self {
        case .disabled: 1
        case .native: 2
        case .builtin: 3
        case .nativeBuiltin: 4
        case .builtinNative: 5
        }
    }
}

struct NormalizedPolicySource: Codable, Equatable {
    let schemaVersion: Int
    let defaultPolicy: NormalizedPolicy
    let processPolicies: [NormalizedProcessPolicy]
}

struct NormalizedProcessPolicy: Codable, Equatable {
    let imageSHA256: String
    let policy: NormalizedPolicy
}

struct NormalizedPolicy: Codable, Equatable {
    let id: String
    let graphicsProvider: String
    let providerDirectory: String
    let dllRoutes: [NormalizedDLLRoute]
}

struct NormalizedDLLRoute: Codable, Equatable {
    let module: String
    let loadOrder: LoadOrder
}

public struct PolicySnapshotInspection: Codable, Equatable, Sendable {
    public let version: Int
    public let sourceDigest: String
    public let entries: [PolicySnapshotEntryInspection]
}

public struct PolicySnapshotEntryInspection: Codable, Equatable, Sendable {
    public let imageSHA256: String?
    public let policyID: String
    public let graphicsProvider: String
    public let providerDirectory: String
    public let defaultPolicy: Bool
    public let dllRoutes: [PolicySnapshotRouteInspection]
}

public struct PolicySnapshotRouteInspection: Codable, Equatable, Sendable {
    public let module: String
    public let loadOrder: String
}
