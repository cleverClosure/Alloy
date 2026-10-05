// Author: Timur Isaev
import Foundation

public enum ClientSection: String, CaseIterable, Codable, Sendable, Identifiable {
    case library, activity, diagnostics, settings
    public var id: Self { self }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .library: "square.grid.2x2"
        case .activity: "arrow.down.circle"
        case .diagnostics: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
}

public enum ClientAppearance: String, CaseIterable, Codable, Sendable {
    case system, light, dark
}

public struct ClientPreferences: Codable, Equatable, Sendable {
    public var section: ClientSection = .library
    public var selectedGameID: String?
    public var appearance: ClientAppearance = .system
    public var reduceMotion = false
    public init() {}
}

public enum LibraryPhase: String, Codable, Sendable {
    case loading, empty, available, unsupported, failed, disconnected
}

public struct ClientProblem: Codable, Equatable, Sendable {
    public let title: String
    public let explanation: String
    public let nextStep: String
    public let supportCode: String
    public init(title: String, explanation: String, nextStep: String, supportCode: String) {
        self.title = title
        self.explanation = explanation
        self.nextStep = nextStep
        self.supportCode = supportCode
    }
}

public struct LibraryGame: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let builds: [String]
    public let installationIDs: [String]
    public let unsupportedReason: String?
    public var status: String { unsupportedReason == nil ? "Untested" : "Unsupported" }
    public init(id: String, name: String, builds: [String], installationIDs: [String],
                unsupportedReason: String? = nil) {
        self.id = id
        self.name = name
        self.builds = builds
        self.installationIDs = installationIDs
        self.unsupportedReason = unsupportedReason
    }
}

public struct ClientActivity: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let detail: String
    public let progress: Double?
    public init(id: String, title: String, state: String, detail: String, progress: Double? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.progress = progress
    }
}

public struct ClientSnapshot: Equatable, Sendable {
    public var phase: LibraryPhase = .disconnected
    public var games: [LibraryGame] = []
    public var activities: [ClientActivity] = []
    public var problem: ClientProblem?
    public var preview = false
    public var connected = false
    public var serviceDescription = "Not connected"
    public init() {}

    public static func fixture(_ phase: LibraryPhase) -> Self {
        var value = Self()
        value.preview = true
        value.phase = phase
        value.connected = phase != .disconnected
        value.serviceDescription = "Interface preview · no service connection"
        if phase == .available || phase == .unsupported {
            value.games = [
                LibraryGame(id: "steam:910001", name: "Atlas (synthetic)", builds: ["21"],
                            installationIDs: ["preview-atlas"],
                            unsupportedReason: phase == .unsupported ?
                                "This preview models an unavailable runtime." : nil),
                LibraryGame(id: "steam:910002", name: "Boreal (synthetic)", builds: ["13"],
                            installationIDs: ["preview-boreal"])
            ]
        }
        if phase == .failed {
            value.problem = ClientProblem(title: "Library could not be read",
                                          explanation: "The preview models a discovery failure.",
                                          nextStep: "Reconnect to the local service, then refresh the library.",
                                          supportCode: "CLIENT-PREVIEW-DISCOVERY")
        }
        return value
    }
}
