// Author: Timur Isaev

import AlloyTitleVolumes
import Foundation

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
        throw VolumeError.integrityMismatch
    }
    print(text)
}

struct AuditReport: Encodable {
    let volume: VolumeRecord
    let inventory: TreeInventory
    let fingerprint: String
}

struct SettingsReport: Encodable {
    let status: SettingsStatus
    let fingerprint: String
}

func boundedInput(_ path: String, limit: Int) throws -> Data {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw VolumeError.quotaExceeded }
    return data
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 3 else { throw VolumeError.invalidPolicy }
    let command = arguments[0]
    let store = try TitleVolumeStore(root: URL(fileURLWithPath: arguments[1]))
    let gameID = arguments[2]
    switch command {
    case "init":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        try emit(store.createTitle(gameID: gameID))
    case "list":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        try emit(store.records(gameID: gameID))
    case "adopt-legacy-saves":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        try emit(store.adoptLegacySaves(gameID: gameID))
    case "audit":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        for record in try store.records(gameID: gameID) {
            let inventory = try store.inventory(gameID: gameID, kind: record.kind, generation: record.generation)
            try emit(AuditReport(volume: record, inventory: inventory, fingerprint: inventory.fingerprint))
        }
    case "scratch-create":
        guard arguments.count == 5, let now = Int64(arguments[4]) else { throw VolumeError.invalidPolicy }
        try emit(store.createScratch(gameID: gameID, sessionID: arguments[3], now: now))
    case "scratch-expire":
        guard arguments.count == 4, let now = Int64(arguments[3]) else { throw VolumeError.invalidPolicy }
        try emit(store.expireScratch(gameID: gameID, now: now))
    case "snapshot", "snapshot-if-due":
        guard arguments.count == 4, let now = Int64(arguments[3]) else { throw VolumeError.invalidPolicy }
        if command == "snapshot" { try emit(store.snapshot(gameID: gameID, now: now)) } else {
            try emit(store.snapshotIfDue(gameID: gameID, now: now))
        }
    case "backup-create":
        guard arguments.count == 5, let now = Int64(arguments[3]) else { throw VolumeError.invalidPolicy }
        try emit(store.createBackup(gameID: gameID, now: now, reason: arguments[4]))
    case "backup-list":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        try emit(store.archives(gameID: gameID))
    case "backup-delete":
        guard arguments.count == 4 else { throw VolumeError.invalidPolicy }
        try store.deleteArchive(gameID: gameID, archiveID: arguments[3])
    case "backup-restore":
        guard arguments.count == 6, let now = Int64(arguments[5]) else { throw VolumeError.invalidPolicy }
        try emit(store.restore(gameID: gameID, archiveID: arguments[3],
                               expectedFingerprint: arguments[4], now: now))
    case "settings-status":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        let status = try store.settingsStatus(gameID: gameID)
        try emit(SettingsReport(status: status, fingerprint: status.current.fingerprint))
    case "settings-reset", "settings-update":
        let expectedCount = command == "settings-reset" ? 5 : 6
        guard arguments.count == expectedCount, let now = Int64(arguments[4]) else {
            throw VolumeError.invalidPolicy
        }
        let files: [String: Data]
        if command == "settings-reset" { files = [:] } else {
            let data = try boundedInput(arguments[5], limit: 64 << 20)
            files = try JSONDecoder().decode([String: Data].self, from: data)
        }
        try emit(store.updateSettings(gameID: gameID, update: SettingsUpdate(
            expectedFingerprint: arguments[3], files: files, now: now)))
    case "cache-status":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        try emit(store.activeCache(gameID: gameID))
    case "cache-activate":
        guard arguments.count == 4 else { throw VolumeError.invalidPolicy }
        let data = try boundedInput(arguments[3], limit: 1 << 20)
        try emit(store.activateCache(gameID: gameID, identity: JSONDecoder().decode(CacheIdentity.self, from: data)))
    default: throw VolumeError.invalidPolicy
    }
} catch {
    FileHandle.standardError.write(Data("alloy-volumes: \(error)\n".utf8))
    exit(1)
}
