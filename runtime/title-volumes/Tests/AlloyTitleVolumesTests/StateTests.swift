// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyTitleVolumes

func cacheIdentity(runtime: String = "runtime-one", provider: String = "provider-one") -> CacheIdentity {
    CacheIdentity(runtimeIdentity: runtime, providers: ["graphics": provider],
                  compatibilityInputs: ["host-epoch": "macos-build", "profile": "profile-digest"])
}

@Suite struct StateTests {
    @Test func categoryQuotasHaveExactBoundaryControls() throws {
        try fixture { _, store in
            _ = try store.createTitle(gameID: "game", quotas: VolumeQuotas(saves: 8, settings: 8, cache: 8, scratch: 8))
            let initial = try store.settingsStatus(gameID: "game")
            let settings = try store.updateSettings(gameID: "game", update: SettingsUpdate(
                expectedFingerprint: initial.current.fingerprint,
                files: ["config": Data(repeating: 1, count: 8)], now: 1))
            #expect(throws: VolumeError.quotaExceeded) {
                try store.updateSettings(gameID: "game", update: SettingsUpdate(
                    expectedFingerprint: settings.inventory.fingerprint,
                    files: ["config": Data(repeating: 2, count: 9)], now: 2))
            }
            #expect(try store.settingsStatus(gameID: "game").current == settings.inventory)
            let cache = try store.activateCache(gameID: "game", identity: cacheIdentity())
            _ = try store.createScratch(gameID: "game", sessionID: "session", now: 1)
            for (kind, generation) in [(VolumeKind.cache, cache.volume.generation), (.scratch, "session")] {
                try store.write(gameID: "game", kind: kind, generation: generation,
                                path: "exact", data: Data(repeating: 1, count: 8))
                #expect(throws: VolumeError.quotaExceeded) {
                    try store.write(gameID: "game", kind: kind, generation: generation, path: "extra", data: Data([1]))
                }
                #expect(try store.inventory(gameID: "game", kind: kind, generation: generation).bytes == 8)
            }
        }
    }

    @Test func settingsVersionsResetAndExternalDrift() throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 4)
            let saves = try store.inventory(gameID: "game", kind: .saves)
            let initial = try store.settingsStatus(gameID: "game")
            let first = try store.updateSettings(gameID: "game", update: SettingsUpdate(
                expectedFingerprint: initial.current.fingerprint, files: ["config.ini": Data("one".utf8)], now: 100))
            #expect(first.revision == 1)
            #expect(try !store.settingsStatus(gameID: "game").changedOutsideLibrary)
            let file = root.appendingPathComponent("volumes/game/settings/config.ini")
            try Data("user edit".utf8).write(to: file)
            let drift = try store.settingsStatus(gameID: "game")
            #expect(drift.changedOutsideLibrary)
            #expect(throws: VolumeError.conflict) {
                try store.updateSettings(gameID: "game", update: SettingsUpdate(
                    expectedFingerprint: first.inventory.fingerprint, files: [:], now: 101))
            }
            let reset = try store.updateSettings(gameID: "game", update: SettingsUpdate(
                expectedFingerprint: drift.current.fingerprint, files: [:], now: 101))
            #expect(reset.revision == 2)
            #expect(reset.inventory.entries.isEmpty)
            #expect(try store.archives(gameID: "game").contains(where: { $0.inventory == drift.current }))
            #expect(try store.settingsHistory(gameID: "game").map(\.revision) == [1, 2])
            #expect(try store.inventory(gameID: "game", kind: .saves) == saves)
        }
    }

    @Test(arguments: TitleVolumeStore.settingsFaultPoints)
    func settingsReplacementAndMetadataRecoverTogether(point: String) throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 3)
            let saves = try store.inventory(gameID: "game", kind: .saves)
            let initial = try store.settingsStatus(gameID: "game")
            #expect(throws: Injected.at(point)) {
                try store.updateSettings(gameID: "game", update: SettingsUpdate(
                    expectedFingerprint: initial.current.fingerprint,
                    files: ["a": Data([1]), "b": Data([2])], now: 100)) { reached in
                        if reached == "settings." + point { throw Injected.at(point) }
                    }
            }
            let reopened = try TitleVolumeStore(root: root)
            let status = try reopened.settingsStatus(gameID: "game")
            if ["after-swap", "after-sync", "after-metadata", "after-commit"].contains(point) {
                #expect(status.version?.revision == 1)
                #expect(!status.changedOutsideLibrary)
                #expect(status.current.entries.count == 2)
            } else {
                #expect(status.version == nil)
                #expect(status.current.entries.isEmpty)
            }
            #expect(try reopened.inventory(gameID: "game", kind: .saves) == saves)
        }
    }

    @Test func completeCacheIdentityInvalidatesOnlyDisposableBytes() throws {
        try fixture { _, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 8)
            let saves = try store.inventory(gameID: "game", kind: .saves)
            let first = try store.activateCache(gameID: "game", identity: cacheIdentity())
            try store.write(gameID: "game", kind: .cache, generation: first.volume.generation,
                            path: "shader", data: Data([1]))
            #expect(try store.activateCache(gameID: "game", identity: cacheIdentity()) == first)
            #expect(try store.inventory(gameID: "game", kind: .cache,
                                        generation: first.volume.generation).bytes == 1)
            let runtimeChanged = try store.activateCache(gameID: "game",
                                                         identity: cacheIdentity(runtime: "runtime-two"))
            #expect(runtimeChanged.volume.id != first.volume.id)
            #expect(throws: VolumeError.unknownVolume) {
                try store.inventory(gameID: "game", kind: .cache, generation: first.volume.generation)
            }
            let providerChanged = try store.activateCache(gameID: "game",
                identity: cacheIdentity(runtime: "runtime-two", provider: "provider-two"))
            #expect(providerChanged.volume.id != runtimeChanged.volume.id)
            #expect(try store.inventory(gameID: "game", kind: .saves) == saves)
        }
    }

    @Test(arguments: TitleVolumeStore.cacheFaultPoints)
    func cacheJournalRecoversWithoutSaveMutation(point: String) throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 5)
            let saves = try store.inventory(gameID: "game", kind: .saves)
            let first = try store.activateCache(gameID: "game", identity: cacheIdentity())
            try store.write(gameID: "game", kind: .cache, generation: first.volume.generation,
                            path: "cache", data: Data([1]))
            let next = cacheIdentity(runtime: "next")
            #expect(throws: Injected.at(point)) {
                try store.activateCache(gameID: "game", identity: next) { reached in
                    if reached == "cache." + point { throw Injected.at(point) }
                }
            }
            let reopened = try TitleVolumeStore(root: root)
            #expect(try reopened.activeCache(gameID: "game")?.identity == next)
            #expect(try reopened.records(gameID: "game").filter { $0.kind == .cache }.count == 1)
            #expect(try reopened.inventory(gameID: "game", kind: .saves) == saves)
        }
    }

    @Test(arguments: TitleVolumeStore.scratchFaultPoints)
    func scratchJournalRecoversWithoutSaveMutation(point: String) throws {
        try fixture { root, store in
            _ = try store.createTitle(gameID: "game")
            try savePair(store, value: 6)
            let saves = try store.inventory(gameID: "game", kind: .saves)
            _ = try store.createScratch(gameID: "game", sessionID: "dead", now: 100, lifetimeSeconds: 1)
            try store.write(gameID: "game", kind: .scratch, generation: "dead", path: "temp", data: Data([1]))
            #expect(throws: Injected.at(point)) {
                try store.expireScratch(gameID: "game", now: 102) { reached in
                    if reached == "scratch." + point { throw Injected.at(point) }
                }
            }
            let reopened = try TitleVolumeStore(root: root)
            #expect(try reopened.records(gameID: "game").allSatisfy { $0.kind != .scratch })
            #expect(try reopened.inventory(gameID: "game", kind: .saves) == saves)
        }
    }
}
