// Author: Timur Isaev
import AlloyStoreCatalog
import Foundation
import Testing

func scratchDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func treeBytes(_ root: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let file = entries?.nextObject() as? URL {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
        }
    }
    return result
}

@Test func exhaustiveTransitionGraph() throws {
    let edges: [OperationState: Set<OperationState>] = [
        .queued: [.running], .running: [.paused, .succeeded, .failed, .cancelling],
        .paused: [.running, .cancelling], .cancelling: [.cancelled]
    ]
    for source in OperationState.allCases {
        for destination in OperationState.allCases {
            #expect(source.allows(destination) == (edges[source]?.contains(destination) ?? false))
        }
    }
}

@Test func idempotencyReplayAndImmutableTerminal() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try OperationJournal(root: root)
    let operation = try journal.create(kind: .install, idempotencyKey: "key", payload: ["a": 1, "b": 2])
    let before = try treeBytes(root)
    #expect(try journal.create(kind: .install, idempotencyKey: "key", payload: ["b": 2, "a": 1]) == operation)
    #expect(try treeBytes(root) == before)
    #expect(throws: OperationError.idempotencyConflict) {
        try journal.create(kind: .install, idempotencyKey: "key", payload: ["a": 2])
    }
    #expect(throws: OperationError.invalidTransition(.queued, .succeeded)) {
        try journal.transition(operation.operationID, to: .succeeded, stage: "DONE")
    }
    _ = try journal.transition(operation.operationID, to: .running, stage: "FETCHING")
    _ = try journal.transition(operation.operationID, to: .paused, stage: "PAUSED")
    _ = try journal.transition(operation.operationID, to: .running, stage: "FETCHING")
    let finished = try journal.transition(operation.operationID, to: .succeeded, stage: "DONE", result: Data("ok".utf8))
    #expect(throws: OperationError.immutableTerminal) {
        try journal.transition(operation.operationID, to: .running, stage: "FETCHING")
    }
    let terminalBytes = try treeBytes(root)
    #expect(try journal.create(kind: .install, idempotencyKey: "key", payload: ["a": 1, "b": 2]) == finished)
    #expect(try treeBytes(root) == terminalBytes)
    let retry = try journal.create(kind: .install, idempotencyKey: "retry", payload: ["a": 1, "b": 2],
                                   previousAttemptID: operation.operationID)
    #expect(retry.previousAttemptID == operation.operationID)
    #expect(retry.operationID != operation.operationID)
}

@Test func everyJournalWritePointSurvivesProcessDeath() throws {
    for stage in ["QUEUED", "RUNNING"] {
        for point in OperationJournal.writePoints {
            let root = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            if stage == "RUNNING" { #expect(try runJournalProbe(root, action: "seed") == 0) }
            let status = try runJournalProbe(
                root, action: stage == "QUEUED" ? "seed" : "run", fault: stage + "." + point)
            #expect(status == 9)
            let journal = try OperationJournal(root: root)
            let recovered = try journal.create(kind: .install, idempotencyKey: "probe", payload: ["fixture": "known"])
            #expect([OperationState.queued, .running].contains(recovered.state))
            #expect(try journal.list().count == 1)
            if recovered.state == .queued {
                _ = try journal.transition(recovered.operationID, to: .running, stage: "RUNNING")
            }
            _ = try journal.transition(recovered.operationID, to: .succeeded, stage: "DONE")
            #expect(try journal.get(recovered.operationID).state == .succeeded)
        }
    }
}

private func runJournalProbe(_ root: URL, action: String, fault: String? = nil) throws -> Int32 {
    let child = Process()
    child.executableURL = packageRoot.appendingPathComponent(".build/debug/alloy-store-catalog")
    child.arguments = ["journal-probe", root.path, action]
    child.standardOutput = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "ALLOY_CATALOG_FAULT")
    environment["ALLOY_CATALOG_FAULT"] = fault
    child.environment = environment
    try child.run()
    child.waitUntilExit()
    return child.terminationStatus
}

@Test func journalEnforcesEveryTransitionAndRejectsCorruption() throws {
    let routes: [OperationState: [OperationState]] = [
        .queued: [], .running: [.running], .paused: [.running, .paused],
        .succeeded: [.running, .succeeded], .failed: [.running, .failed],
        .cancelling: [.running, .cancelling], .cancelled: [.running, .cancelling, .cancelled]
    ]
    for source in OperationState.allCases {
        for destination in OperationState.allCases {
            let root = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let journal = try OperationJournal(root: root)
            let operation = try journal.create(kind: .install, idempotencyKey: "graph", payload: "fixture")
            for state in routes[source] ?? [] {
                _ = try journal.transition(operation.operationID, to: state, stage: state.rawValue)
            }
            let before = try treeBytes(root)
            if source.allows(destination) {
                #expect(try journal.transition(operation.operationID, to: destination,
                                               stage: destination.rawValue).state == destination)
            } else {
                #expect(throws: OperationError.self) {
                    try journal.transition(operation.operationID, to: destination, stage: destination.rawValue)
                }
                #expect(try treeBytes(root) == before)
            }
        }
    }
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try OperationJournal(root: root)
    let operation = try journal.create(kind: .install, idempotencyKey: "corrupt", payload: "fixture")
    let path = root.appendingPathComponent(operation.operationID + ".json")
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    object["payloadDigest"] = String(repeating: "0", count: 64)
    try JSONSerialization.data(withJSONObject: object).write(to: path)
    #expect(throws: OperationError.corruptJournal(operation.operationID)) { try journal.get(operation.operationID) }
}
