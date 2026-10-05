// Author: Timur Isaev
import AlloyProfileCompiler
import AlloyRuntimeAPI
import AlloyStoreCatalog
import Foundation

/// Real requests always execute off the main actor. No service engine is embedded in the app.
public struct ServiceGateway: Sendable {
    public let client: RuntimeClient
    public init(configuration: ServiceConfiguration) { client = RuntimeClient(configuration: configuration) }
    public var namespace: String { client.configuration.serviceName }
    public var allowsFixtures: Bool { client.configuration.fixtureMode == true }

    public func request<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ method: String, _ input: Input, as type: Output.Type
    ) async throws -> Output {
        try await Task.detached { try client.request(method, input, returning: type) }.value
    }

    public func read<Output: Decodable & Sendable>(_ method: String, as type: Output.Type) async throws -> Output {
        try await Task.detached { try client.call(method).decode(type) }.value
    }

    public func observe(cursors: [String: Int]) async throws -> ServiceObservation {
        try await Task.detached {
            let info = try client.info()
            var games: [LibraryGame] = []
            var cursor: String?
            var snapshotID: String?
            var seen = Set<String>()
            repeat {
                let page = try client.listGames(PageQuery(cursor: cursor))
                guard snapshotID == nil || snapshotID == page.snapshotID else { throw ClientServiceError.changedBuild }
                snapshotID = page.snapshotID
                for game in page.games {
                    guard seen.insert(game.gameID).inserted, games.count < 10_000 else {
                        throw ClientServiceError.invalidResponse
                    }
                    games.append(LibraryGame(id: game.gameID, name: game.name, builds: game.buildIDs,
                                             installationIDs: game.installationIDs))
                }
                guard page.nextPageToken == nil || page.nextPageToken != cursor else {
                    throw ClientServiceError.invalidResponse
                }
                cursor = page.nextPageToken
            } while cursor != nil
            let operations = try client.call("operation.list").decode([CatalogOperation].self)
            guard operations.count <= 1_000 else { throw ClientServiceError.invalidResponse }
            let updates = try operations.map { operation in
                try client.updates(OperationCursor(operationID: operation.operationID,
                                                   nextIndex: cursors[operation.operationID] ?? 0))
            }
            return ServiceObservation(info: info, games: games, updates: updates, sessions: try client.sessions())
        }.value
    }

    public func validate(_ recipe: DevelopmentRecipe) async throws -> GameDetails {
        let details = try await request("catalog.get", IdentifierRequest(recipe.install.gameID), as: GameDetails.self)
        guard let installation = details.installations.first(where: {
            $0.installationID == recipe.install.installationID
        }), installation.fingerprint.buildID == recipe.expectedBuildID,
              installation.fingerprint.aggregateSHA256 == recipe.expectedFingerprint else {
            throw ClientServiceError.changedBuild
        }
        let fingerprint = installation.fingerprint
        let expected = BuildIdentity(id: "steam:" + fingerprint.appID + ":" + fingerprint.buildID + ":" +
                                        fingerprint.aggregateSHA256, manifestId: fingerprint.buildID,
                                     files: fingerprint.files.map {
                                         ObservedFile(path: $0.path, sha256: $0.sha256, size: Int(exactly: $0.size))
                                     })
        let profile = try GameProfileValidator.validate(recipe.launch.profile)
        guard try recipe.launch.build.digest() == expected.digest(),
              profile.game.canonicalId == recipe.install.gameID,
              profile.runtime.generation == recipe.install.generationID else { throw ClientServiceError.changedBuild }
        return details
    }
}

public struct ServiceObservation: Sendable {
    public let info: ServiceInfo
    public let games: [LibraryGame]
    public let updates: [OperationUpdate]
    public let sessions: [SessionSnapshot]
}

public enum ClientServiceError: Error {
    case changedBuild, invalidResponse, developmentOnly, noConnection
}

/// Supplied only through --development-fixture; never inferred from discovered game files.
public struct DevelopmentRecipe: Codable, Sendable {
    public let install: InstallPlanRequest
    public let expectedBuildID: String
    public let expectedFingerprint: String
    public let launch: DevelopmentLaunchInput

    public static func read(_ path: String) throws -> Self {
        let url = URL(fileURLWithPath: path)
        let bytes = try PreferencesStore(directory: url.deletingLastPathComponent())
            .readData(name: url.lastPathComponent, maximum: 4 * 1024 * 1024)
        guard let bytes else { throw ClientServiceError.developmentOnly }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard !value.install.baseURLs.isEmpty, value.install.baseURLs.allSatisfy({
            $0.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains($0.host ?? "")
                && $0.user == nil && $0.password == nil
        }) else { throw ClientServiceError.developmentOnly }
        return value
    }
}
