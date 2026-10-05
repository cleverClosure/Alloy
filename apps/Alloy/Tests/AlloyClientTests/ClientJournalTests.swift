// Author: Timur Isaev
@testable import AlloyClientCore
import Foundation
import Testing

struct ClientJournalTests {
    @Test func restartReusesIntentWithinServiceNamespace() throws {
        var journal = ClientJournal()
        let first = try journal.reserve(namespace: "service-a", slot: "install",
                                        method: "install.start", identifier: "plan")
        let bytes = try JSONEncoder().encode(journal)
        var restored = try JSONDecoder().decode(ClientJournal.self, from: bytes)
        #expect(try restored.reserve(namespace: "service-a", slot: "install",
                                     method: "install.start", identifier: "plan") == first)
        let other = try restored.reserve(namespace: "service-b", slot: "install",
                                         method: "install.start", identifier: "plan")
        #expect(other.key != first.key)
        #expect(throws: ClientServiceError.self) {
            try restored.reserve(namespace: "service-a", slot: "install",
                                        method: "install.start", identifier: "changed")
        }
    }

    @Test @MainActor func corruptRequestJournalCannotBecomeAnEmptyWritableJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PreferencesStore(directory: root)
        try storage.writeData(Data("broken".utf8), name: "requests.json")
        let controller = RuntimeController(store: ClientStore(storage: storage), storage: storage)
        #expect(!controller.journalUsable)
        #expect(controller.problem != nil)
        #expect(try storage.readData(name: "requests.json", maximum: 64) == Data("broken".utf8))
    }
}
