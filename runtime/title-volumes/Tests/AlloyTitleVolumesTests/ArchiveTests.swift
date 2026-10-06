// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyTitleVolumes

enum Injected: Error, Equatable { case at(String) }

func savePair(_ store: TitleVolumeStore, value: UInt8) throws {
    try store.write(gameID: "game", kind: .saves, path: "slot/a", data: Data(repeating: value, count: 32768))
    try store.write(gameID: "game", kind: .saves, path: "slot/b", data: Data(repeating: value, count: 65536))
}

@Suite struct ArchiveTests {
    @Test func cloneBackupRestoreAndExplicitDelete() throws {
        try fixture { _, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 1)
            let backup = try store.createBackup(gameID: "game", now: 100, reason: "user request")
            #expect(backup.clonedFiles == 2)
            #expect(backup.copiedFiles == 0)
            try savePair(store, value: 2)
            let changed = try store.inventory(gameID: "game", kind: .saves)
            let restored = try store.restore(gameID: "game", archiveID: backup.id,
                                              expectedFingerprint: changed.fingerprint, now: 101)
            guard case .restored(let previous) = restored else { Issue.record("restore failed"); return }
            #expect(try store.inventory(gameID: "game", kind: .saves) == backup.inventory)
            #expect(try store.archives(gameID: "game").first(where: { $0.id == previous })?.inventory == changed)
            try store.deleteArchive(gameID: "game", archiveID: backup.id)
            #expect(try !store.archives(gameID: "game").contains(where: { $0.id == backup.id }))
            #expect(try store.inventory(gameID: "game", kind: .saves) == backup.inventory)
        }
    }

    @Test func staleRestorePreservesBothVersionsAndCrossTitleIsRefused() throws {
        try fixture { _, store in
            _ = try store.createTitle(gameID: "game")
            _ = try store.createTitle(gameID: "other")
            try savePair(store, value: 1)
            let backup = try store.createBackup(gameID: "game", now: 100, reason: "before change")
            try savePair(store, value: 2)
            let current = try store.inventory(gameID: "game", kind: .saves)
            let outcome = try store.restore(gameID: "game", archiveID: backup.id,
                                           expectedFingerprint: backup.inventory.fingerprint, now: 101)
            guard case .conflict(let local, let incoming) = outcome else { Issue.record("no conflict"); return }
            #expect(incoming == backup.id)
            #expect(try store.archives(gameID: "game").first(where: { $0.id == local })?.inventory == current)
            #expect(try store.inventory(gameID: "game", kind: .saves) == current)
            #expect(throws: VolumeError.self) {
                try store.restore(gameID: "other", archiveID: backup.id, expectedFingerprint: "wrong", now: 102)
            }
            #expect(try store.inventory(gameID: "other", kind: .saves).entries.isEmpty)
        }
    }

    @Test func policyAndQuietBoundary() throws {
        try fixture { _, store in
            _ = try store.createTitle(gameID: "game", backupPolicy: BackupPolicy(periodicIntervalSeconds: 60))
            try savePair(store, value: 1)
            #expect(try store.snapshotIfDue(gameID: "game", now: 100) != nil)
            #expect(try store.snapshotIfDue(gameID: "game", now: 159) == nil)
            _ = try store.createScratch(gameID: "game", sessionID: "session", now: 100)
            _ = try store.withSessionLease(gameID: "game", sessionID: "session") { _ in
                #expect(throws: VolumeError.busy) { try store.snapshot(gameID: "game", now: 160) }
            }
            #expect(try store.snapshotIfDue(gameID: "game", now: 160) != nil)
            #expect(throws: VolumeError.invalidPolicy) { try store.snapshotIfDue(gameID: "game", now: 150) }
        }
    }

    @Test(arguments: TitleVolumeStore.restoreFaultPoints)
    func restoreRecoversBeforeOrAfterAtEveryBoundary(point: String) throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 1)
            let archive = try store.createBackup(gameID: "game", now: 100, reason: "test")
            try savePair(store, value: 2)
            let before = try store.inventory(gameID: "game", kind: .saves)
            #expect(throws: Injected.at(point)) {
                try store.restore(gameID: "game", archiveID: archive.id,
                                  expectedFingerprint: before.fingerprint, now: 101) { reached in
                    if reached == "restore." + point { throw Injected.at(point) }
                }
            }
            let reopened = try TitleVolumeStore(root: root)
            let current = try reopened.inventory(gameID: "game", kind: .saves)
            #expect(current == before || current == archive.inventory)
            let expected = ["after-swap", "after-sync", "after-commit"].contains(point) ? archive.inventory : before
            #expect(current == expected)
            #expect(try reopened.archives(gameID: "game").contains(where: { $0.inventory == before }))
        }
    }

    @Test(arguments: TitleVolumeStore.snapshotFaultPoints)
    func interruptedSnapshotNeverChangesLiveSaves(point: String) throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 9)
            let before = try store.inventory(gameID: "game", kind: .saves)
            #expect(throws: Injected.at(point)) {
                try store.snapshot(gameID: "game", now: 100) { reached in
                    if reached == "snapshot." + point { throw Injected.at(point) }
                }
            }
            let reopened = try TitleVolumeStore(root: root)
            #expect(try reopened.inventory(gameID: "game", kind: .saves) == before)
            let published = try reopened.archives(gameID: "game")
            #expect(published.count == (point == "after-publish" ? 1 : 0))
            #expect(published.allSatisfy { $0.inventory == before })
        }
    }

    @Test func plantedTornArchiveIsDetectedAndLiveSavesPreserved() throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 1)
            let backup = try store.createBackup(gameID: "game", now: 100, reason: "control")
            let path = root.appendingPathComponent("metadata/title-volumes/archives/game/\(backup.id)/tree/slot/a")
            try Data([0]).write(to: path)
            #expect(throws: VolumeError.integrityMismatch) {
                try store.restore(gameID: "game", archiveID: backup.id,
                                  expectedFingerprint: backup.inventory.fingerprint, now: 101)
            }
            #expect(try store.inventory(gameID: "game", kind: .saves) == backup.inventory)
        }
    }

    @Test func declaredAndDiscoveredPathsRemainScoped() throws {
        try fixture { _, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 1)
            let declaration = SavePathDeclaration(profileID: "profile-one", revision: 1, bindings: [
                SavePathBinding(guestPath: "C:\\Users\\Player\\Saved Games\\Game", relativePath: "slot")
            ])
            try store.declareSavePaths(gameID: "game", declaration: declaration)
            #expect(try store.savePaths(gameID: "game") == declaration)
            #expect(try store.discoverSaves(gameID: "game", candidates: ["slot", "missing"]).count == 1)
            #expect(throws: VolumeError.unsafePath) {
                try store.discoverSaves(gameID: "game", candidates: ["../other/saves"])
            }
        }
    }
}
