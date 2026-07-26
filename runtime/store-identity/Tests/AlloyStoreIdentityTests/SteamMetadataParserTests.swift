// Author: Timur Isaev

import Foundation
import Testing
import AlloyStoreIdentity

@Suite("Steam metadata parser")
struct SteamMetadataParserTests {
    @Test("clean appmanifest metadata is parsed into typed identity fields")
    func cleanControlParses() throws {
        _ = try parseAndCheckCleanControl()
    }

    @Test(
        "hostile fixture is refused while its clean control still parses",
        arguments: hostileFixtureCases
    )
    func hostileFixtureIsRefused(testCase: HostileFixtureCase) throws {
        _ = try parseAndCheckCleanControl()

        let data = try Data(contentsOf: metadataFixtureURL(testCase.fixture))
        let error = captureError {
            _ = try SteamMetadataParser.parse(
                data: data,
                sourceName: testCase.fixture
            )
        }

        #expect(
            matches(error, expected: testCase.expectedError),
            "expected \(testCase.expectedError.rawValue), got \(String(describing: error))"
        )
    }

    @Test(
        "generated parser limit input is refused while its clean control still parses",
        arguments: GeneratedHostileInput.allCases
    )
    func generatedLimitIsRefused(testCase: GeneratedHostileInput) throws {
        _ = try parseAndCheckCleanControl()

        let error = captureError {
            _ = try SteamMetadataParser.parse(
                data: testCase.data,
                sourceName: testCase.rawValue
            )
        }

        #expect(
            matches(error, expected: testCase.expectedError),
            "expected \(testCase.expectedError.rawValue), got \(String(describing: error))"
        )
    }
}

struct HostileFixtureCase: Sendable {
    let fixture: String
    let expectedError: ExpectedMetadataError
}

enum ExpectedMetadataError: String, Sendable {
    case inputTooLarge
    case invalidUTF8
    case truncatedInput
    case malformedNesting
    case nestingTooDeep
    case tokenTooLarge
    case duplicateKey
    case invalidUnsignedInteger
    case sizeOverflow
}

enum GeneratedHostileInput: String, CaseIterable, Sendable {
    case inputTooLarge = "input-too-large"
    case invalidUTF8 = "invalid-utf8"
    case nestingTooDeep = "nesting-too-deep"
    case tokenTooLarge = "token-too-large"

    var expectedError: ExpectedMetadataError {
        switch self {
        case .inputTooLarge:
            return .inputTooLarge
        case .invalidUTF8:
            return .invalidUTF8
        case .nestingTooDeep:
            return .nestingTooDeep
        case .tokenTooLarge:
            return .tokenTooLarge
        }
    }

    var data: Data {
        switch self {
        case .inputTooLarge:
            return Data(
                repeating: 0x20,
                count: 8 * 1_024 * 1_024 + 1
            )
        case .invalidUTF8:
            return Data([
                0x22, 0x41, 0x70, 0x70, 0x53, 0x74, 0x61, 0x74, 0x65, 0x22,
                0x0A, 0x7B, 0x0A,
                0x22, 0x6E, 0x61, 0x6D, 0x65, 0x22, 0x20,
                0x22, 0xFF, 0x22, 0x0A,
                0x7D, 0x0A
            ])
        case .nestingTooDeep:
            var text = "\"AppState\"\n{\n"
            for index in 0...64 {
                text += "\"level-\(index)\"\n{\n"
            }
            text += "\"value\" \"leaf\"\n"
            for _ in 0...64 {
                text += "}\n"
            }
            text += "}\n"
            return Data(text.utf8)
        case .tokenTooLarge:
            let oversizedValue = String(
                repeating: "x",
                count: 1 * 1_024 * 1_024 + 1
            )
            return Data(
                """
                "AppState"
                {
                    "name" "\(oversizedValue)"
                }

                """.utf8
            )
        }
    }
}

private let hostileFixtureCases: [HostileFixtureCase] = [
    HostileFixtureCase(
        fixture: "truncated-quoted-value.acf",
        expectedError: .truncatedInput
    ),
    HostileFixtureCase(
        fixture: "truncated-object.acf",
        expectedError: .truncatedInput
    ),
    HostileFixtureCase(
        fixture: "extra-closing-brace.acf",
        expectedError: .malformedNesting
    ),
    HostileFixtureCase(
        fixture: "missing-value-token.acf",
        expectedError: .malformedNesting
    ),
    HostileFixtureCase(
        fixture: "duplicate-top-key.acf",
        expectedError: .duplicateKey
    ),
    HostileFixtureCase(
        fixture: "duplicate-depot-key.acf",
        expectedError: .duplicateKey
    ),
    HostileFixtureCase(
        fixture: "invalid-unsigned-size.acf",
        expectedError: .invalidUnsignedInteger
    ),
    HostileFixtureCase(
        fixture: "non-numeric-size.acf",
        expectedError: .invalidUnsignedInteger
    ),
    HostileFixtureCase(
        fixture: "overflow-top-size.acf",
        expectedError: .sizeOverflow
    ),
    HostileFixtureCase(
        fixture: "overflow-depot-size.acf",
        expectedError: .sizeOverflow
    )
]

private let metadataFixtureRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/SteamMetadata", isDirectory: true)

private func metadataFixtureURL(_ fixture: String) -> URL {
    metadataFixtureRoot.appendingPathComponent(fixture, isDirectory: false)
}

@discardableResult
private func parseAndCheckCleanControl() throws -> SteamAppManifest {
    let fixture = "clean-appmanifest.acf"
    let manifest = try SteamMetadataParser.parse(
        data: Data(contentsOf: metadataFixtureURL(fixture)),
        sourceName: fixture
    )

    #expect(manifest.appID == "900000")
    #expect(manifest.name == "Synthetic Game")
    #expect(manifest.installDirectory == "Synthetic Game")
    #expect(manifest.buildID == "90000042")
    #expect(manifest.sizeOnDisk == 346)
    #expect(manifest.installedDepots.count == 2)
    return manifest
}

private func captureError(_ operation: () throws -> Void) -> (any Error)? {
    do {
        try operation()
        return nil
    } catch {
        return error
    }
}

private func matches(
    _ error: (any Error)?,
    expected: ExpectedMetadataError
) -> Bool {
    guard let metadataError = error as? SteamMetadataError else {
        return false
    }

    switch expected {
    case .inputTooLarge:
        return isInputTooLarge(metadataError)
    case .invalidUTF8:
        return isInvalidUTF8(metadataError)
    case .truncatedInput:
        return isTruncatedInput(metadataError)
    case .malformedNesting:
        return isMalformedNesting(metadataError)
    case .nestingTooDeep:
        return isNestingTooDeep(metadataError)
    case .tokenTooLarge:
        return isTokenTooLarge(metadataError)
    case .duplicateKey:
        return isDuplicateKey(metadataError)
    case .invalidUnsignedInteger:
        return isInvalidUnsignedInteger(metadataError)
    case .sizeOverflow:
        return isSizeOverflow(metadataError)
    }
}

private func isInputTooLarge(_ error: SteamMetadataError) -> Bool {
    if case .inputTooLarge = error { return true }
    return false
}

private func isInvalidUTF8(_ error: SteamMetadataError) -> Bool {
    if case .invalidUTF8 = error { return true }
    return false
}

private func isTruncatedInput(_ error: SteamMetadataError) -> Bool {
    if case .truncatedInput = error { return true }
    return false
}

private func isMalformedNesting(_ error: SteamMetadataError) -> Bool {
    if case .malformedNesting = error { return true }
    return false
}

private func isNestingTooDeep(_ error: SteamMetadataError) -> Bool {
    if case .nestingTooDeep = error { return true }
    return false
}

private func isTokenTooLarge(_ error: SteamMetadataError) -> Bool {
    if case .tokenTooLarge = error { return true }
    return false
}

private func isDuplicateKey(_ error: SteamMetadataError) -> Bool {
    if case .duplicateKey = error { return true }
    return false
}

private func isInvalidUnsignedInteger(_ error: SteamMetadataError) -> Bool {
    if case .invalidUnsignedInteger = error { return true }
    return false
}

private func isSizeOverflow(_ error: SteamMetadataError) -> Bool {
    if case .sizeOverflow = error { return true }
    return false
}
