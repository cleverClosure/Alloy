// Author: Timur Isaev

import Foundation

public struct SettingsVersion: Codable, Equatable, Sendable {
    public let gameID: String
    public let revision: Int64
    public let createdAt: Int64
    public let inventory: TreeInventory
    public let previousArchiveID: String
}

public struct SettingsStatus: Codable, Equatable, Sendable {
    public let version: SettingsVersion?
    public let current: TreeInventory
    public var changedOutsideLibrary: Bool { version.map { $0.inventory != current } ?? !current.entries.isEmpty }
}

public struct SettingsUpdate: Sendable {
    public let expectedFingerprint: String
    public let files: [String: Data]
    public let now: Int64
    public init(expectedFingerprint: String, files: [String: Data], now: Int64) {
        self.expectedFingerprint = expectedFingerprint
        self.files = files
        self.now = now
    }
}

extension TitleVolumeStore {
    public static let settingsFaultPoints = ["after-preserve", "after-stage", "after-journal",
                                            "after-swap", "after-sync", "after-metadata", "after-commit"]

    public func settingsStatus(gameID: String) throws -> SettingsStatus {
        try locked {
            let volume = try resolve(gameID, .settings, nil, in: loadRegistry())
            return SettingsStatus(version: try settingsVersion(gameID),
                                  current: try directory(volume).inventory(limit: volume.quota))
        }
    }

    public func settingsHistory(gameID: String) throws -> [SettingsVersion] {
        try locked {
            _ = try titleRecord(gameID, in: loadRegistry())
            let history = try metadata.child("settings-history", create: true).child(gameID, create: true)
            return try history.names().map {
                let value = try decodeChecked(SettingsVersion.self, history.read($0))
                guard value.gameID == gameID, "\(value.revision).json" == $0 else {
                    throw VolumeError.integrityMismatch
                }
                return value
            }.sorted { $0.revision < $1.revision }
        }
    }

    /// Replaces the complete settings tree, including an explicit reset represented by an empty files map.
    public func updateSettings(gameID: String, update: SettingsUpdate,
                               faultInjector: VolumeFaultInjector? = nil) throws -> SettingsVersion {
        guard update.now >= 0, update.files.count <= 10_000 else { throw VolumeError.invalidPolicy }
        return try locked {
            try quiet(gameID) {
                let volume = try resolve(gameID, .settings, nil, in: loadRegistry())
                let current = try directory(volume).inventory(limit: volume.quota)
                guard try current.fingerprint == update.expectedFingerprint else { throw VolumeError.conflict }
                let previousVersion = try settingsVersion(gameID)
                guard (previousVersion?.revision ?? 0) < Int64.max,
                      update.now >= (previousVersion?.createdAt ?? 0) else { throw VolumeError.invalidPolicy }
                let previous = try capture(gameID, request: CaptureRequest(
                    volumeKind: .settings, kind: .settings, now: update.now,
                    reason: update.files.isEmpty ? "before explicit reset" : "before settings update",
                    operation: "preserve-settings"), fault: nil)
                try faultInjector?("settings.after-preserve")
                let stage = try stageSettings(update.files, quota: volume.quota)
                let next = SettingsVersion(gameID: gameID, revision: (previousVersion?.revision ?? 0) + 1,
                                           createdAt: update.now, inventory: try stage.inventory(limit: volume.quota),
                                           previousArchiveID: previous.id)
                try replace(gameID, source: stage, request: ReplacementRequest(
                    kind: .settings, before: previous, after: next.inventory,
                    operation: "settings", settingsVersion: next), fault: faultInjector)
                return next
            }
        }
    }

    private func stageSettings(_ files: [String: Data], quota: Int64) throws -> Directory {
        let stage = try metadata.child("staging", create: true).child(UUID().uuidString.lowercased(), create: true)
        var remaining = quota
        for path in files.keys.sorted() {
            guard let data = files[path], Int64(data.count) <= remaining else { throw VolumeError.quotaExceeded }
            remaining -= Int64(data.count)
            let components = try relativeComponents(path)
            var parent = stage
            for component in components.dropLast() { parent = try parent.child(component, create: true) }
            try parent.write(components[components.count - 1], data: data, exclusive: true)
        }
        return stage
    }

    func settingsVersion(_ gameID: String) throws -> SettingsVersion? {
        guard try metadata.information("settings-current") != nil else { return nil }
        let directory = try metadata.child("settings-current")
        guard try directory.information(gameID + ".json") != nil else { return nil }
        let value = try decodeChecked(SettingsVersion.self, directory.read(gameID + ".json"))
        guard value.gameID == gameID, value.revision > 0 else { throw VolumeError.integrityMismatch }
        return value
    }

    func publishSettings(_ value: SettingsVersion) throws {
        try identifier(value.gameID)
        guard value.revision > 0, value.createdAt >= 0 else { throw VolumeError.integrityMismatch }
        let history = try metadata.child("settings-history", create: true).child(value.gameID, create: true)
        let name = "\(value.revision).json"
        if try history.information(name) != nil {
            guard try decodeChecked(SettingsVersion.self, history.read(name)) == value else {
                throw VolumeError.integrityMismatch
            }
        } else { try history.write(name, data: checked(value), exclusive: true) }
        try metadata.child("settings-current", create: true).write(value.gameID + ".json", data: checked(value))
    }
}
