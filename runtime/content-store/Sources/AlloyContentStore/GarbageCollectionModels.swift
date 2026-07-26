// Author: Timur Isaev

import Foundation

public struct GarbageCollectionResult: Codable, Equatable, Sendable {
    public let generationsRemoved: Int
    public let objectsRemoved: Int
    public let downloadsRemoved: Int
    public let quarantineEntriesRemoved: Int
    public let bytesReclaimed: UInt64

    public init(
        generationsRemoved: Int,
        objectsRemoved: Int,
        downloadsRemoved: Int,
        quarantineEntriesRemoved: Int,
        bytesReclaimed: UInt64
    ) {
        self.generationsRemoved = generationsRemoved
        self.objectsRemoved = objectsRemoved
        self.downloadsRemoved = downloadsRemoved
        self.quarantineEntriesRemoved = quarantineEntriesRemoved
        self.bytesReclaimed = bytesReclaimed
    }

    public static let zero = GarbageCollectionResult(
        generationsRemoved: 0,
        objectsRemoved: 0,
        downloadsRemoved: 0,
        quarantineEntriesRemoved: 0,
        bytesReclaimed: 0
    )
}

struct RootedGeneration: Hashable {
    let gameID: String
    let generationID: String
}

struct GarbageCollectionMark {
    let generations: Set<RootedGeneration>
    let objectDigests: Set<String>
}
