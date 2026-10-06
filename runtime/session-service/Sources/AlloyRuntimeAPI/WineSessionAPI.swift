// Author: Timur Isaev

import AlloyContentStore
import Foundation

/// Source omits host, createdAt and volumes; the service binds those authoritative fields.
public struct SyntheticResolveRequest: Codable, Sendable {
    public let source: Data
    public let entryPath: String
    public let key: String
    public let maximumSeconds: Int

    public init(source: Data, entryPath: String, key: String, maximumSeconds: Int = 120) {
        self.source = source
        self.entryPath = entryPath
        self.key = key
        self.maximumSeconds = maximumSeconds
    }
}

public struct WineCorrelation: Codable, Sendable {
    public let sessionID: String
    public let launchSpecID: String
    public let generationID: String
    public let correlationID: String
    public init(sessionID: String, launchSpecID: String, generationID: String, correlationID: String) {
        self.sessionID = sessionID
        self.launchSpecID = launchSpecID
        self.generationID = generationID
        self.correlationID = correlationID
    }
}

public struct WineSessionEvent: Codable, Sendable {
    public let sequence: Int
    public let kind: String
    public let correlation: WineCorrelation
    public let code: RuntimeCode

    public init(sequence: Int, kind: String, correlation: WineCorrelation, code: RuntimeCode = .ok) {
        self.sequence = sequence
        self.kind = kind
        self.correlation = correlation
        self.code = code
    }
}

public struct WineSessionSnapshot: Codable, Sendable {
    public let driver: String
    public let sessionID: String
    public let preview: LaunchPreview
    public let state: String
    public let code: RuntimeCode
    public let events: [WineSessionEvent]
    public let exitCode: Int32?

    public init(sessionID: String, preview: LaunchPreview, state: String, code: RuntimeCode = .ok,
                events: [WineSessionEvent] = [], exitCode: Int32? = nil) {
        driver = "wine"
        self.sessionID = sessionID
        self.preview = preview
        self.state = state
        self.code = code
        self.events = events
        self.exitCode = exitCode
    }
}
