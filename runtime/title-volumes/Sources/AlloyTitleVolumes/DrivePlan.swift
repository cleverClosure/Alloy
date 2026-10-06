// Author: Timur Isaev

import Foundation

public enum DriveAccess: String, Codable, Sendable {
    case readOnly, readWrite, updaterScoped
}

public struct DriveBinding: Codable, Equatable, Sendable {
    public let relativePath: String
    public let volumeID: String
    public let access: DriveAccess
}

public struct DriveMapping: Codable, Equatable, Sendable {
    public let letter: String
    public let bindings: [DriveBinding]
}

public struct SessionVolumeRequest: Sendable {
    public let gameID: String
    public let sessionID: String
    public let runtimeVolumeID: String
    public let payloadVolumeID: String
    public let payloadAccess: DriveAccess

    public init(gameID: String, sessionID: String, runtimeVolumeID: String, payloadVolumeID: String,
                payloadAccess: DriveAccess = .readOnly) {
        self.gameID = gameID
        self.sessionID = sessionID
        self.runtimeVolumeID = runtimeVolumeID
        self.payloadVolumeID = payloadVolumeID
        self.payloadAccess = payloadAccess
    }
}

public struct DriveMappingPlan: Codable, Equatable, Sendable {
    public let gameID: String
    public let sessionID: String
    public let volumeIDs: [String: String]
    public let drives: [DriveMapping]
    public let saveRedirections: [SavePathBinding]
    public let hostRootMapped: Bool
}

extension TitleVolumeStore {
    /// Returns a broker plan with opaque IDs; it does not grant access or mount host paths.
    public func drivePlan(_ request: SessionVolumeRequest, expectedCacheIdentity: CacheIdentity,
                          now: Int64) throws -> DriveMappingPlan {
        try identifier(request.runtimeVolumeID)
        try identifier(request.payloadVolumeID)
        guard now >= 0, request.payloadAccess != .readWrite else { throw VolumeError.invalidPolicy }
        return try locked {
            let registry = try loadRegistry()
            let saves = try resolve(request.gameID, .saves, nil, in: registry)
            let settings = try resolve(request.gameID, .settings, nil, in: registry)
            let scratch = try resolve(request.gameID, .scratch, request.sessionID, in: registry)
            guard (scratch.expiresAt ?? 0) > now,
                  let cache = try activeCacheUnlocked(request.gameID) else { throw VolumeError.unknownVolume }
            guard cache.identity == expectedCacheIdentity else { throw VolumeError.conflict }
            for record in [saves, settings, scratch, cache.volume] {
                _ = try directory(record).inventory(limit: record.quota)
            }
            let ids = ["runtime": request.runtimeVolumeID, "game": request.payloadVolumeID,
                       "saves": saves.id, "settings": settings.id, "cache": cache.volume.id, "temp": scratch.id]
            guard Set(ids.values).count == 6 else { throw VolumeError.unsafePath }
            let drives = [
                DriveMapping(letter: "C", bindings: [DriveBinding(relativePath: "", volumeID: request.runtimeVolumeID,
                                                                 access: .readOnly)]),
                DriveMapping(letter: "G", bindings: [DriveBinding(relativePath: "", volumeID: request.payloadVolumeID,
                                                                 access: request.payloadAccess)]),
                DriveMapping(letter: "S", bindings: [
                    DriveBinding(relativePath: "saves", volumeID: saves.id, access: .readWrite),
                    DriveBinding(relativePath: "settings", volumeID: settings.id, access: .readWrite)
                ]),
                DriveMapping(letter: "T", bindings: [DriveBinding(relativePath: "", volumeID: scratch.id,
                                                                 access: .readWrite)])
            ]
            return DriveMappingPlan(gameID: request.gameID, sessionID: request.sessionID, volumeIDs: ids,
                                    drives: drives,
                                    saveRedirections: try savePathsUnlocked(request.gameID)?.bindings ?? [],
                                    hostRootMapped: false)
        }
    }
}
