// Author: Timur Isaev

import AlloyTitleVolumes
import Darwin
import Foundation

enum ProbeError: Error { case assertion(String) }

struct FixtureState: Codable {
    let backupID: String
    let saveFingerprint: String
    let settingsFingerprint: String
}

final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(10)
    FileHandle.standardOutput.write(data)
}

func require(_ condition: Bool, _ reason: String) throws {
    guard condition else { throw ProbeError.assertion(reason) }
}

func identity(_ runtime: String) -> CacheIdentity {
    CacheIdentity(runtimeIdentity: runtime, providers: ["graphics": "provider-digest"],
                  compatibilityInputs: ["host": "host-epoch", "profile": "profile-digest"])
}

func makeFault(_ requested: String) -> VolumeFaultInjector {
    let parts = requested.split(separator: "@").map(String.init)
    let point = parts[0]
    let occurrence = parts.count == 2 ? Int(parts[1]) ?? 0 : 1
    let counter = HitCounter()
    return { reached in
        if reached == point, counter.increment() == occurrence {
            try output(["reached": requested])
            kill(getpid(), SIGKILL)
            throw ProbeError.assertion("SIGKILL did not terminate the probe")
        }
    }
}

func prepare(_ root: URL, _ store: TitleVolumeStore) throws {
    _ = try store.createTitle(gameID: "game")
    _ = try store.createTitle(gameID: "other")
    try store.write(gameID: "other", kind: .saves, path: "sentinel", data: Data("other title".utf8))
    for (name, size) in [("a", 32768), ("b", 65536)] {
        try store.write(gameID: "game", kind: .saves, path: "slot/" + name, data: Data(repeating: 1, count: size))
    }
    let backup = try store.createBackup(gameID: "game", now: 100, reason: "synthetic known answer")
    for (name, size) in [("a", 32768), ("b", 65536)] {
        try store.write(gameID: "game", kind: .saves, path: "slot/" + name, data: Data(repeating: 2, count: size))
    }
    let initial = try store.settingsStatus(gameID: "game")
    _ = try store.updateSettings(gameID: "game", update: SettingsUpdate(
        expectedFingerprint: initial.current.fingerprint, files: ["a": Data([3]), "b": Data([4])], now: 100))
    let cache = try store.activateCache(gameID: "game", identity: identity("runtime-one"))
    try store.write(gameID: "game", kind: .cache, generation: cache.volume.generation, path: "shader", data: Data([1]))
    _ = try store.createScratch(gameID: "game", sessionID: "session", now: 100, lifetimeSeconds: 10)
    try store.write(gameID: "game", kind: .scratch, generation: "session", path: "temp", data: Data([1]))
    let state = FixtureState(backupID: backup.id,
        saveFingerprint: try store.inventory(gameID: "game", kind: .saves).fingerprint,
        settingsFingerprint: try store.settingsStatus(gameID: "game").current.fingerprint)
    try JSONEncoder().encode(state).write(to: root.appendingPathComponent("fixture.json"))
    try output(["prepared": true])
}

func runOperation(_ operation: String, root: URL, store: TitleVolumeStore,
                  fault: @escaping VolumeFaultInjector) throws {
    let data = try Data(contentsOf: root.appendingPathComponent("fixture.json"))
    let fixture = try JSONDecoder().decode(FixtureState.self, from: data)
    switch operation {
    case "snapshot": _ = try store.snapshot(gameID: "game", now: 200, faultInjector: fault)
    case "backup": _ = try store.createBackup(gameID: "game", now: 200, reason: "proof", faultInjector: fault)
    case "restore":
        _ = try store.restore(gameID: "game", archiveID: fixture.backupID,
                             expectedFingerprint: fixture.saveFingerprint, now: 200, faultInjector: fault)
    case "settings":
        _ = try store.updateSettings(gameID: "game", update: SettingsUpdate(
            expectedFingerprint: fixture.settingsFingerprint, files: ["a": Data([5]), "b": Data([6])], now: 200),
            faultInjector: fault)
    case "cache": _ = try store.activateCache(gameID: "game", identity: identity("runtime-two"), faultInjector: fault)
    case "scratch": _ = try store.expireScratch(gameID: "game", now: 200, faultInjector: fault)
    default: throw ProbeError.assertion("unknown operation")
    }
    try output(["completed": operation])
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw ProbeError.assertion("missing command") }
    if command == "points" {
        var points = [String]()
        for operation in ["snapshot", "backup"] {
            points += TitleVolumeStore.snapshotFaultPoints.map { operation + "." + $0 }
            points.append(operation + ".after-clone-file@2")
        }
        points += TitleVolumeStore.restoreFaultPoints.map { "restore." + $0 }
        points += TitleVolumeStore.settingsFaultPoints.map { "settings." + $0 }
        points += TitleVolumeStore.cacheFaultPoints.map { "cache." + $0 }
        points += TitleVolumeStore.scratchFaultPoints.map { "scratch." + $0 }
        try output(points)
    } else {
        guard arguments.count >= 2 else { throw ProbeError.assertion("missing root") }
        let root = URL(fileURLWithPath: arguments[1])
        let store = try TitleVolumeStore(root: root)
        switch command {
        case "prepare": try prepare(root, store)
        case "run":
            guard arguments.count == 4 else { throw ProbeError.assertion("run needs operation and point") }
            try runOperation(arguments[2], root: root, store: store, fault: makeFault(arguments[3]))
        case "recover":
            for record in try store.records(gameID: "game") {
                _ = try store.inventory(gameID: "game", kind: record.kind, generation: record.generation)
            }
            _ = try store.archives(gameID: "game")
            _ = try store.settingsStatus(gameID: "game")
            _ = try store.activeCache(gameID: "game")
            try output(["recovered": true])
        case "lifecycle", "lifecycle-planted":
            try lifecycle(root, store: store, plant: command == "lifecycle-planted")
        case "hold":
            try store.withSessionLease(gameID: "game", sessionID: "session") { _ in
                try output(["lease": "held"])
                while true { pause() }
            }
        case "expire": try output(store.expireScratch(gameID: "game", now: 200))
        case "escape":
            try store.write(gameID: "game", kind: .saves, path: "../other/saves/sentinel", data: Data([0]))
        case "quota-prepare":
            _ = try store.createTitle(gameID: "game", quotas: VolumeQuotas(saves: 8))
            try store.write(gameID: "game", kind: .saves, path: "save", data: Data(repeating: 1, count: 8))
        case "quota-audit": _ = try store.inventory(gameID: "game", kind: .saves)
        default: throw ProbeError.assertion("unknown command")
        }
    }
} catch {
    FileHandle.standardError.write(Data("volume-proof: \(error)\n".utf8))
    exit(1)
}
