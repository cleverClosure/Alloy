// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyContentStore

@Suite("Activation journal identity binding")
struct JournalIdentityBindingTests {
    @Test("a journal filename cannot lend its identity to another operation")
    func journalIdentityMustMatchFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-binding-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ContentStore(root: root)
        let descriptor = LayerDescriptor(
            name: "runtime", version: "1", digest: ContentStore.digest(Data()),
            mediaType: "application/octet-stream", size: 0, role: .hostRuntime
        )
        let operation = ActivationOperation(
            operationID: "operation-a", gameID: "synthetic-game", generationID: "generation-a",
            layers: [descriptor], healthOutcome: .pass, previousActive: nil
        )
        try store.writeJournal(operation)
        let path = store.journalURL("operation-a")
        #expect(try store.readJournal(path) == operation)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        object["operationId"] = "operation-b"
        try store.writeAtomic(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: path)
        #expect(throws: ContentStoreError.invalidJournal("operation-a")) { try store.readJournal(path) }
        try store.writeJournal(operation)
        #expect(try store.readJournal(path) == operation)
    }
}
