// Author: Timur Isaev
@testable import AlloyClientCore
import Foundation
import Testing

struct ClientStateTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("alloy-client-tests-" + UUID().uuidString)
    }

    @Test @MainActor func defaultHasNoInventedCatalogOrConnection() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClientStore(storage: PreferencesStore(directory: root))
        #expect(store.snapshot.phase == .disconnected)
        #expect(!store.snapshot.preview && !store.snapshot.connected)
        #expect(store.snapshot.games.isEmpty && store.snapshot.activities.isEmpty)
    }

    @Test @MainActor func selectionSurvivesPartialRefreshAndRestart() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PreferencesStore(directory: root)
        let store = ClientStore(snapshot: .fixture(.available), storage: storage)
        store.select("steam:910002")
        store.preferences.section = .activity
        store.savePreferences()
        store.update(.fixture(.disconnected))
        #expect(store.preferences.selectedGameID == "steam:910002")
        let restored = ClientStore(storage: storage)
        #expect(restored.preferences.section == .activity)
        restored.update(.fixture(.available))
        #expect(restored.selectedGame?.name == "Boreal (synthetic)")
        restored.update(.fixture(.empty))
        #expect(restored.selectedGame == nil && restored.preferences.selectedGameID == nil)
    }

    @Test func fixturesAreExplicitAndNeverCertified() {
        for phase in [LibraryPhase.loading, .empty, .available, .unsupported, .failed, .disconnected] {
            let state = ClientSnapshot.fixture(phase)
            #expect(state.preview)
            #expect(state.phase == phase)
            #expect(state.games.allSatisfy { ["Untested", "Unsupported"].contains($0.status) })
            #expect(state.activities.isEmpty)
        }
    }

    @Test func preferenceStorageRejectsSymlinksAndPublicFiles() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PreferencesStore(directory: root)
        try storage.write(ClientPreferences())
        let file = root.appendingPathComponent("preferences.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: PreferencesError.self) { try storage.read() }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("absent"))
        #expect(throws: PreferencesError.self) { try storage.read() }
    }
}
