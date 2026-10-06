// Author: Timur Isaev

import AlloyContentStore
import AlloyTitleVolumes
import Foundation

func layer(_ version: String) -> LayerInput {
    let data = Data("synthetic layer \(version)".utf8)
    return LayerInput(descriptor: LayerDescriptor(name: "runtime", version: version,
        digest: ContentStore.digest(data), mediaType: "application/vnd.alloy.test-layer", size: data.count,
        role: .hostRuntime, sourceRevision: version, licenseID: "LicenseRef-Test"), contents: data)
}

func lifecycle(_ root: URL, store: TitleVolumeStore, plant: Bool) throws {
    let saves = try store.inventory(gameID: "game", kind: .saves)
    let other = try store.inventory(gameID: "other", kind: .saves)
    let runtime = try ContentStore(root: root)
    let legacyBytes = Data("legacy content-store save".utf8)
    try runtime.writeSave(gameID: "legacy", name: "legacy.sav", data: legacyBytes)
    _ = try store.adoptLegacySaves(gameID: "legacy")
    try require(try store.read(gameID: "legacy", kind: .saves, path: "legacy.sav") == legacyBytes,
                "legacy adoption changed saves")
    func unchanged() throws {
        try require(try store.inventory(gameID: "game", kind: .saves) == saves, "save mutation detected")
        try require(try store.inventory(gameID: "other", kind: .saves) == other, "other-title save mutation detected")
    }
    _ = try runtime.activate(gameID: "game", generationID: "generation-a", layers: [layer("a")])
    try require(try runtime.inspect(gameID: "game").active?.generationID == "generation-a", "first activation absent")
    try unchanged()
    _ = try runtime.activate(gameID: "game", generationID: "generation-b", layers: [layer("b")])
    try require(try runtime.inspect(gameID: "game").active?.generationID == "generation-b", "update absent")
    try unchanged()
    _ = try runtime.activate(gameID: "game", generationID: "generation-c", layers: [layer("c")], healthOutcome: .fail)
    try require(try runtime.inspect(gameID: "game").active?.generationID == "generation-b", "rollback absent")
    try unchanged()
    let collected = try runtime.collectGarbage()
    try require(collected.generationsRemoved > 0 && collected.objectsRemoved > 0, "GC was a no-op")
    try unchanged()
    let references = try runtime.referenceSnapshot(gameID: "game")
    _ = try runtime.uninstall(gameID: "game", expectedReferences: references, operationID: "proof-uninstall")
    try require(try runtime.inspect(gameID: "game").active == nil, "uninstall retained active reference")
    try unchanged()
    _ = try runtime.collectGarbage()
    try runtime.recoverAll()
    if plant { try runtime.writeSave(gameID: "game", name: "planted-torn-save", data: Data([0])) }
    try unchanged()
    try output(["activation": true, "healthRollback": true, "nonemptyGC": true, "legacyAdoption": true,
                "uninstall": true, "restartRecovery": true, "savesUnchanged": true])
}
