// Author: Timur Isaev
import AlloyContentStore
import Foundation

public struct InstallPlan: Codable, Equatable, Sendable {
    public let planID: String
    public let gameID: String
    public let installationID: String
    public let generationID: String
    public let layers: [LayerDescriptor]
    public let baseURLs: [URL]
    public let requiredObjectBytes: UInt64
}

public struct UninstallPlan: Codable, Equatable, Sendable {
    public let planID: String
    public let gameID: String
    public let installationID: String
    public let expectedReferences: GenerationReferences
}

struct InstallRequest: Codable, Equatable {
    let gameID: String
    let installationID: String
    let generationID: String
    let layers: [LayerDescriptor]
    let baseURLs: [URL]
}

struct UninstallRequest: Codable, Equatable {
    let gameID: String
    let installationID: String
    let expectedReferences: GenerationReferences
}

public enum InstallationError: Error, Equatable {
    case invalidIdentifier(String)
    case unknownPlan(String)
    case corruptPlan(String)
    case noInstalledPlan(String)
    case unexpectedGeneration
    case unknownKind
}
