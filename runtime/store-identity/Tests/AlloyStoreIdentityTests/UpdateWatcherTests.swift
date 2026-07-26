// Author: Timur Isaev

import Foundation
import Testing
import AlloyStoreIdentity

@Suite("Update watcher")
struct UpdateWatcherTests {
    @Test("launcher or metadata-only update preserves identical game content")
    func metadataOnlyUpdate() throws {
        let anchor = try loadUpdateAnchor()
        try requireUnchangedControl(anchor)

        let observed = try replacingIdentity(
            anchor,
            buildID: "24280930",
            manifestID: "3716404947812214694"
        )
        let detection = try #require(
            try UpdateWatcher.detect(
                anchor: anchor,
                observation: observation(for: observed)
            )
        )

        #expect(detection.appID == "1272160")
        #expect(detection.supersededBuildID == "24280929")
        #expect(detection.observedBuildID == "24280930")
        #expect(detection.metadataChanged)
        #expect(!detection.gameContentChanged)
        #expect(detection.changedDepotIDs == ["1272161"])
        #expect(detection.addedFilePaths.isEmpty)
        #expect(detection.removedFilePaths.isEmpty)
        #expect(detection.changedFilePaths.isEmpty)
        #expect(observed.files == anchor.files)
        #expect(observed.aggregateSHA256 == anchor.aggregateSHA256)
    }

    @Test("game-only update reports changed bytes under unchanged metadata")
    func gameOnlyUpdate() throws {
        let anchor = try loadUpdateAnchor()
        try requireUnchangedControl(anchor)

        let changedPath = "The Life and Suffering of Sir Brante.exe"
        let observed = try replacingFile(
            in: anchor,
            path: changedPath,
            sha256: String(repeating: "a", count: 64)
        )
        let detection = try #require(
            try UpdateWatcher.detect(
                anchor: anchor,
                observation: observation(for: observed)
            )
        )

        #expect(detection.appID == "1272160")
        #expect(detection.supersededBuildID == "24280929")
        #expect(detection.observedBuildID == "24280929")
        #expect(!detection.metadataChanged)
        #expect(detection.gameContentChanged)
        #expect(detection.changedDepotIDs.isEmpty)
        #expect(detection.addedFilePaths.isEmpty)
        #expect(detection.removedFilePaths.isEmpty)
        #expect(detection.changedFilePaths == [changedPath])
        #expect(observed.aggregateSHA256 != anchor.aggregateSHA256)
    }

    @Test("combined build update names superseded metadata and every file delta")
    func combinedBuildAndGameUpdate() throws {
        let anchor = try loadUpdateAnchor()
        try requireUnchangedControl(anchor)

        let removedPath = "MonoBleedingEdge/EmbedRuntime/MonoPosixHelper.dll"
        let changedPath = "The Life and Suffering of Sir Brante.exe"
        let addedPath = "zz-alloy-added.bin"
        var files: [FingerprintFileRecord] = try anchor.files.compactMap { file
            -> FingerprintFileRecord? in
            if file.path == removedPath {
                return nil
            }
            if file.path == changedPath {
                return try FingerprintFileRecord(
                    path: file.path,
                    size: file.size,
                    sha256: String(repeating: "b", count: 64)
                )
            }
            return file
        }
        files.append(try FingerprintFileRecord(
            path: addedPath,
            size: 17,
            sha256: String(repeating: "c", count: 64)
        ))
        let observed = try replacingIdentity(
            anchor,
            buildID: "24280931",
            manifestID: "3716404947812214695",
            files: files
        )
        let detection = try #require(
            try UpdateWatcher.detect(
                anchor: anchor,
                observation: observation(for: observed)
            )
        )

        #expect(detection.appID == "1272160")
        #expect(detection.supersededBuildID == "24280929")
        #expect(detection.observedBuildID == "24280931")
        #expect(detection.metadataChanged)
        #expect(detection.gameContentChanged)
        #expect(detection.changedDepotIDs == ["1272161"])
        #expect(detection.addedFilePaths == [addedPath])
        #expect(detection.removedFilePaths == [removedPath])
        #expect(detection.changedFilePaths == [changedPath])
    }

    @Test("manifest and fingerprint disagreement is refused")
    func mismatchedObservationIsRefused() throws {
        let anchor = try loadUpdateAnchor()
        try requireUnchangedControl(anchor)

        let metadataFingerprint = try replacingIdentity(
            anchor,
            buildID: "24280932",
            manifestID: "3716404947812214696"
        )
        let mismatched = try stagedObservation(
            metadataFingerprint: metadataFingerprint,
            fingerprint: anchor
        )
        let error = captureUpdateError {
            _ = try UpdateWatcher.detect(
                anchor: anchor,
                observation: mismatched
            )
        }

        #expect(error != nil)
    }
}

private let gate3RepositoryRoot = URL(
    fileURLWithPath: #filePath,
    isDirectory: false
)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let updateAnchorURL = gate3RepositoryRoot.appendingPathComponent(
    "spikes/STORE-001/results/fingerprint-1272160-first.json",
    isDirectory: false
)

private func loadUpdateAnchor() throws -> FingerprintRecord {
    try JSONDecoder().decode(
        FingerprintRecord.self,
        from: Data(contentsOf: updateAnchorURL)
    )
}

private func requireUnchangedControl(_ anchor: FingerprintRecord) throws {
    let detection = try UpdateWatcher.detect(
        anchor: anchor,
        observation: try observation(for: anchor)
    )
    #expect(detection == nil)
}

private func observation(
    for fingerprint: FingerprintRecord
) throws -> UpdateObservation {
    try stagedObservation(
        metadataFingerprint: fingerprint,
        fingerprint: fingerprint
    )
}

private func stagedObservation(
    metadataFingerprint: FingerprintRecord,
    fingerprint: FingerprintRecord
) throws -> UpdateObservation {
    let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "alloy-update-observation-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: scratchRoot,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    let fingerprintURL = scratchRoot.appendingPathComponent("fingerprint.json")
    let manifestURL = scratchRoot.appendingPathComponent(
        "appmanifest_\(metadataFingerprint.appID).acf"
    )
    try fingerprint.canonicalJSON().write(to: fingerprintURL)
    try manifestData(for: metadataFingerprint).write(to: manifestURL)

    let stagedFingerprint = try JSONDecoder().decode(
        FingerprintRecord.self,
        from: Data(contentsOf: fingerprintURL)
    )
    let stagedMetadata = try SteamMetadataParser.parse(
        data: Data(contentsOf: manifestURL),
        sourceName: manifestURL.lastPathComponent
    )
    return UpdateObservation(
        metadata: stagedMetadata,
        fingerprint: stagedFingerprint
    )
}

private func manifestData(for fingerprint: FingerprintRecord) -> Data {
    let depotLines = fingerprint.depots.keys.sorted().flatMap { depotID
        -> [String] in
        guard let depot = fingerprint.depots[depotID] else {
            return []
        }
        return [
            "        \"\(depotID)\"",
            "        {",
            "            \"manifest\" \"\(depot.manifest)\"",
            "            \"size\"     \"\(depot.size)\"",
            "        }"
        ]
    }
    let lines = [
        "\"AppState\"",
        "{",
        "    \"appid\"        \"\(fingerprint.appID)\"",
        "    \"name\"         \"\(fingerprint.name)\"",
        "    \"installdir\"   \"\(fingerprint.name)\"",
        "    \"SizeOnDisk\"   \"\(fingerprint.totalBytes)\"",
        "    \"buildid\"      \"\(fingerprint.buildID)\"",
        "    \"InstalledDepots\"",
        "    {"
    ] + depotLines + [
        "    }",
        "}"
    ]
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

private func replacingIdentity(
    _ anchor: FingerprintRecord,
    buildID: String,
    manifestID: String,
    files: [FingerprintFileRecord]? = nil
) throws -> FingerprintRecord {
    var depots = anchor.depots
    let anchoredDepot = try #require(depots["1272161"])
    depots["1272161"] = try FingerprintDepotRecord(
        manifest: manifestID,
        size: anchoredDepot.size
    )
    let identity = try FingerprintIdentity(
        appID: anchor.appID,
        name: anchor.name,
        buildID: buildID,
        depots: depots
    )
    return try FingerprintRecord(
        identity: identity,
        files: files ?? anchor.files
    )
}

private func replacingFile(
    in anchor: FingerprintRecord,
    path: String,
    sha256: String
) throws -> FingerprintRecord {
    let files = try anchor.files.map { file in
        guard file.path == path else {
            return file
        }
        return try FingerprintFileRecord(
            path: file.path,
            size: file.size,
            sha256: sha256
        )
    }
    let identity = try FingerprintIdentity(
        appID: anchor.appID,
        name: anchor.name,
        buildID: anchor.buildID,
        depots: anchor.depots
    )
    return try FingerprintRecord(identity: identity, files: files)
}

private func captureUpdateError(
    _ operation: () throws -> Void
) -> (any Error)? {
    do {
        try operation()
        return nil
    } catch {
        return error
    }
}
