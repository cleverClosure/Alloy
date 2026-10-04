// Author: Timur Isaev
import AlloyRuntimeAPI
import AlloyStoreCatalog
import Foundation

/// Development inspection commands also exercise the public consumer API from
/// this separate-process target, which never imports the service implementation.
enum TypedCommands {
    private struct SnapshotInput: Decodable {
        let cursor: OperationCursor
        let sessionID: String
        let previewID: String
    }

    private struct Snapshot: Encodable {
        let info: ServiceInfo
        let catalog: CatalogPage
        let operation: OperationUpdate
        let preview: LaunchPreview
        let session: SessionSnapshot
    }

    static func run(_ method: String, client: RuntimeClient) throws -> Bool {
        guard ["typed-preview", "typed-fixture-start", "typed-session-stop", "typed-snapshot"].contains(method) else {
            return false
        }
        let bytes = FileHandle.standardInput.readData(ofLength: RuntimeLimits.messageBytes + 1)
        guard bytes.count <= RuntimeLimits.messageBytes else { throw RuntimeFailure.status(.oversized) }
        let decoder = JSONDecoder()
        let result: Data
        switch method {
        case "typed-preview":
            let input = try decoder.decode(DevelopmentLaunchInput.self, from: bytes)
            result = try RuntimeEncoding.encode(client.resolveLaunch(input))
        case "typed-fixture-start":
            result = try RuntimeEncoding.encode(client.startFixture(decoder.decode(FixtureStart.self, from: bytes)))
        case "typed-session-stop":
            let input = try decoder.decode(IdentifierRequest.self, from: bytes)
            result = try RuntimeEncoding.encode(client.stopSession(input.identifier))
        default:
            let input = try decoder.decode(SnapshotInput.self, from: bytes)
            let snapshot = try Snapshot(info: client.info(), catalog: client.listGames(),
                                         operation: client.updates(input.cursor),
                                         preview: client.verifyLaunch(input.previewID),
                                         session: client.session(input.sessionID))
            result = try RuntimeEncoding.encode(snapshot)
        }
        FileHandle.standardOutput.write(result)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return true
    }
}
