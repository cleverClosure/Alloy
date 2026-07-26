// Author: Timur Isaev

import AlloyContentStore
import Foundation

enum HarnessError: Error, CustomStringConvertible {
    case invariant(String)
    case usage

    var description: String {
        switch self {
        case let .invariant(message):
            "stress invariant failed: \(message)"
        case .usage:
            """
            usage:
              alloy-content-store-stress-harness run ROOT SEED STEPS
              alloy-content-store-stress-harness child-activate ROOT GAME GEN PAYLOAD pass|fail FAULT|none
              alloy-content-store-stress-harness child-collect ROOT FAULT|none
            """
        }
    }
}

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

enum StressOperation: String, CaseIterable {
    case publish
    case activate
    case rollback
    case lease
    case release
    case sweep
}

let stressCollectionFaultPoints = ContentStore.garbageCollectionFaultPoints.filter {
    !$0.hasSuffix("-item")
}

struct StressModel {
    var active: String
    var rollback: String
    var materialized: [String: String]
    var leases: [GenerationLease]

    var reachableGenerations: Set<String> {
        var result: Set<String> = [active, rollback]
        result.formUnion(leases.map(\.generationID))
        return result
    }

    var reachableDigests: Set<String> {
        Set(reachableGenerations.compactMap { generationID in
            materialized[generationID].map { ContentStore.digest(Data($0.utf8)) }
        })
    }
}

struct StressStepResult {
    let detail: String
    let fault: String
    let completedSweep: Bool
}

struct StressRunContext {
    let root: URL
    let store: ContentStore
    let seed: UInt64
}

struct StressOperationRequest {
    let operation: StressOperation
    let step: Int
    let forceFault: Bool
}

struct StressActivationRequest {
    let generationID: String
    let payload: String
    let healthOutcome: HealthOutcome
}

func layer(generationID: String, payload: String) -> LayerInput {
    let data = Data(payload.utf8)
    return LayerInput(
        descriptor: LayerDescriptor(
            name: "stress-runtime",
            version: generationID,
            digest: ContentStore.digest(data),
            mediaType: "application/vnd.alloy.test-layer",
            size: data.count,
            role: .hostRuntime,
            sourceRevision: generationID
        ),
        contents: data
    )
}

func verifyModel(
    store: ContentStore,
    root: URL,
    model: StressModel,
    requireExactReachability: Bool
) throws {
    try verifyReferencesAndSave(store: store, model: model)
    if requireExactReachability {
        try verifyExactReachability(root: root, model: model)
    }
}

private func verifyReferencesAndSave(
    store: ContentStore,
    model: StressModel
) throws {
    let inspection = try store.inspect(gameID: "stress-game")
    guard inspection.active?.generationID == model.active else {
        throw HarnessError.invariant(
            "active \(inspection.active?.generationID ?? "none"), model \(model.active)"
        )
    }
    guard inspection.rollback?.generationID == model.rollback else {
        throw HarnessError.invariant(
            "rollback \(inspection.rollback?.generationID ?? "none"), model \(model.rollback)"
        )
    }
    guard inspection.candidate == nil else {
        throw HarnessError.invariant("candidate survived recovery")
    }
    guard inspection.incompleteOperationCount == 0 else {
        throw HarnessError.invariant(
            "\(inspection.incompleteOperationCount) incomplete journal(s)"
        )
    }
    guard try store.readSave(
        gameID: "stress-game",
        name: "save.bin"
    ) == Data("save-sentinel".utf8) else {
        throw HarnessError.invariant("save sentinel changed")
    }
    if let active = inspection.active {
        try store.validateReference(active, gameID: "stress-game")
    }
    if let rollback = inspection.rollback {
        try store.validateReference(rollback, gameID: "stress-game")
    }
    for lease in model.leases {
        try store.validateReference(
            GenerationReference(
                generationID: lease.generationID,
                manifestDigest: lease.manifestDigest
            ),
            gameID: lease.gameID
        )
    }
}

private func verifyExactReachability(
    root: URL,
    model: StressModel
) throws {
    let onDiskGenerations = try generationIDs(root: root, gameID: "stress-game")
    guard onDiskGenerations == model.reachableGenerations else {
        throw HarnessError.invariant(
            "generation reachability disk=\(onDiskGenerations.sorted()) "
                + "model=\(model.reachableGenerations.sorted())"
        )
    }
    let onDiskObjects = try objectDigests(root: root)
    guard onDiskObjects == model.reachableDigests else {
        throw HarnessError.invariant(
            "object reachability disk=\(onDiskObjects.sorted()) "
                + "model=\(model.reachableDigests.sorted())"
        )
    }
}

private func generationIDs(root: URL, gameID: String) throws -> Set<String> {
    let directory = root
        .appendingPathComponent("generations", isDirectory: true)
        .appendingPathComponent(gameID, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return []
    }
    return Set(try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey]
    ).map(\.lastPathComponent))
}

private func objectDigests(root: URL) throws -> Set<String> {
    let directory = root.appendingPathComponent("objects/sha256", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        return []
    }
    var result: Set<String> = []
    while let url = enumerator.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            continue
        }
        result.insert(
            "sha256:\(url.deletingLastPathComponent().lastPathComponent)\(url.lastPathComponent)"
        )
    }
    return result
}
