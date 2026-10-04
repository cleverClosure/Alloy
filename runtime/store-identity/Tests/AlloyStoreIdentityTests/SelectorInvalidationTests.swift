// Author: Timur Isaev

import CryptoKit
import Foundation
import Testing
import AlloyStoreIdentity

@Suite("Selector registry and invalidation")
struct SelectorInvalidationTests {
    @Test("exact registry evidence emits one canonical idempotent invalidation")
    func exactRegistryAndIdempotentEmission() throws {
        let loaded = try loadSelectorRegistry()
        try checkRegistryContract(loaded)
        let anchor = try loadSelectorAnchor()
        let unchanged = try stagedSelectorObservation(for: anchor)
        let changed = try combinedSelectorObservation(anchor)
        try withSelectorOutputRoot("idempotent") { root in
            let store = InvalidationStore(root: root)
            try requireUnchangedSelectorControl(
                store: store,
                anchor: anchor,
                observation: unchanged,
                registry: loaded.registry,
                root: root
            )
            let first = try #require(try store.emit(
                anchor: anchor,
                observation: changed,
                registry: loaded.registry
            ))
            #expect(first.created)
            let firstBytes = try Data(contentsOf: first.url)
            let filesAfterFirst = try invalidationJSONFiles(in: root)
            #expect(filesAfterFirst == [first.url.standardizedFileURL])
            let second = try #require(try store.emit(
                anchor: anchor,
                observation: changed,
                registry: loaded.registry
            ))
            #expect(!second.created)
            #expect(second.record == first.record)
            #expect(second.record.invalidationID == first.record.invalidationID)
            #expect(second.url.standardizedFileURL == first.url.standardizedFileURL)
            #expect(try Data(contentsOf: second.url) == firstBytes)
            #expect(try invalidationJSONFiles(in: root).count == 1)
            let decoded = try JSONDecoder().decode(
                InvalidationRecord.self,
                from: firstBytes
            )
            #expect(decoded == first.record)
            #expect(decoded.superseded.buildID == selectorBuildID)
            #expect(decoded.selectorIDs == expectedSelectorIDs)
            #expect(try canonicalJSON(decoded) == firstBytes)
            #expect(hasExactlyOneTrailingLineFeed(firstBytes))
        }
    }

    @Test("changed observation with no exact selector match is refused")
    func selectorMismatchIsRefused() throws {
        let loaded = try loadSelectorRegistry()
        let registry = try registryWithoutExactBuild(from: loaded.data)
        let anchor = try loadSelectorAnchor()
        let unchanged = try stagedSelectorObservation(for: anchor)
        let changed = try combinedSelectorObservation(anchor)
        try withSelectorOutputRoot("mismatch") { root in
            let store = InvalidationStore(root: root)
            try requireUnchangedSelectorControl(
                store: store,
                anchor: anchor,
                observation: unchanged,
                registry: registry,
                root: root
            )
            let error = captureSelectorError {
                _ = try store.emit(
                    anchor: anchor,
                    observation: changed,
                    registry: registry
                )
            }
            #expect(error != nil)
            #expect(try directoryIsEmpty(root))
        }
    }

    @Test("conflicting existing invalidation is refused without overwrite")
    func corruptExistingTargetIsRefused() throws {
        let loaded = try loadSelectorRegistry()
        let anchor = try loadSelectorAnchor()
        let unchanged = try stagedSelectorObservation(for: anchor)
        let changed = try combinedSelectorObservation(anchor)
        try withSelectorOutputRoot("corrupt-target") { root in
            let store = InvalidationStore(root: root)
            try requireUnchangedSelectorControl(
                store: store,
                anchor: anchor,
                observation: unchanged,
                registry: loaded.registry,
                root: root
            )
            let first = try #require(try store.emit(
                anchor: anchor,
                observation: changed,
                registry: loaded.registry
            ))
            let corrupt = Data("{\"corrupt\":true}\n".utf8)
            try corrupt.write(to: first.url, options: .atomic)

            let error = captureSelectorError {
                _ = try store.emit(
                    anchor: anchor,
                    observation: changed,
                    registry: loaded.registry
                )
            }
            #expect(error != nil)
            #expect(try Data(contentsOf: first.url) == corrupt)
            #expect(try invalidationJSONFiles(in: root).count == 1)
        }
    }
}

private struct LoadedSelectorRegistry {
    let data: Data
    let object: [String: Any]
    let registry: SelectorRegistry
}

private struct ExpectedSelector {
    let kind: String
    let path: String
    let sha256: String
    let imageHashes: [String: String]
}

private let selectorRepositoryRoot = URL(
    fileURLWithPath: #filePath,
    isDirectory: false
)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let selectorRegistryURL = selectorRepositoryRoot.appendingPathComponent(
    "runtime/store-identity/Registry/selectors.v1.json",
    isDirectory: false
)

private let selectorAnchorURL = selectorRepositoryRoot.appendingPathComponent(
    "spikes/STORE-001/results/fingerprint-1272160-first.json",
    isDirectory: false
)

private let selectorBuildID = "24280929"
private let selectorExecutable = "The Life and Suffering of Sir Brante.exe"
private let selectorExecutableSHA256 =
    "1fb707b113f25388a6dacdd81140bf2205f4fe93c71e83d3169e58ab98f95455"
private let selectorAggregateSHA256 =
    "1563163e7bdbd3d54566845f45b0406c02a10e0f66c6a97ba4e55bc1f56be88e"

private let expectedSelectorIDs = [
    "gfx-001.result-06.1272160.24280929",
    "store-001.fingerprint.1272160.24280929",
    "store-001.launch-policy.sir-brante-24280929"
]

private let expectedSelectors: [String: ExpectedSelector] = [
    "gfx-001.result-06.1272160.24280929": ExpectedSelector(
        kind: "scene-measurement",
        path: "spikes/GFX-001/results/2026-07-25-06-sir-brante-title-scene.md",
        sha256: "aa1a853eac5661694e1d08d16a4a543821c03c9e53b916fa18b5fe42802a5001",
        imageHashes: [selectorExecutable: selectorExecutableSHA256]
    ),
    "store-001.fingerprint.1272160.24280929": ExpectedSelector(
        kind: "fingerprint",
        path: "spikes/STORE-001/results/fingerprint-1272160-first.json",
        sha256: "5c6b43999284b699461fb64e916b21eb17d0ea9067460bac51c1e2c269dadc5a",
        imageHashes: [selectorExecutable: selectorExecutableSHA256]
    ),
    "store-001.launch-policy.sir-brante-24280929": ExpectedSelector(
        kind: "launch-policy",
        path: "spikes/STORE-001/runtime-launch/launch-sir-brante.sh",
        sha256: "ac203ae4bdc3bdc7915aff16416abf5fd275bc38adedcee8916aa5538bf6ea4d",
        imageHashes: [
            selectorExecutable: selectorExecutableSHA256,
            "executableSHA256": selectorExecutableSHA256,
            "processPolicies[].imageSHA256": selectorExecutableSHA256
        ]
    )
]

private func loadSelectorRegistry() throws -> LoadedSelectorRegistry {
    let data = try Data(contentsOf: selectorRegistryURL)
    let value = try JSONSerialization.jsonObject(with: data)
    let object = try #require(value as? [String: Any])
    let registry = try JSONDecoder().decode(SelectorRegistry.self, from: data)
    return LoadedSelectorRegistry(
        data: data,
        object: object,
        registry: registry
    )
}

private func checkRegistryContract(
    _ loaded: LoadedSelectorRegistry
) throws {
    #expect(Set(loaded.object.keys) == [
        "author", "record", "selectors", "version"
    ])
    #expect(loaded.object["author"] as? String == "Timur Isaev")
    #expect(loaded.object["version"] as? Int == 1)
    let rawSelectors = try #require(
        loaded.object["selectors"] as? [[String: Any]]
    )
    #expect(rawSelectors.count == 3)

    let selectors = loaded.registry.selectors
    #expect(selectors.map(\.selectorID) == expectedSelectorIDs)
    for selector in selectors {
        let expected = try #require(expectedSelectors[selector.selectorID])
        #expect(selector.artifact.kind == expected.kind)
        #expect(selector.artifact.path == expected.path)
        #expect(selector.artifact.sha256 == expected.sha256)
        #expect(selector.storefront == "steam")
        #expect(selector.gameID == "1272160")
        #expect(selector.storeBuildID == selectorBuildID)
        #expect(selector.manifestIDs == [
            "1272161": "3716404947812214693"
        ])
        #expect(selector.aggregateSHA256 == selectorAggregateSHA256)
        #expect(selector.imageHashes == expected.imageHashes)
        let artifactURL = selectorRepositoryRoot.appendingPathComponent(
            selector.artifact.path,
            isDirectory: false
        )
        #expect(try sha256(of: artifactURL) == expected.sha256)
    }

    try checkStrictSelectorShape(rawSelectors)
    let canonical = try loaded.registry.canonicalJSON()
    #expect(canonical == loaded.data)
    let roundTrip = try SelectorRegistry.decode(canonical)
    #expect(roundTrip == loaded.registry)

    var unknownFieldObject = loaded.object
    unknownFieldObject["unexpected"] = true
    let strictError = captureSelectorError {
        _ = try SelectorRegistry.decode(
            JSONSerialization.data(withJSONObject: unknownFieldObject)
        )
    }
    #expect(strictError != nil)
}

private func checkStrictSelectorShape(
    _ selectors: [[String: Any]]
) throws {
    let selectorKeys: Set<String> = [
        "aggregate_sha256", "artifact", "game_id", "image_hashes",
        "manifest_ids", "selector_id", "store_build_id", "storefront"
    ]
    for selector in selectors {
        #expect(Set(selector.keys) == selectorKeys)
        let artifact = try #require(selector["artifact"] as? [String: Any])
        #expect(Set(artifact.keys) == ["kind", "path", "sha256"])
    }
}

private func loadSelectorAnchor() throws -> FingerprintRecord {
    try JSONDecoder().decode(
        FingerprintRecord.self,
        from: Data(contentsOf: selectorAnchorURL)
    )
}

private func combinedSelectorObservation(
    _ anchor: FingerprintRecord
) throws -> UpdateObservation {
    let removedPath = "MonoBleedingEdge/EmbedRuntime/MonoPosixHelper.dll"
    var files = try anchor.files.compactMap { file -> FingerprintFileRecord? in
        if file.path == removedPath {
            return nil
        }
        if file.path == selectorExecutable {
            return try FingerprintFileRecord(
                path: file.path,
                size: file.size,
                sha256: String(repeating: "b", count: 64)
            )
        }
        return file
    }
    files.append(try FingerprintFileRecord(
        path: "zz-alloy-selector-added.bin",
        size: 17,
        sha256: String(repeating: "c", count: 64)
    ))

    var depots = anchor.depots
    let depot = try #require(depots["1272161"])
    depots["1272161"] = try FingerprintDepotRecord(
        manifest: "3716404947812214695",
        size: depot.size
    )
    let identity = try FingerprintIdentity(
        appID: anchor.appID,
        name: anchor.name,
        buildID: "24280931",
        depots: depots
    )
    return try stagedSelectorObservation(
        for: FingerprintRecord(identity: identity, files: files)
    )
}

private func stagedSelectorObservation(
    for fingerprint: FingerprintRecord
) throws -> UpdateObservation {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-selector-observation-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let fingerprintURL = root.appendingPathComponent("fingerprint.json")
    let manifestURL = root.appendingPathComponent("appmanifest.acf")
    try fingerprint.canonicalJSON().write(to: fingerprintURL)
    try selectorManifestData(for: fingerprint).write(to: manifestURL)
    let stagedFingerprint = try JSONDecoder().decode(
        FingerprintRecord.self,
        from: Data(contentsOf: fingerprintURL)
    )
    let metadata = try SteamMetadataParser.parse(
        data: Data(contentsOf: manifestURL),
        sourceName: manifestURL.lastPathComponent
    )
    return UpdateObservation(
        metadata: metadata,
        fingerprint: stagedFingerprint
    )
}

private func selectorManifestData(
    for fingerprint: FingerprintRecord
) -> Data {
    let depots = fingerprint.depots.keys.sorted().flatMap { depotID -> [String] in
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
        "    \"appid\"       \"\(fingerprint.appID)\"",
        "    \"name\"        \"\(fingerprint.name)\"",
        "    \"installdir\"  \"\(fingerprint.name)\"",
        "    \"SizeOnDisk\"  \"\(fingerprint.totalBytes)\"",
        "    \"buildid\"     \"\(fingerprint.buildID)\"",
        "    \"InstalledDepots\"",
        "    {"
    ] + depots + ["    }", "}"]
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

private func requireUnchangedSelectorControl(
    store: InvalidationStore,
    anchor: FingerprintRecord,
    observation: UpdateObservation,
    registry: SelectorRegistry,
    root: URL
) throws {
    let emission = try store.emit(
        anchor: anchor,
        observation: observation,
        registry: registry
    )
    #expect(emission == nil)
    #expect(try directoryIsEmpty(root))
}

private func registryWithoutExactBuild(
    from data: Data
) throws -> SelectorRegistry {
    let value = try JSONSerialization.jsonObject(with: data)
    var root = try #require(value as? [String: Any])
    var selectors = try #require(root["selectors"] as? [[String: Any]])
    for index in selectors.indices {
        selectors[index]["store_build_id"] = "24280928"
    }
    root["selectors"] = selectors
    return try JSONDecoder().decode(
        SelectorRegistry.self,
        from: JSONSerialization.data(withJSONObject: root)
    )
}

private func withSelectorOutputRoot(
    _ label: String,
    operation: (URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-selector-\(label)-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try operation(root)
}

private func directoryIsEmpty(_ root: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    ).isEmpty
}

private func invalidationJSONFiles(in root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        return []
    }
    return try enumerator.compactMap { item -> URL? in
        guard let url = item as? URL,
            url.pathExtension == "json",
            try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else {
            return nil
        }
        return url.standardizedFileURL
    }
        .sorted { $0.path < $1.path }
}

private func sha256(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func canonicalJSON<Value: Encodable>(
    _ value: Value
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}

private func hasExactlyOneTrailingLineFeed(_ data: Data) -> Bool {
    guard data.last == 0x0A else {
        return false
    }
    return data.count == 1 || data[data.count - 2] != 0x0A
}

private func captureSelectorError(
    _ operation: () throws -> Void
) -> (any Error)? {
    do {
        try operation()
        return nil
    } catch {
        return error
    }
}
