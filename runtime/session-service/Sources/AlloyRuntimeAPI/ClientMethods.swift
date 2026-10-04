// Author: Timur Isaev
import AlloyProfileCompiler
import AlloyStoreCatalog
import Foundation

public enum OperationCommand: String, Sendable {
    case run, pause, resume, cancel
}

extension RuntimeClient {
    public func info() throws -> ServiceInfo { try call("info").decode(ServiceInfo.self) }

    public func host() throws -> HostCapabilities { try call("host.info").decode(HostCapabilities.self) }

    public func game(_ identifier: String) throws -> GameDetails {
        try request("catalog.get", IdentifierRequest(identifier), returning: GameDetails.self)
    }

    public func discoverInstallations() throws -> [GameInstallation] {
        try call("catalog.discover").decode([GameInstallation].self)
    }

    public func controlOperation(_ identifier: String, command: OperationCommand) throws -> CatalogOperation {
        try request("operation." + command.rawValue, IdentifierRequest(identifier), returning: CatalogOperation.self)
    }

    public func resolveLaunch(_ input: DevelopmentLaunchInput) throws -> LaunchPreview {
        try request("launch.resolve", input, returning: LaunchPreview.self)
    }

    public func verifyLaunch(_ identifier: String) throws -> LaunchPreview {
        try request("launch.verify", IdentifierRequest(identifier), returning: LaunchPreview.self)
    }

    public func startFixture(_ input: FixtureStart) throws -> SessionSnapshot {
        try request("fixture.start", input, returning: SessionSnapshot.self)
    }

    public func session(_ identifier: String) throws -> SessionSnapshot {
        try request("session.get", IdentifierRequest(identifier), returning: SessionSnapshot.self)
    }

    public func sessions() throws -> [SessionSnapshot] { try call("session.list").decode([SessionSnapshot].self) }

    public func stopSession(_ identifier: String) throws -> SessionSnapshot {
        try request("session.stop", IdentifierRequest(identifier), returning: SessionSnapshot.self)
    }
}
