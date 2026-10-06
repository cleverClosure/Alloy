// Author: Timur Isaev

import Darwin
import Foundation

public typealias VolumeFaultInjector = @Sendable (String) throws -> Void

public enum ArchiveKind: String, Codable, Sendable {
    case snapshot, backup, conflict, beforeRestore, settings
}

public struct ArchiveRecord: Codable, Equatable, Sendable {
    public let id: String
    public let gameID: String
    public let volumeKind: VolumeKind
    public let kind: ArchiveKind
    public let createdAt: Int64
    public let reason: String
    public let inventory: TreeInventory
    public let clonedFiles: Int
    public let copiedFiles: Int
}

public enum RestoreOutcome: Codable, Equatable, Sendable {
    case restored(previousArchiveID: String)
    case conflict(localArchiveID: String, incomingArchiveID: String)
}

struct CaptureRequest {
    let volumeKind: VolumeKind
    let kind: ArchiveKind
    let now: Int64
    let reason: String
    let operation: String
}

extension TitleVolumeStore {
    public static let snapshotFaultPoints = ["after-stage", "after-clone-file", "after-clone",
                                            "after-manifest", "after-publish"]
    public static let restoreFaultPoints = ["after-preserve", "after-stage", "after-journal",
                                           "after-swap", "after-sync", "after-commit"]

    public func snapshot(gameID: String, now: Int64,
                         faultInjector: VolumeFaultInjector? = nil) throws -> ArchiveRecord {
        try locked {
            try quiet(gameID) {
                try capture(gameID, request: CaptureRequest(volumeKind: .saves, kind: .snapshot, now: now,
                            reason: "explicit snapshot", operation: "snapshot"), fault: faultInjector)
            }
        }
    }

    public func createBackup(gameID: String, now: Int64, reason: String,
                             faultInjector: VolumeFaultInjector? = nil) throws -> ArchiveRecord {
        try locked {
            try quiet(gameID) {
                try capture(gameID, request: CaptureRequest(volumeKind: .saves, kind: .backup, now: now,
                            reason: reason, operation: "backup"), fault: faultInjector)
            }
        }
    }

    /// A scheduler calls this at a quiet boundary; no background timer or implicit retention deletion exists.
    public func snapshotIfDue(gameID: String, now: Int64) throws -> ArchiveRecord? {
        try locked {
            let saves = try resolve(gameID, .saves, nil, in: loadRegistry())
            guard let interval = saves.backupPolicy.periodicIntervalSeconds else { return nil }
            let previous = try archivesUnlocked(gameID).filter { $0.kind == .snapshot }.map(\.createdAt).max()
            if let previous {
                guard now >= previous else { throw VolumeError.invalidPolicy }
                if now - previous < interval { return nil }
            }
            return try quiet(gameID) {
                try capture(gameID, request: CaptureRequest(volumeKind: .saves, kind: .snapshot, now: now,
                            reason: "periodic policy", operation: "snapshot"), fault: nil)
            }
        }
    }

    public func archives(gameID: String) throws -> [ArchiveRecord] {
        try locked { try archivesUnlocked(gameID) }
    }

    public func deleteArchive(gameID: String, archiveID: String) throws {
        try identifier(archiveID)
        try locked {
            _ = try archive(gameID, archiveID)
            let source = try archiveDirectory(gameID)
            let trash = try metadata.child("archive-trash", create: true)
            let id = UUID().uuidString.lowercased()
            guard renameatx_np(source.descriptor, archiveID, trash.descriptor, id, UInt32(RENAME_EXCL)) == 0 else {
                throw VolumeError.systemCall("retire archive", errno)
            }
            try source.sync()
            try trash.sync()
            try trash.remove(id)
        }
    }

    public func restore(gameID: String, archiveID: String, expectedFingerprint: String, now: Int64,
                        faultInjector: VolumeFaultInjector? = nil) throws -> RestoreOutcome {
        try locked {
            try quiet(gameID) {
                let incoming = try archive(gameID, archiveID)
                guard incoming.volumeKind == .saves else { throw VolumeError.invalidPolicy }
                let saves = try resolve(gameID, .saves, nil, in: loadRegistry())
                let current = try directory(saves).inventory(limit: saves.quota)
                if try current.fingerprint != expectedFingerprint {
                    let local = try capture(gameID, request: CaptureRequest(
                        volumeKind: .saves, kind: .conflict, now: now,
                        reason: "restore conflict", operation: "conflict"), fault: nil)
                    return .conflict(localArchiveID: local.id, incomingArchiveID: incoming.id)
                }
                let previous = try capture(gameID, request: CaptureRequest(
                    volumeKind: .saves, kind: .beforeRestore, now: now,
                    reason: "before restore \(archiveID)", operation: "preserve"), fault: nil)
                try faultInjector?("restore.after-preserve")
                let source = try archiveDirectory(gameID).child(archiveID).child("tree")
                try replace(gameID, source: source, request: ReplacementRequest(
                    kind: .saves, before: previous, after: incoming.inventory, operation: "restore"),
                    fault: faultInjector)
                return .restored(previousArchiveID: previous.id)
            }
        }
    }

    func capture(_ gameID: String, request: CaptureRequest, fault: VolumeFaultInjector?) throws -> ArchiveRecord {
        let volumeKind = request.volumeKind
        let kind = request.kind
        let now = request.now
        let reason = request.reason
        let operation = request.operation
        guard now >= 0, !reason.isEmpty, reason.utf8.count <= 512 else { throw VolumeError.invalidPolicy }
        let volume = try resolve(gameID, volumeKind, nil, in: loadRegistry())
        let source = try directory(volume)
        let inventory = try source.inventory(limit: volume.quota)
        let id = UUID().uuidString.lowercased()
        let stages = try metadata.child("staging", create: true)
        let stage = try stages.child(id, create: true)
        let tree = try stage.child("tree", create: true)
        try fault?("\(operation).after-stage")
        let counts = try source.cloneTree(to: tree, inventory: inventory) {
            try fault?("\(operation).after-clone-file")
        }
        try fault?("\(operation).after-clone")
        guard try source.inventory(limit: volume.quota) == inventory,
              try tree.inventory(limit: volume.quota) == inventory else { throw VolumeError.conflict }
        let record = ArchiveRecord(id: id, gameID: gameID, volumeKind: volumeKind, kind: kind,
                                   createdAt: now, reason: reason, inventory: inventory,
                                   clonedFiles: counts.cloned, copiedFiles: counts.copied)
        try stage.write("record.json", data: checked(record))
        try fault?("\(operation).after-manifest")
        let destination = try archiveDirectory(gameID)
        guard renameatx_np(stages.descriptor, id, destination.descriptor, id, UInt32(RENAME_EXCL)) == 0 else {
            throw VolumeError.systemCall("publish archive", errno)
        }
        try destination.sync()
        try stages.sync()
        try fault?("\(operation).after-publish")
        return record
    }

    func archiveDirectory(_ gameID: String) throws -> Directory {
        _ = try titleRecord(gameID, in: loadRegistry())
        return try metadata.child("archives", create: true).child(gameID, create: true)
    }

    func archive(_ gameID: String, _ archiveID: String) throws -> ArchiveRecord {
        try identifier(archiveID)
        let directory = try archiveDirectory(gameID).child(archiveID)
        let record = try decodeChecked(ArchiveRecord.self, directory.read("record.json"))
        guard record.gameID == gameID, record.id == archiveID,
              [.saves, .settings].contains(record.volumeKind) else { throw VolumeError.integrityMismatch }
        let volume = try resolve(gameID, record.volumeKind, nil, in: loadRegistry())
        guard try directory.child("tree").inventory(limit: volume.quota) == record.inventory else {
            throw VolumeError.integrityMismatch
        }
        return record
    }

    func archivesUnlocked(_ gameID: String) throws -> [ArchiveRecord] {
        try archiveDirectory(gameID).names().map { try archive(gameID, $0) }.sorted {
            ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
        }
    }

    func quiet<T>(_ gameID: String, _ body: () throws -> T) throws -> T {
        try identifier(gameID)
        let handle = try lockFile(try metadata.child("leases"), "writers-" + gameID)
        defer { flock(handle, LOCK_UN); close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw VolumeError.busy }
            throw VolumeError.systemCall("quiet boundary", errno)
        }
        return try body()
    }
}
