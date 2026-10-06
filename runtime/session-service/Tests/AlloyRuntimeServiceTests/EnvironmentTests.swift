// Author: Timur Isaev

import AlloyRuntimeAPI
import AlloyTitleVolumes
import Darwin
import Foundation
import Testing
@testable import AlloyRuntimeService

private func environmentRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("alloy-environment-" + UUID().uuidString)
    try privateDirectory(root)
    return root
}

@Test func prefixCopiesAreDeterministicIsolatedAndScrubbed() throws {
    let root = try environmentRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = root.appendingPathComponent("content")
    let state = root.appendingPathComponent("state")
    let runtime = root.appendingPathComponent("runtime")
    let payload = root.appendingPathComponent("payload")
    for url in [content, state, runtime, payload] { try privateDirectory(url) }
    let volumes = try TitleVolumeStore(root: content)
    _ = try volumes.createTitle(gameID: "game")
    let identity = CacheIdentity(runtimeIdentity: "generation", providers: ["graphics": "marker"],
                                 compatibilityInputs: ["test": "one"])
    _ = try volumes.activateCache(gameID: "game", identity: identity)
    _ = try volumes.createScratch(gameID: "game", sessionID: "session", now: 1)
    let plan = try volumes.drivePlan(SessionVolumeRequest(gameID: "game", sessionID: "session",
                                                          runtimeVolumeID: "runtime", payloadVolumeID: "payload"),
                                    expectedCacheIdentity: identity, now: 1)
    let builder = try SessionEnvironment(stateRoot: state, contentRoot: content)
    var boots = 0
    func prepare(_ name: String) throws -> PreparedSessionEnvironment {
        try builder.prepare(SessionEnvironmentInput(runtime: runtime, generation: "generation", runtimeDigest: "digest",
                                                     plan: plan, payload: payload),
                            sessionRoot: root.appendingPathComponent(name)) { prefix in
            boots += 1
            try privateDirectory(prefix.appendingPathComponent("drive_c/users/test"))
            try Data("unchanged registry".utf8).write(to: prefix.appendingPathComponent("state.bin"))
            try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("drive_c/inside"),
                                                       withDestinationURL: prefix.appendingPathComponent("state.bin"))
            let desktop = prefix.appendingPathComponent("drive_c/users/test/Desktop")
            try FileManager.default.createSymbolicLink(at: desktop,
                withDestinationURL: FileManager.default.homeDirectoryForCurrentUser)
            try privateDirectory(prefix.appendingPathComponent("dosdevices"))
            try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path,
                                                       withDestinationPath: "/")
        }
    }
    let first = try prepare("one")
    let second = try prepare("two")
    #expect(boots == 1)
    try verifyCopies(first, second, volumes: volumes)
    _ = try prepare("three")
    #expect(boots == 1)
}

private func verifyCopies(_ first: PreparedSessionEnvironment, _ second: PreparedSessionEnvironment,
                          volumes: TitleVolumeStore) throws {
    #expect(first.prefix != second.prefix)
    #expect(first.templateDigest == second.templateDigest)
    #expect(first.prefixDigest == second.prefixDigest)
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: first.prefix.appendingPathComponent("drive_c/inside").path) == "../state.bin")
    #expect(try FileManager.default.contentsOfDirectory(atPath: first.prefix.appendingPathComponent("dosdevices").path)
        .sorted() == ["c:", "g:", "s:", "t:"])
    #expect(first.environment["DYLD_INSERT_LIBRARIES"] == nil)
    #expect(first.environment["ALLOY_POLICY_SNAPSHOT_FD"] == nil)
    #expect(first.environment["HOME"] == first.prefix.path)
    #expect(first.environment["WINEPREFIX"] != second.environment["WINEPREFIX"])
    #expect(try FileManager.default.contentsOfDirectory(
        atPath: first.prefix.appendingPathComponent("drive_c/users/test/Desktop").path).isEmpty)
    try Data("changed".utf8).write(to: first.prefix.appendingPathComponent("state.bin"))
    #expect(try String(contentsOf: second.prefix.appendingPathComponent("state.bin"), encoding: .utf8)
        == "unchanged registry")
    let save = first.prefix.appendingPathComponent("dosdevices/s:/saves/save.dat")
    try Data("persistent".utf8).write(to: save)
    #expect(chmod(save.path, 0o600) == 0)
    #expect(try volumes.read(gameID: "game", kind: .saves, path: "save.dat") == Data("persistent".utf8))
}

@Test func modifiedTemplatesAndAliasedCacheRootsReject() throws {
    let root = try environmentRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try PrefixTemplate(root: root.appendingPathComponent("cache"))
    let bootstrap: (URL) throws -> Void = {
        try Data("original".utf8).write(to: $0.appendingPathComponent("state.bin"))
    }
    _ = try cache.copy(generation: "one", runtimeDigest: "hash", runtime: root,
                       destination: root.appendingPathComponent("first"), bootstrap: bootstrap)
    let template = try #require(FileManager.default.contentsOfDirectory(at: cache.root,
        includingPropertiesForKeys: nil).first { $0.lastPathComponent.count == 64 })
    try Data("tampered".utf8).write(to: template.appendingPathComponent("state.bin"))
    #expect(throws: RuntimeFailure.status(.conflict)) {
        try cache.copy(generation: "one", runtimeDigest: "hash", runtime: root,
                       destination: root.appendingPathComponent("second"), bootstrap: bootstrap)
    }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cache.root)
    #expect(throws: RuntimeFailure.status(.malformed)) { try PrefixTemplate(root: alias) }
}

@Test func freshRegistryMetadataIsDeterministicAndUnsettledUpdatesReject() throws {
    let first = try environmentRoot(), second = try environmentRoot()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    for (index, root) in [first, second].enumerated() {
        let text = """
        WINE REGISTRY Version 2
        #arch=win64
        [Software\\\\Microsoft\\\\Cryptography] \(index + 1000)
        #time=\(index + 100)
        "MachineGuid"="\(UUID().uuidString.lowercased())"

        """
        try Data(text.utf8).write(to: root.appendingPathComponent("system.reg"))
        try PrefixNormalization.apply(root, seed: "runtime-one")
    }
    let normalized = try Data(contentsOf: first.appendingPathComponent("system.reg"))
    #expect(try Data(contentsOf: second.appendingPathComponent("system.reg")) == normalized)
    try PrefixNormalization.apply(second, seed: "runtime-two")
    #expect(try Data(contentsOf: second.appendingPathComponent("system.reg")) != normalized)
    try (normalized + Data("\"PendingFileRenameOperations\"=str(7):\"pending\"\n".utf8))
        .write(to: first.appendingPathComponent("system.reg"))
    #expect(throws: RuntimeFailure.status(.conflict)) { try PrefixNormalization.apply(first, seed: "runtime-one") }
}
