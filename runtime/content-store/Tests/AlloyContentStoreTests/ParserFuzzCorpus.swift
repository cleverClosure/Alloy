// Author: Timur Isaev

import Darwin
import Foundation
import Testing
@testable import AlloyContentStore

enum JSONParserKind: String, CaseIterable {
    case generation
    case journal
    case lease
    case transport
}

struct ContentParserCorpus {
    let store: ContentStore
    let generation: GenerationReference
    let documents: [JSONParserKind: Data]

    init(root: URL) throws {
        store = try ContentStore(root: root)
        let payload = Data("parser-harness-payload".utf8)
        let descriptor = LayerDescriptor(
            name: "runtime", version: "1", digest: ContentStore.digest(payload),
            mediaType: "application/octet-stream", size: payload.count, role: .hostRuntime
        )
        generation = try store.activate(
            gameID: "fuzz-game", generationID: "fuzz-generation",
            layers: [LayerInput(descriptor: descriptor, contents: payload)], operationID: "fuzz-operation"
        )
        let lease = GenerationLease(
            leaseID: "fuzz-lease", gameID: "fuzz-game", generation: generation, objectDigests: [descriptor.digest],
            holder: LeaseProcessIdentity(processID: 1, startTimeSeconds: 1, startTimeMicroseconds: 0),
            createdAtUnixSeconds: 0
        )
        let transport = TransportRecord(
            operationID: "fuzz-transport", descriptor: descriptor,
            baseURLs: [try #require(URL(string: "https://synthetic.invalid/objects"))]
        )
        let directory = store.generationURL(gameID: "fuzz-game", generationID: "fuzz-generation")
        guard chmod(directory.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
        documents = [
            .generation: try Data(contentsOf: directory.appendingPathComponent("manifest.json")),
            .journal: try Data(contentsOf: store.journalURL("fuzz-operation")),
            .lease: try store.encoder.encode(lease), .transport: try store.encoder.encode(transport)
        ]
        try store.createDirectory(store.leaseURL("fuzz-lease").deletingLastPathComponent())
        try store.createDirectory(store.transportDirectory("fuzz-transport"))
    }

    func stage(_ data: Data, kind: JSONParserKind) throws {
        try data.write(to: path(kind), options: .atomic)
    }

    func read(_ kind: JSONParserKind, data: Data) throws {
        switch kind {
        case .generation:
            // Recompute the envelope digest so mutations reach the manifest parser and semantic validator.
            try store.validateReference(
                GenerationReference(generationID: generation.generationID, manifestDigest: ContentStore.digest(data)),
                gameID: "fuzz-game"
            )
        case .journal: _ = try store.readJournal(path(kind))
        case .lease: _ = try store.readLease(path(kind))
        case .transport: _ = try store.readTransportRecord("fuzz-transport")
        }
    }

    func path(_ kind: JSONParserKind) -> URL {
        switch kind {
        case .generation:
            store.generationURL(gameID: "fuzz-game", generationID: generation.generationID)
                .appendingPathComponent("manifest.json")
        case .journal: store.journalURL("fuzz-operation")
        case .lease: store.leaseURL("fuzz-lease")
        case .transport: store.transportRecordURL("fuzz-transport")
        }
    }

    func legacySeeds() throws -> [Data] {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/main-21136e4-store")
        let manifest = fixtures.appendingPathComponent("generations/fixture-game/generation-a/manifest.json")
        let journals = try FileManager.default.contentsOfDirectory(
            at: fixtures.appendingPathComponent("metadata/journal"), includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        // The truncated JSON seed and unsupported schema mirror existing hostile reader tests.
        return try [Data(contentsOf: manifest)] + journals.map { try Data(contentsOf: $0) }
            + [Data("{".utf8), Data(#"{"schemaVersion":"2.0"}"#.utf8)]
    }
}

func withContentParserCorpus(_ body: (ContentParserCorpus) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("content-parser-fuzz-\(UUID())")
    defer {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            var info = stat()
            if lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { chmod(file.path, 0o700) }
        }
        try? FileManager.default.removeItem(at: root)
    }
    try body(ContentParserCorpus(root: root))
}
