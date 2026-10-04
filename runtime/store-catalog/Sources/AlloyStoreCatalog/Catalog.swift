// Author: Timur Isaev
import AlloyStoreIdentity
import CryptoKit
import Foundation

public enum CatalogError: Error, Equatable {
    case invalidPage
    case unknownGame(String)
    case unknownInstallation(String)
    case changedInstallation(String)
    case invalidInput(String)
}

public struct GameSummary: Codable, Equatable, Sendable {
    public let gameID: String
    public let name: String
    public let buildIDs: [String]
    public let installationIDs: [String]
}

public struct GameInstallation: Codable, Equatable, Sendable {
    public let installationID: String
    public let libraryPath: String
    public let installPath: String
    public let manifestPath: String
    public let fingerprint: FingerprintRecord
}

public struct GameDetails: Codable, Equatable, Sendable {
    public let summary: GameSummary
    public let installations: [GameInstallation]
}

public struct CatalogPage: Codable, Equatable, Sendable {
    public let snapshotID: String
    public let games: [GameSummary]
    public let nextPageToken: String?
}

/// An immutable, versioned observation of explicitly supplied local libraries.
/// No Steam account, default library search, storefront mutation, or cache writes.
public struct StoreCatalog: Sendable {
    public let snapshotID: String
    public let installations: [GameInstallation]
    private let games: [GameDetails]

    public init(libraryRoots: [URL]) throws {
        let roots = Set(libraryRoots.map { $0.standardizedFileURL.path }).sorted()
        installations = roots.flatMap { Self.scanLibrary(URL(fileURLWithPath: $0)) }
            .sorted { $0.installationID < $1.installationID }
        let grouped = Dictionary(grouping: installations, by: { "steam-" + $0.fingerprint.appID })
        games = grouped.keys.sorted().map { gameID in
            let found = grouped[gameID] ?? []
            return GameDetails(summary: GameSummary(
                gameID: gameID, name: found.first?.fingerprint.name ?? "",
                buildIDs: Set(found.map(\.fingerprint.buildID)).sorted(),
                installationIDs: found.map(\.installationID)
            ), installations: found)
        }
        snapshotID = try Self.digest(Self.encode(installations))
    }

    public func listGames(pageSize: Int = 100, pageToken: String? = nil) throws -> CatalogPage {
        guard (1...1_000).contains(pageSize) else { throw CatalogError.invalidPage }
        var offset = 0
        if let pageToken {
            guard let bytes = Data(base64Encoded: pageToken),
                  let cursor = try? JSONDecoder().decode(Cursor.self, from: bytes),
                  cursor.snapshotID == snapshotID, (0...games.count).contains(cursor.offset)
            else { throw CatalogError.invalidPage }
            offset = cursor.offset
        }
        let end = min(offset + pageSize, games.count)
        let next = end < games.count
            ? try Self.encode(Cursor(snapshotID: snapshotID, offset: end)).base64EncodedString() : nil
        return CatalogPage(snapshotID: snapshotID, games: games[offset..<end].map(\.summary), nextPageToken: next)
    }

    public func getGame(_ gameID: String) throws -> GameDetails {
        guard let game = games.first(where: { $0.summary.gameID == gameID }) else {
            throw CatalogError.unknownGame(gameID)
        }
        return game
    }

    public func discoverInstallations() -> [GameInstallation] { installations }

    public func refreshBuildFingerprint(_ installationID: String) throws -> FingerprintRecord {
        guard let installation = installations.first(where: { $0.installationID == installationID }) else {
            throw CatalogError.unknownInstallation(installationID)
        }
        let manifest = try Self.readManifest(URL(fileURLWithPath: installation.manifestPath))
        guard manifest.appID == installation.fingerprint.appID,
              URL(fileURLWithPath: installation.installPath).lastPathComponent == manifest.installDirectory else {
            throw CatalogError.changedInstallation(installationID)
        }
        let fingerprint = try FingerprintScanner.scan(
            installRoot: URL(fileURLWithPath: installation.installPath), identity: manifest.fingerprintIdentity())
        guard try Self.readManifest(URL(fileURLWithPath: installation.manifestPath)) == manifest else {
            throw CatalogError.changedInstallation(installationID)
        }
        return fingerprint
    }

    private static func scanLibrary(_ root: URL) -> [GameInstallation] {
        let steamapps = root.appendingPathComponent("steamapps")
        let common = steamapps.appendingPathComponent("common")
        guard realDirectory(root), realDirectory(steamapps), realDirectory(common),
              let files = try? FileManager.default.contentsOfDirectory(
                at: steamapps, includingPropertiesForKeys: nil) else { return [] }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            guard file.lastPathComponent.hasPrefix("appmanifest_"), file.pathExtension == "acf" else { return nil }
            do {
                let manifest = try readManifest(file)
                guard file.lastPathComponent == "appmanifest_\(manifest.appID).acf",
                      safeComponent(manifest.installDirectory) else { return nil }
                let install = common.appendingPathComponent(manifest.installDirectory)
                guard realDirectory(install) else { return nil }
                let fingerprint = try FingerprintScanner.scan(
                    installRoot: install, identity: manifest.fingerprintIdentity())
                guard try readManifest(file) == manifest else { return nil }
                return GameInstallation(
                    installationID: "install-" + digest(Data(install.path.utf8)),
                    libraryPath: root.path, installPath: install.path,
                    manifestPath: file.path, fingerprint: fingerprint)
            } catch { return nil }
        }
    }

    private static func readManifest(_ file: URL) throws -> SteamAppManifest {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= SteamMetadataParser.maximumInputBytes else {
            throw CatalogError.invalidInput(file.path)
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: SteamMetadataParser.maximumInputBytes + 1) ?? Data()
        return try SteamMetadataParser.parse(data: bytes, sourceName: file.lastPathComponent)
    }

    private static func realDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
            && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private struct Cursor: Codable {
        let snapshotID: String
        let offset: Int
    }
}
