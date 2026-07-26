// Author: Timur Isaev

import Foundation

public struct LeaseProcessIdentity: Codable, Equatable, Sendable {
    public let processID: Int32
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt32

    public init(
        processID: Int32,
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt32
    ) {
        self.processID = processID
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }

    enum CodingKeys: String, CodingKey {
        case processID = "processId"
        case startTimeSeconds
        case startTimeMicroseconds
    }
}

public struct GenerationLease: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "1.0"

    public let schemaVersion: String
    public let leaseID: String
    public let gameID: String
    public let generationID: String
    public let manifestDigest: String
    public let objectDigests: [String]
    public let holder: LeaseProcessIdentity
    public let createdAtUnixSeconds: Int64

    init(
        leaseID: String,
        gameID: String,
        generation: GenerationReference,
        objectDigests: [String],
        holder: LeaseProcessIdentity,
        createdAtUnixSeconds: Int64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.leaseID = leaseID
        self.gameID = gameID
        generationID = generation.generationID
        manifestDigest = generation.manifestDigest
        self.objectDigests = objectDigests
        self.holder = holder
        self.createdAtUnixSeconds = createdAtUnixSeconds
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case leaseID = "leaseId"
        case gameID = "gameId"
        case generationID = "generationId"
        case manifestDigest
        case objectDigests
        case holder
        case createdAtUnixSeconds
    }
}
