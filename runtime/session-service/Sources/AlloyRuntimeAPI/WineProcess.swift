// Author: Timur Isaev

import AlloyContentStore
import Foundation

/// Session + creation ordinal never aliases a reused Wine/Unix PID.
public struct WineProcess: Codable, Sendable {
    public let identifier: String
    public let winePID: String
    public let parentIdentifier: String?
    public var imagePath: String
    public var unixPID: Int32?
    public var native: LeaseProcessIdentity?
    public var exited: Bool
    public var classification: String
    public var policyID: String?

    public init(identifier: String, winePID: String, parentIdentifier: String?, imagePath: String) {
        self.identifier = identifier
        self.winePID = winePID
        self.parentIdentifier = parentIdentifier
        self.imagePath = imagePath
        exited = false
        classification = "unresolved"
    }
}
