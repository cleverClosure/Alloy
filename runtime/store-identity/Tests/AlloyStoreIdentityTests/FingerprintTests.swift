// Author: Timur Isaev

import Darwin
import Foundation
import Testing
@testable import AlloyStoreIdentity

@Suite("Fingerprint parity")
struct FingerprintTests {
    @Test("synthetic fixture has its known identity, files, and aggregate")
    func syntheticScannerMatchesKnownFingerprint() throws {
        let expectedFiles = try syntheticFiles()
        let expected = try FingerprintRecord(
            identity: syntheticIdentity(),
            files: expectedFiles
        )
        let actual = try FingerprintScanner.scan(
            installRoot: syntheticInstallRoot,
            identity: syntheticIdentity()
        )

        #expect(actual == expected)
        #expect(actual.files == expectedFiles)
        #expect(actual.files.map(\.path) == [
            ".hidden-settings",
            "Data/.internal/state.bin",
            "Data/config/settings.ini",
            "Data/levels/level-01.dat",
            "README.txt",
            "SyntheticGame.exe"
        ])
        #expect(actual.fileCount == 6)
        #expect(actual.totalBytes == 346)
        #expect(
            actual.aggregateSHA256
                == "94f9ae3d556e33fcd4f7acfaa36e25521e3542e71e3c67ffa1004adadb6d2d1e"
        )
    }

    @Test("Swift scanner exactly matches the Python parity reference")
    func syntheticScannerMatchesPythonReference() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "alloy-fingerprint-parity-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let outputURL = temporaryDirectory.appendingPathComponent("fingerprint.json")
        try runPythonReference(outputURL: outputURL)

        let pythonRecord = try JSONDecoder().decode(
            FingerprintRecord.self,
            from: Data(contentsOf: outputURL)
        )
        let swiftRecord = try FingerprintScanner.scan(
            installRoot: syntheticInstallRoot,
            identity: syntheticIdentity()
        )
        let pythonCanonical = try pythonRecord.canonicalJSON()
        let swiftCanonical = try swiftRecord.canonicalJSON()
        let expectedFiles = try syntheticFiles()

        #expect(pythonRecord == swiftRecord)
        #expect(pythonCanonical == swiftCanonical)
        #expect(pythonRecord.files == expectedFiles)
        #expect(
            pythonRecord.aggregateSHA256
                == "94f9ae3d556e33fcd4f7acfaa36e25521e3542e71e3c67ffa1004adadb6d2d1e"
        )
    }

    @Test("committed Sir Brante anchor decodes and canonically round-trips")
    func committedAnchorRoundTrips() throws {
        let anchor = try JSONDecoder().decode(
            FingerprintRecord.self,
            from: Data(contentsOf: committedAnchorURL)
        )

        #expect(anchor.record == "alloy-store-001-fingerprint")
        #expect(anchor.version == 1)
        #expect(anchor.appID == "1272160")
        #expect(anchor.name == "The Life and Suffering of Sir Brante")
        #expect(anchor.buildID == "24280929")
        #expect(anchor.depots.count == 1)
        let depot = try #require(anchor.depots["1272161"])
        #expect(depot.manifest == "3716404947812214693")
        #expect(depot.size == "3498258640")
        #expect(anchor.fileCount == 1_422)
        #expect(anchor.files.count == 1_422)
        #expect(anchor.totalBytes == 3_498_258_640)
        #expect(
            anchor.aggregateSHA256
                == "1563163e7bdbd3d54566845f45b0406c02a10e0f66c6a97ba4e55bc1f56be88e"
        )
        let first = try #require(anchor.files.first)
        #expect(first.path == "MonoBleedingEdge/EmbedRuntime/MonoPosixHelper.dll")
        #expect(first.size == 792_064)
        #expect(
            first.sha256
                == "d750f57379401468f58af217c2d975a509a3f2dd9f42bcdba9855a7f6aa3b0cc"
        )
        let last = try #require(anchor.files.last)
        #expect(last.path == "WinPixEventRuntime.dll")
        #expect(last.size == 42_704)
        #expect(
            last.sha256
                == "2f84a7583f08064f55ac9ea3426f898e1bef6f408fecee22c1f5567601e70123"
        )

        let canonical = try anchor.canonicalJSON()
        let decodedCanonical = try JSONDecoder().decode(
            FingerprintRecord.self,
            from: canonical
        )
        let originalValue = try JSONSerialization.jsonObject(
            with: Data(contentsOf: committedAnchorURL)
        )
        let canonicalValue = try JSONSerialization.jsonObject(with: canonical)

        #expect(decodedCanonical == anchor)
        #expect(try decodedCanonical.canonicalJSON() == canonical)
        #expect(
            (originalValue as? NSDictionary)?.isEqual(canonicalValue) == true
        )
    }

    @Test("one changed fixture byte changes the file and aggregate digests")
    func changedByteChangesFingerprint() throws {
        let scratchRoot = try scratchInstallCopy()
        defer {
            try? FileManager.default.removeItem(
                at: scratchRoot.deletingLastPathComponent()
            )
        }

        let before = try FingerprintScanner.scan(
            installRoot: scratchRoot,
            identity: syntheticIdentity()
        )
        let target = scratchRoot.appendingPathComponent("README.txt")
        var bytes = try Data(contentsOf: target)
        bytes[0] ^= 0x01
        try bytes.write(to: target)
        let after = try FingerprintScanner.scan(
            installRoot: scratchRoot,
            identity: syntheticIdentity()
        )
        let beforeTarget = try #require(
            before.files.first { $0.path == "README.txt" }
        )
        let afterTarget = try #require(
            after.files.first { $0.path == "README.txt" }
        )

        #expect(before.fileCount == after.fileCount)
        #expect(before.totalBytes == after.totalBytes)
        #expect(beforeTarget.sha256 != afterTarget.sha256)
        #expect(before.aggregateSHA256 != after.aggregateSHA256)
        #expect(
            before.aggregateSHA256
                == "94f9ae3d556e33fcd4f7acfaa36e25521e3542e71e3c67ffa1004adadb6d2d1e"
        )
    }

    @Test("hidden files are included while symlinks and FIFOs are skipped")
    func scannerMembershipRules() throws {
        let scratchRoot = try scratchInstallCopy()
        defer {
            try? FileManager.default.removeItem(
                at: scratchRoot.deletingLastPathComponent()
            )
        }

        let hiddenURL = scratchRoot.appendingPathComponent("Data/.added-control")
        try Data("hidden control\n".utf8).write(to: hiddenURL)
        let symlinkURL = scratchRoot.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: committedAnchorURL
        )
        let fifoURL = scratchRoot.appendingPathComponent("ignored-fifo")
        let fifoStatus = fifoURL.path.withCString {
            mkfifo($0, S_IRUSR | S_IWUSR)
        }
        guard fifoStatus == 0 else {
            throw FixtureError.fifoCreationFailed(errno)
        }

        let record = try FingerprintScanner.scan(
            installRoot: scratchRoot,
            identity: syntheticIdentity()
        )

        #expect(record.fileCount == 7)
        #expect(record.files.contains { $0.path == "Data/.added-control" })
        #expect(!record.files.contains { $0.path == "outside-link" })
        #expect(!record.files.contains { $0.path == "ignored-fifo" })
    }

    @Test("a deterministic mid-scan mutation is refused")
    func scannerRefusesChangedFinalObservation() throws {
        let scratchRoot = try scratchInstallCopy()
        defer {
            try? FileManager.default.removeItem(
                at: scratchRoot.deletingLastPathComponent()
            )
        }
        let target = scratchRoot.appendingPathComponent("README.txt")

        do {
            _ = try FingerprintScanner.scan(
                installRoot: scratchRoot,
                identity: syntheticIdentity(),
                beforeFinalObservation: {
                    let handle = try FileHandle(forWritingTo: target)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("changed\n".utf8))
                    try handle.close()
                }
            )
            Issue.record("scanner emitted a record for a changed installation")
        } catch let error as FingerprintError {
            #expect(error == .scanChanged("README.txt"))
        }
    }

    @Test("cross-field corruption is rejected")
    func malformedRecordIsRejected() throws {
        let anchorData = try Data(contentsOf: committedAnchorURL)
        var object = try #require(
            JSONSerialization.jsonObject(with: anchorData)
                as? [String: Any]
        )
        object["file_count"] = 0
        let malformedCount = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                FingerprintRecord.self,
                from: malformedCount
            )
        }

        object["file_count"] = 1_422
        object["aggregate_sha256"] = String(repeating: "0", count: 64)
        let malformedAggregate = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                FingerprintRecord.self,
                from: malformedAggregate
            )
        }
    }
}

private let packageRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let repositoryRoot = packageRoot
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let syntheticLibraryRoot = packageRoot
    .appendingPathComponent("Tests/Fixtures/SyntheticSteamLibrary", isDirectory: true)

private let syntheticInstallRoot = syntheticLibraryRoot
    .appendingPathComponent("steamapps/common/Synthetic Game", isDirectory: true)

private let committedAnchorURL = repositoryRoot
    .appendingPathComponent(
        "spikes/STORE-001/results/fingerprint-1272160-first.json",
        isDirectory: false
    )

private func syntheticIdentity() throws -> FingerprintIdentity {
    try FingerprintIdentity(
        appID: "900000",
        name: "Synthetic Game",
        buildID: "90000042",
        depots: [
            "900001": try FingerprintDepotRecord(
                manifest: "1111111111111111111",
                size: "282"
            ),
            "900002": try FingerprintDepotRecord(
                manifest: "2222222222222222222",
                size: "64"
            )
        ]
    )
}

private func syntheticFiles() throws -> [FingerprintFileRecord] {
    [
        try FingerprintFileRecord(
            path: ".hidden-settings",
            size: 34,
            sha256: "a82c7472b5bb29659717c4d2625d3ece4ea44604d681ac7b308f40212bd0bf14"
        ),
        try FingerprintFileRecord(
            path: "Data/.internal/state.bin",
            size: 52,
            sha256: "5644fd4ae752421c1b2fcd812f7e597d89e0f97d6d81941e42c773f2d9ebfe17"
        ),
        try FingerprintFileRecord(
            path: "Data/config/settings.ini",
            size: 69,
            sha256: "9c2063ae09aa3e24bddd0f16c7c7800d9e8cf9abb60680a2032cf9e1c3e21183"
        ),
        try FingerprintFileRecord(
            path: "Data/levels/level-01.dat",
            size: 48,
            sha256: "ed44a4ddf38fd42f228095f1b60a46bfa9feb3193099ccd42db563946ccb35a1"
        ),
        try FingerprintFileRecord(
            path: "README.txt",
            size: 88,
            sha256: "bd1b8801d777d81f11ad069ff2fb2ae3b1c1e0e78db05002d030bed482da15a9"
        ),
        try FingerprintFileRecord(
            path: "SyntheticGame.exe",
            size: 55,
            sha256: "72990a9650e60f93642f6edb23662fad347bf3286acc3be50a993e7b0519c02d"
        )
    ]
}

private func runPythonReference(outputURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3",
        repositoryRoot.appendingPathComponent("tools/steam-fingerprint.py").path,
        syntheticLibraryRoot.path,
        "--app",
        "900000",
        "--out",
        outputURL.path
    ]
    process.currentDirectoryURL = repositoryRoot
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()

    let diagnostics = [
        standardOutput.fileHandleForReading.readDataToEndOfFile(),
        standardError.fileHandleForReading.readDataToEndOfFile()
    ]
        .compactMap { String(data: $0, encoding: .utf8) }
        .joined(separator: "\n")
    guard process.terminationStatus == 0 else {
        throw PythonReferenceError(
            status: process.terminationStatus,
            diagnostics: diagnostics
        )
    }
}

private func scratchInstallCopy() throws -> URL {
    let scratchParent = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "alloy-fingerprint-scratch-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
    let scratchRoot = scratchParent.appendingPathComponent(
        "Synthetic Game",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: scratchParent,
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: syntheticInstallRoot, to: scratchRoot)
    return scratchRoot
}

private struct PythonReferenceError: Error, CustomStringConvertible {
    let status: Int32
    let diagnostics: String

    var description: String {
        "steam-fingerprint.py exited \(status): \(diagnostics)"
    }
}

private enum FixtureError: Error {
    case fifoCreationFailed(Int32)
}
