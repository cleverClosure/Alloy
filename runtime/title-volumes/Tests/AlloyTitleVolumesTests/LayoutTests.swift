// Author: Timur Isaev

import Darwin
import Foundation
import Testing
@testable import AlloyTitleVolumes

func fixture(_ body: (URL, TitleVolumeStore) throws -> Void) throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("alloy-volumes-\(UUID().uuidString.lowercased())")
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root, TitleVolumeStore(root: root))
}

@Suite struct LayoutTests {
    @Test func persistentIdentityAndPrivateLayout() throws {
        try fixture { root, store in
            let records = try store.createTitle(gameID: "game-one")
            let other = try store.createTitle(gameID: "game-two")
            #expect(Set(records.map(\.id)).isDisjoint(with: other.map(\.id)))
            #expect(records.allSatisfy { $0.generation == nil })
            for record in records {
                var info = stat()
                #expect(lstat(root.appendingPathComponent(record.relativePath).path, &info) == 0)
                #expect(info.st_mode & 0o777 == 0o700)
            }
            try store.write(gameID: "game-one", kind: .saves, path: "nested/slot.sav", data: Data("save".utf8))
            let reopened = try TitleVolumeStore(root: root)
            #expect(try reopened.records(gameID: "game-one") == records)
            #expect(try reopened.read(gameID: "game-one", kind: .saves, path: "nested/slot.sav") == Data("save".utf8))
            #expect(try reopened.inventory(gameID: "game-two", kind: .saves).entries.isEmpty)
        }
    }

    @Test func quotasRefuseWithoutDeletingSaves() throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game", quotas: VolumeQuotas(saves: 8, settings: 8, cache: 8, scratch: 8))
            try store.write(gameID: "game", kind: .saves, path: "one.sav", data: Data(repeating: 1, count: 8))
            #expect(throws: VolumeError.quotaExceeded) {
                try store.write(gameID: "game", kind: .saves, path: "two.sav", data: Data([2]))
            }
            #expect(try store.read(gameID: "game", kind: .saves, path: "one.sav") == Data(repeating: 1, count: 8))
            let file = root.appendingPathComponent("volumes/game/saves/one.sav")
            try Data(repeating: 3, count: 9).write(to: file)
            #expect(throws: VolumeError.quotaExceeded) { try store.inventory(gameID: "game", kind: .saves) }
            #expect(try Data(contentsOf: file).count == 9)
        }
    }

    @Test func pathAndAliasAttacksHaveCleanControls() throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "one")
            _ = try store.createTitle(gameID: "two")
            try store.write(gameID: "two", kind: .saves, path: "slot", data: Data([7]))
            for path in ["../two/saves/slot", "/tmp/escape", "x\\y", "NUL", "slot.", "x//y"] {
                #expect(throws: VolumeError.unsafePath) {
                    try store.write(gameID: "one", kind: .saves, path: path, data: Data([0]))
                }
            }
            let saves = root.appendingPathComponent("volumes/one/saves")
            #expect(symlink("../../two/saves", saves.appendingPathComponent("escape").path) == 0)
            #expect(throws: VolumeError.self) {
                try store.write(gameID: "one", kind: .saves, path: "escape/slot", data: Data([0]))
            }
            #expect(unlink(saves.appendingPathComponent("escape").path) == 0)
            #expect(link(root.appendingPathComponent("volumes/two/saves/slot").path,
                         saves.appendingPathComponent("hardlink").path) == 0)
            #expect(throws: VolumeError.unsafeFile) { try store.inventory(gameID: "one", kind: .saves) }
            #expect(unlink(saves.appendingPathComponent("hardlink").path) == 0)
            try store.write(gameID: "one", kind: .saves, path: "Slot", data: Data([1]))
            #expect(throws: VolumeError.unsafePath) {
                try store.write(gameID: "one", kind: .saves, path: "slot", data: Data([0]))
            }
            #expect(try store.read(gameID: "two", kind: .saves, path: "slot") == Data([7]))
        }
    }

    @Test func scratchExpiryHonorsLiveLeaseAndNeverTouchesSaves() throws {
        try fixture { _, store in
            _ = try store.createTitle(gameID: "game")
            try store.write(gameID: "game", kind: .saves, path: "slot", data: Data([42]))
            let scratch = try store.createScratch(gameID: "game", sessionID: "session-one",
                                                   now: 100, lifetimeSeconds: 10)
            try store.withSessionLease(gameID: "game", sessionID: "session-one") { _ in
                #expect(try store.expireScratch(gameID: "game", now: 111).isEmpty)
                try store.write(gameID: "game", kind: .scratch, generation: "session-one",
                                path: "temp", data: Data([1]))
            }
            #expect(try store.expireScratch(gameID: "game", now: 111) == [scratch.id])
            #expect(try store.read(gameID: "game", kind: .saves, path: "slot") == Data([42]))
        }
    }

    @Test func damagedRegistryNeverSilentlyResets() throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game")
            let registry = root.appendingPathComponent("metadata/title-volumes/registry.json")
            let valid = try Data(contentsOf: registry)
            try valid.prefix(valid.count / 2).write(to: registry)
            #expect(throws: VolumeError.corruptRegistry) { try TitleVolumeStore(root: root) }
            try valid.write(to: registry)
            #expect(try TitleVolumeStore(root: root).records(gameID: "game").count == 2)
            try FileManager.default.removeItem(at: registry)
            #expect(throws: VolumeError.corruptRegistry) { try TitleVolumeStore(root: root) }
        }
    }
}
