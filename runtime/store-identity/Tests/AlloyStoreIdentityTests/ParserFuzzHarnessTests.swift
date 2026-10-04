// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyStoreIdentity

@Suite("Seeded Steam parser harness", .serialized)
struct ParserFuzzHarnessTests {
    @Test("positive corpus control reaches the production Steam parser")
    func validCorpusControl() throws {
        var data = try steamFuzzFixture("clean-appmanifest.acf")
        if ProcessInfo.processInfo.environment["ALLOY_FUZZ_CONTROL"] == "malformation" {
            print("FUZZ_CONTROL target=steam planted=invalid-utf8 positive_corpus=true")
            data = Data([0xFF])
        }
        let manifest = try SteamMetadataParser.parse(data: data, sourceName: "clean-control")
        #expect(manifest.appID == "900000")
        #expect(manifest.installedDepots.count == 2)
    }

    @Test("existing hostile corpus and deterministic structured mutations are rejected")
    func structuredRejectionProperties() throws {
        let settings = try ParserFuzzSettings()
        var random = ParserFuzzRandom(state: settings.seed)
        for (name, expected) in steamHostileCorpus {
            let data = try steamFuzzFixture(name)
            do {
                _ = try SteamMetadataParser.parse(data: data, sourceName: name)
                Issue.record("Hostile fixture was accepted: \(name)")
            } catch let error as SteamMetadataError {
                #expect(steamErrorKind(error) == expected)
            }
        }
        let clean = try #require(String(data: steamFuzzFixture("clean-appmanifest.acf"), encoding: .utf8))
        for iteration in 0..<settings.iterations {
            try settings.checkDeadline()
            let digits = String(random.next() % 1_000_000)
            let sourceName = "structured-\(settings.seed)-\(iteration)"
            let value: String
            let expected: SteamMetadataError
            switch random.next() % 3 {
            case 0:
                value = "-" + digits
                expected = .invalidUnsignedInteger(sourceName: sourceName, field: "SizeOnDisk", value: value)
            case 1:
                value = digits + "x"
                expected = .invalidUnsignedInteger(sourceName: sourceName, field: "SizeOnDisk", value: value)
            default:
                value = "18446744073709551616" + digits
                expected = .sizeOverflow(sourceName: sourceName, field: "SizeOnDisk", value: value)
            }
            let mutated = clean.replacingOccurrences(of: "\"346\"", with: "\"\(value)\"")
            #expect(mutated != clean)
            #expect(throws: expected) {
                try SteamMetadataParser.parse(data: Data(mutated.utf8), sourceName: sourceName)
            }
            let valid = clean.replacingOccurrences(of: "\"346\"", with: "\"\(digits)\"")
            let control = try SteamMetadataParser.parse(data: Data(valid.utf8), sourceName: sourceName)
            #expect(control.sizeOnDisk == UInt64(digits))
        }
        print("FUZZ_STRUCTURED target=steam seed=\(settings.seed) mutations=\(settings.iterations) hostile_fixtures=10")
    }

    @Test("bounded random byte mutations may parse or reject but must not crash")
    func randomByteRobustness() throws {
        let settings = try ParserFuzzSettings()
        var random = ParserFuzzRandom(state: settings.seed)
        let corpus = try (["clean-appmanifest.acf"] + steamHostileCorpus.map(\.0)).map(steamFuzzFixture)
        var accepted = 0
        var rejected = 0
        for iteration in 0..<settings.iterations {
            try settings.checkDeadline()
            let base = corpus[Int(random.next() % UInt64(corpus.count))]
            let data = random.mutate(base)
            do {
                let value = try SteamMetadataParser.parse(data: data, sourceName: "random-\(iteration)")
                #expect(!value.appID.isEmpty)
                #expect(!value.buildID.isEmpty)
                accepted += 1
            } catch is SteamMetadataError {
                rejected += 1
            }
        }
        #expect(accepted + rejected == settings.iterations)
        print(
            "FUZZ_RANDOM target=steam seed=\(settings.seed) iterations=\(settings.iterations)"
                + " accepted=\(accepted) rejected=\(rejected) oracle=crash-only"
        )
    }
}

private let steamHostileCorpus: [(String, String)] = [
    ("truncated-quoted-value.acf", "truncatedInput"), ("truncated-object.acf", "truncatedInput"),
    ("extra-closing-brace.acf", "malformedNesting"), ("missing-value-token.acf", "malformedNesting"),
    ("duplicate-top-key.acf", "duplicateKey"), ("duplicate-depot-key.acf", "duplicateKey"),
    ("invalid-unsigned-size.acf", "invalidUnsignedInteger"), ("non-numeric-size.acf", "invalidUnsignedInteger"),
    ("overflow-top-size.acf", "sizeOverflow"), ("overflow-depot-size.acf", "sizeOverflow")
]

private func steamFuzzFixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("Fixtures/SteamMetadata/\(name)"))
}

private func steamErrorKind(_ error: SteamMetadataError) -> String {
    switch error {
    case .inputTooLarge: "inputTooLarge"
    case .invalidUTF8: "invalidUTF8"
    case .truncatedInput: "truncatedInput"
    case .malformedNesting: "malformedNesting"
    case .nestingTooDeep: "nestingTooDeep"
    case .tokenTooLarge: "tokenTooLarge"
    case .duplicateKey: "duplicateKey"
    case .invalidUnsignedInteger: "invalidUnsignedInteger"
    case .sizeOverflow: "sizeOverflow"
    }
}
