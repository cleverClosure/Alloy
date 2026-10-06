// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyTitleVolumes

@Suite struct HandoffTests {
    @Test func rootRejectsEmbeddedNullAndSymlinkAlias() throws {
        try fixture { root, _ in
            #expect(throws: VolumeError.unsafePath) {
                try TitleVolumeStore(root: root.appendingPathComponent("bad\0root"))
            }
            let alias = root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
            #expect(throws: VolumeError.unsafePath) {
                try TitleVolumeStore(root: URL(fileURLWithPath: alias))
            }
        }
    }

    @Test func extendedACLDoesNotOverridePrivateMode() throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game")
            try store.write(gameID: "game", kind: .saves, path: "slot", data: Data([1]))
            let path = root.appendingPathComponent("volumes/game/saves/slot").path
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/bin/chmod")
            command.arguments = ["+a", "everyone allow read", path]
            try command.run()
            command.waitUntilExit()
            #expect(command.terminationStatus == 0)
            #expect(throws: VolumeError.unsafeFile) { try store.inventory(gameID: "game", kind: .saves) }
            let clean = Process()
            clean.executableURL = URL(fileURLWithPath: "/bin/chmod")
            clean.arguments = ["-N", path]
            try clean.run()
            clean.waitUntilExit()
            #expect(clean.terminationStatus == 0)
            #expect(try store.read(gameID: "game", kind: .saves, path: "slot") == Data([1]))
        }
    }

    @Test func planHasSixTypedVolumesAndFourScopedDrives() throws {
        try fixture { _, store in
            _ = try store.createTitle(gameID: "game")
            let cache = try store.activateCache(gameID: "game", identity: cacheIdentity())
            _ = try store.createScratch(gameID: "game", sessionID: "session", now: 100, lifetimeSeconds: 10)
            let request = SessionVolumeRequest(gameID: "game", sessionID: "session",
                                               runtimeVolumeID: "runtime-handle", payloadVolumeID: "payload-handle")
            let plan = try store.drivePlan(request, expectedCacheIdentity: cacheIdentity(), now: 101)
            #expect(Set(plan.volumeIDs.keys) == ["runtime", "game", "saves", "settings", "cache", "temp"])
            #expect(Set(plan.volumeIDs.values).count == 6)
            #expect(plan.drives.map(\.letter) == ["C", "G", "S", "T"])
            #expect(plan.drives[0].bindings[0].access == .readOnly)
            #expect(plan.drives[2].bindings.map(\.relativePath) == ["saves", "settings"])
            #expect(!plan.hostRootMapped)
            #expect(plan.volumeIDs["cache"] == cache.volume.id)
            #expect(throws: VolumeError.unknownVolume) {
                try store.drivePlan(request, expectedCacheIdentity: cacheIdentity(), now: 110)
            }
            #expect(throws: VolumeError.conflict) {
                try store.drivePlan(request, expectedCacheIdentity: cacheIdentity(runtime: "changed"), now: 101)
            }
            #expect(throws: VolumeError.unsafePath) {
                try store.drivePlan(SessionVolumeRequest(gameID: "game", sessionID: "session",
                    runtimeVolumeID: "same", payloadVolumeID: "same"),
                    expectedCacheIdentity: cacheIdentity(), now: 101)
            }
            #expect(throws: VolumeError.invalidIdentifier) {
                try store.drivePlan(SessionVolumeRequest(gameID: "game", sessionID: "session",
                    runtimeVolumeID: "/", payloadVolumeID: "payload"),
                    expectedCacheIdentity: cacheIdentity(), now: 101)
            }
        }
    }

    @Test func unicodeCaseAliasesAndOverlappingRedirectionsAreRefused() throws {
        try fixture { _, store in
            _ = try store.createTitle(gameID: "game")
            try store.write(gameID: "game", kind: .saves, path: "σ.sav", data: Data([1]))
            #expect(throws: VolumeError.unsafePath) {
                try store.write(gameID: "game", kind: .saves, path: "ς.sav", data: Data([2]))
            }
            #expect(try store.read(gameID: "game", kind: .saves, path: "σ.sav") == Data([1]))
            #expect(throws: VolumeError.unsafePath) {
                try store.declareSavePaths(gameID: "game", declaration: SavePathDeclaration(
                    profileID: "profile", revision: 1, bindings: [
                        SavePathBinding(guestPath: "C:\\Saves", relativePath: "one"),
                        SavePathBinding(guestPath: "C:\\Saves\\Nested", relativePath: "two")
                    ]))
            }
            try store.declareSavePaths(gameID: "game", declaration: SavePathDeclaration(
                profileID: "profile", revision: 1,
                bindings: [SavePathBinding(guestPath: "C:\\Saves", relativePath: "one")]))
            #expect(try store.savePaths(gameID: "game")?.bindings.count == 1)
        }
    }
}
