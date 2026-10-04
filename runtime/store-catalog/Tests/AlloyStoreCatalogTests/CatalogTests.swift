// Author: Timur Isaev
import AlloyStoreCatalog
import Foundation
import Testing

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let identityRoot = packageRoot.deletingLastPathComponent().appendingPathComponent("store-identity")

@Test func exactMultiGameCatalogAndPagination() throws {
    let library = packageRoot.appendingPathComponent("Tests/Fixtures/MultiGameLibrary")
    let catalog = try StoreCatalog(libraryRoots: [library, library])
    let first = try catalog.listGames(pageSize: 1)
    #expect(first.games.map(\.gameID) == ["steam-910001"])
    let second = try catalog.listGames(pageSize: 1, pageToken: #require(first.nextPageToken))
    #expect(second.games.map(\.gameID) == ["steam-910002"])
    #expect(second.nextPageToken == nil)
    #expect(try catalog.getGame("steam-910001").summary.buildIDs == ["21"])
    #expect(try catalog.getGame("steam-910002").summary.buildIDs == ["42"])
    #expect(throws: CatalogError.self) { try catalog.getGame("missing") }
    #expect(throws: CatalogError.self) { try catalog.listGames(pageToken: "bad") }
    #expect(throws: CatalogError.self) { try catalog.listGames(pageSize: 0) }
    let empty = try StoreCatalog(libraryRoots: [])
    #expect(throws: CatalogError.self) { try empty.listGames(pageToken: first.nextPageToken) }
}

@Test func emptyAndHostileLibrariesHaveNoPhantoms() throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: scratch) }
    #expect(try StoreCatalog(libraryRoots: [scratch]).listGames().games.isEmpty)
    let common = scratch.appendingPathComponent("steamapps/common")
    try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
    #expect(try StoreCatalog(libraryRoots: [scratch]).listGames().games.isEmpty)
    let fixtures = identityRoot.appendingPathComponent("Tests/Fixtures/SteamMetadata")
    for file in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil) {
        if file.lastPathComponent == "clean-appmanifest.acf" { continue }
        try FileManager.default.copyItem(at: file, to: common.deletingLastPathComponent()
            .appendingPathComponent("appmanifest_\(UUID().uuidString).acf"))
    }
    #expect(try StoreCatalog(libraryRoots: [scratch]).listGames().games.isEmpty)
}

@Test func knownFingerprintAndRefreshAreExact() throws {
    let root = identityRoot.appendingPathComponent("Tests/Fixtures/SyntheticSteamLibrary")
    let catalog = try StoreCatalog(libraryRoots: [root])
    let installation = try #require(catalog.discoverInstallations().first)
    let refreshed = try catalog.refreshBuildFingerprint(installation.installationID)
    #expect(refreshed == installation.fingerprint)
    #expect(refreshed.aggregateSHA256 == "94f9ae3d556e33fcd4f7acfaa36e25521e3542e71e3c67ffa1004adadb6d2d1e")
    #expect(refreshed.fileCount == 6)
    #expect(refreshed.totalBytes == 346)
}

@Test func fingerprintMatchesExistingCLIBytes() throws {
    let root = identityRoot.appendingPathComponent("Tests/Fixtures/SyntheticSteamLibrary")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let output = scratch.appendingPathComponent("fingerprint.json")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/steam-fingerprint.py").path,
        root.path, "--app", "900000", "--out", output.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let catalog = try StoreCatalog(libraryRoots: [root])
    let installation = try #require(catalog.discoverInstallations().first)
    let actual = try catalog.refreshBuildFingerprint(installation.installationID)
    let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? NSDictionary
    let value = try JSONSerialization.jsonObject(with: actual.canonicalJSON()) as? NSDictionary
    #expect(reference == value)
    #expect(reference?["aggregate_sha256"] as? String == actual.aggregateSHA256)
}
