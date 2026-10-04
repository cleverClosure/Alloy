// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyContentStore

@Suite("Seeded content-store parser harness", .serialized)
struct ParserFuzzHarnessTests {
    @Test("positive corpus control reaches each production JSON reader")
    func validCorpusControl() throws {
        try withContentParserCorpus { corpus in
            for kind in JSONParserKind.allCases {
                var data = try #require(corpus.documents[kind])
                if ProcessInfo.processInfo.environment["ALLOY_FUZZ_CONTROL"] == "malformation" {
                    print("FUZZ_CONTROL target=content-store planted=truncated-json positive_corpus=true")
                    data = Data("{".utf8)
                }
                try corpus.stage(data, kind: kind)
                try corpus.read(kind, data: data)
            }
        }
    }

    @Test("bounded structured JSON mutations have exact semantic rejection oracles")
    func structuredRejectionProperties() throws {
        let settings = try ParserFuzzSettings()
        var random = ParserFuzzRandom(state: settings.seed)
        try withContentParserCorpus { corpus in
            for kind in JSONParserKind.allCases {
                let original = try #require(corpus.documents[kind])
                let object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
                for _ in 0..<settings.iterations {
                    try settings.checkDeadline()
                    let mutation = try mutatedJSON(object, kind: kind, random: &random)
                    try corpus.stage(mutation.data, kind: kind)
                    switch mutation.expected {
                    case .store(let error):
                        #expect(throws: error) { try corpus.read(kind, data: mutation.data) }
                    case .transport(let error):
                        #expect(throws: error) { try corpus.read(kind, data: mutation.data) }
                    }
                    try corpus.stage(original, kind: kind)
                    try corpus.read(kind, data: original)
                }
                print("FUZZ_STRUCTURED target=\(kind.rawValue) seed=\(settings.seed) mutations=\(settings.iterations)")
            }
        }
    }

    @Test("random mutations exercise production readers without inventing a rejection oracle")
    func randomByteRobustness() throws {
        let settings = try ParserFuzzSettings()
        var random = ParserFuzzRandom(state: settings.seed)
        try withContentParserCorpus { corpus in
            let seeds = try corpus.legacySeeds()
            for kind in JSONParserKind.allCases {
                let documents = [try #require(corpus.documents[kind])] + seeds
                var accepted = 0
                var rejected = 0
                for _ in 0..<settings.iterations {
                    try settings.checkDeadline()
                    let base = documents[Int(random.next() % UInt64(documents.count))]
                    let data = random.mutate(base)
                    try corpus.stage(data, kind: kind)
                    do {
                        try corpus.read(kind, data: data)
                        accepted += 1
                    } catch is DecodingError {
                        rejected += 1
                    } catch is ContentStoreError {
                        rejected += 1
                    } catch is ContentTransportError {
                        rejected += 1
                    }
                }
                #expect(accepted + rejected == settings.iterations)
                print(
                    "FUZZ_RANDOM target=\(kind.rawValue) seed=\(settings.seed) iterations=\(settings.iterations)"
                        + " accepted=\(accepted) rejected=\(rejected) oracle=crash-only"
                )
            }
        }
    }
}

private enum ParserExpectedError {
    case store(ContentStoreError)
    case transport(ContentTransportError)
}

private func mutatedJSON(
    _ source: [String: Any], kind: JSONParserKind, random: inout ParserFuzzRandom
) throws -> (data: Data, expected: ParserExpectedError) {
    var object = source
    let choice = random.next() % 4
    let expected: ParserExpectedError
    if choice == 0 {
        let version = "unsupported-\(random.next())"
        object["schemaVersion"] = version
        let names: [JSONParserKind: String] = [
            .generation: "generation manifest", .journal: "activation journal",
            .lease: "generation lease", .transport: "transport record"
        ]
        expected = .store(.unsupportedSchema(kind: try #require(names[kind]), version: version))
    } else {
        expected = try mutateSemantics(&object, kind: kind, choice: choice, value: random.next())
    }
    return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), expected)
}

private func mutateSemantics(
    _ object: inout [String: Any], kind: JSONParserKind, choice: UInt64, value: UInt64
) throws -> ParserExpectedError {
    switch kind {
    case .generation:
        if choice == 1 {
            object["gameId"] = "different-game-\(value)"
        } else if choice == 2 {
            object["layers"] = [Any]()
        } else {
            var layers = try #require(object["layers"] as? [[String: Any]])
            layers[0]["size"] = -Int(value % 1_000 + 1)
            object["layers"] = layers
            return .store(.invalidLayer("name, version, media type, and nonnegative size are required"))
        }
        return .store(.incompleteGeneration("fuzz-generation"))
    case .journal:
        if choice == 1 {
            object["operationId"] = "different-operation-\(value)"
        } else if choice == 2 {
            object["kind"] = "different-kind-\(value)"
        } else {
            object["layers"] = [Any]()
        }
        return .store(.invalidJournal("fuzz-operation"))
    case .lease:
        try mutateLease(&object, choice: choice, value: value)
        return .store(.invalidLease("fuzz-lease"))
    case .transport:
        if choice == 1 {
            object["byteCount"] = -Int(value % 1_000 + 1)
        } else if choice == 2 {
            object["baseUrls"] = ["file:///synthetic-\(value)"]
        } else {
            object["mirrorIndex"] = Int(value % 1_000 + 2)
        }
        return .transport(.invalidRecord("fuzz-transport"))
    }
}

private func mutateLease(_ object: inout [String: Any], choice: UInt64, value: UInt64) throws {
    if choice == 1 {
        object["unexpected-\(value)"] = true
    } else if choice == 2 {
        object["objectDigests"] = [Any]()
    } else {
        var holder = try #require(object["holder"] as? [String: Any])
        holder["processId"] = 0
        object["holder"] = holder
    }
}
