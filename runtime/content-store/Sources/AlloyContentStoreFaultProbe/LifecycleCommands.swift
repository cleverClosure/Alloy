// Author: Timur Isaev

import AlloyContentStore
import Darwin
import Foundation

private enum LifecycleProbeError: Error {
    case usage
    case verification
}

private func lifecycleProbeLayer(_ value: String = "known immutable runtime") -> LayerInput {
    let data = Data(value.utf8)
    return LayerInput(descriptor: LayerDescriptor(
        name: "runtime", version: "1", digest: ContentStore.digest(data),
        mediaType: "application/vnd.alloy.test-layer", size: data.count, role: .hostRuntime
    ), contents: data)
}

private func lifecycleProbeFault() -> FaultInjector {
    let point = ProcessInfo.processInfo.environment["ALLOY_FAULT_AFTER"]
    return { observed in
        if observed == point { _exit(97) }
    }
}

func runLifecycleCommand(_ arguments: [String]) throws -> Bool {
    guard let command = arguments.first, command.hasPrefix("lifecycle-") else { return false }
    guard arguments.count == 2 else { throw LifecycleProbeError.usage }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let store = try ContentStore(root: root, allowDamagedCatalog: command == "lifecycle-repair")
    switch command {
    case "lifecycle-bootstrap":
        try lifecycleBootstrap(store: store, root: root)
    case "lifecycle-corrupt":
        try lifecycleCorrupt(root: root)
    case "lifecycle-update":
        _ = try store.activate(
            gameID: "game", generationID: "c", layers: [lifecycleProbeLayer("upgrade")],
            operationID: "update-proof", faultInjector: lifecycleProbeFault()
        )
    case "lifecycle-repair":
        _ = try store.repairObjects(
            [lifecycleProbeLayer()], operationID: "repair-proof", faultInjector: lifecycleProbeFault()
        )
    case "lifecycle-uninstall":
        let expected = try JSONDecoder().decode(
            GenerationReferences.self, from: Data(contentsOf: root.appendingPathComponent("uninstall-plan.json"))
        )
        try store.uninstall(
            gameID: "game", expectedReferences: expected,
            operationID: "uninstall-proof", faultInjector: lifecycleProbeFault()
        )
    case "lifecycle-verify-repair", "lifecycle-verify-uninstall", "lifecycle-verify-update":
        try lifecycleVerify(store: store, command: command)
    default:
        throw LifecycleProbeError.usage
    }
    return true
}

private func lifecycleBootstrap(store: ContentStore, root: URL) throws {
    for generation in ["a", "b"] {
        _ = try store.activate(gameID: "game", generationID: generation, layers: [lifecycleProbeLayer()])
    }
    try store.writeSave(gameID: "game", name: "save", data: Data("save sentinel".utf8))
    try JSONEncoder().encode(store.referenceSnapshot(gameID: "game"))
        .write(to: root.appendingPathComponent("uninstall-plan.json"))
}

private func lifecycleCorrupt(root: URL) throws {
    let input = lifecycleProbeLayer()
    let digest = String(input.descriptor.digest.dropFirst("sha256:".count))
    let url = root.appendingPathComponent("objects/sha256/\(digest.prefix(2))/\(digest.dropFirst(2))")
    guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw LifecycleProbeError.verification }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var bytes = input.contents
    bytes[0] ^= 1
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
}

private func lifecycleVerify(store: ContentStore, command: String) throws {
    if command == "lifecycle-verify-update" {
        _ = try store.activate(
            gameID: "game", generationID: "c", layers: [lifecycleProbeLayer("upgrade")],
            operationID: "update-proof"
        )
    }
    let inspection = try store.inspect(gameID: "game")
    if command == "lifecycle-verify-uninstall" {
        guard inspection.active == nil, inspection.rollback == nil, inspection.candidate == nil,
              try store.collectGarbage().objectsRemoved == 1 else { throw LifecycleProbeError.verification }
    } else {
        let active = command == "lifecycle-verify-update" ? "c" : "b"
        let rollback = command == "lifecycle-verify-update" ? "b" : "a"
        guard inspection.active?.generationID == active, inspection.rollback?.generationID == rollback else {
            throw LifecycleProbeError.verification
        }
        if let active = inspection.active { try store.validateReference(active, gameID: "game") }
        if let rollback = inspection.rollback { try store.validateReference(rollback, gameID: "game") }
    }
    guard try store.readSave(gameID: "game", name: "save") == Data("save sentinel".utf8),
          try store.catalogConsistencyReport().isConsistent else { throw LifecycleProbeError.verification }
}
