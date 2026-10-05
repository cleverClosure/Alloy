// Author: Timur Isaev
import Foundation
import Observation

@MainActor @Observable
public final class ClientStore {
    public var snapshot: ClientSnapshot
    public var preferences: ClientPreferences
    public var search = ""
    public var persistenceProblem: ClientProblem?
    @ObservationIgnored private let storage: PreferencesStore

    public init(snapshot: ClientSnapshot = ClientSnapshot(), storage: PreferencesStore) {
        self.snapshot = snapshot
        self.storage = storage
        do { preferences = try storage.read() } catch {
            preferences = ClientPreferences()
            persistenceProblem = Self.storageProblem
        }
        reconcileSelection()
    }

    public var visibleGames: [LibraryGame] {
        snapshot.games.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) ||
                $0.status.localizedCaseInsensitiveContains(search) || $0.builds.contains { $0.contains(search) }
        }
    }

    public var selectedGame: LibraryGame? {
        snapshot.games.first { $0.id == preferences.selectedGameID }
    }

    public func select(_ identifier: String?) {
        preferences.selectedGameID = identifier
        savePreferences()
    }

    public func update(_ value: ClientSnapshot) {
        snapshot = value
        reconcileSelection()
    }

    public func savePreferences() {
        do { try storage.write(preferences); persistenceProblem = nil } catch {
            persistenceProblem = Self.storageProblem
        }
    }

    private func reconcileSelection() {
        // A disconnected or partial response is not evidence that a title disappeared.
        guard snapshot.phase == .available || snapshot.phase == .empty || snapshot.phase == .unsupported else { return }
        if selectedGame == nil {
            preferences.selectedGameID = snapshot.games.first?.id
            savePreferences()
        }
    }

    private static var storageProblem: ClientProblem {
        ClientProblem(title: "Preferences could not be saved",
                      explanation: "The local preferences folder is unavailable or has unsafe permissions.",
                      nextStep: "Use a private, writable preferences folder, then reopen Alloy.",
                      supportCode: "CLIENT-PREFERENCES")
    }
}
