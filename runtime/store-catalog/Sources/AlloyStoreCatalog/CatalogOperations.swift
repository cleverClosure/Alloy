// Author: Timur Isaev
import Foundation

struct DiscoveryRequest: Codable {
    let libraryPaths: [String]
}

struct FingerprintRequest: Codable {
    let libraryPaths: [String]
    let installationID: String
}

extension InstallationEngine {
    public func discoverInstallations(libraryRoots: [URL], idempotencyKey: String) throws -> CatalogOperation {
        let request = DiscoveryRequest(libraryPaths: Set(libraryRoots.map { $0.standardizedFileURL.path }).sorted())
        return try journal.create(kind: .discover, idempotencyKey: idempotencyKey, payload: request)
    }

    public func refreshBuildFingerprint(
        installationID: String, libraryRoots: [URL], idempotencyKey: String
    ) throws -> CatalogOperation {
        let request = FingerprintRequest(libraryPaths: Set(libraryRoots.map { $0.standardizedFileURL.path }).sorted(),
                                         installationID: installationID)
        return try journal.create(kind: .fingerprint, idempotencyKey: idempotencyKey, payload: request)
    }

    func executeDiscovery(_ operation: CatalogOperation) throws -> CatalogOperation {
        let request = try JSONDecoder().decode(DiscoveryRequest.self, from: operation.payload)
        _ = try journal.checkpoint(operation.operationID, stage: "DISCOVERING", controllable: false)
        let catalog = try StoreCatalog(libraryRoots: request.libraryPaths.map { URL(fileURLWithPath: $0) })
        try faultInjector?("DISCOVERING.action-complete")
        return try journal.transition(operation.operationID, to: .succeeded, stage: "SUCCEEDED",
                                      result: StoreCatalog.encode(catalog.discoverInstallations()), controllable: false)
    }

    func executeFingerprint(_ operation: CatalogOperation) throws -> CatalogOperation {
        let request = try JSONDecoder().decode(FingerprintRequest.self, from: operation.payload)
        _ = try journal.checkpoint(operation.operationID, stage: "FINGERPRINTING", controllable: false)
        let catalog = try StoreCatalog(libraryRoots: request.libraryPaths.map { URL(fileURLWithPath: $0) })
        let fingerprint = try catalog.refreshBuildFingerprint(request.installationID)
        try faultInjector?("FINGERPRINTING.action-complete")
        return try journal.transition(operation.operationID, to: .succeeded, stage: "SUCCEEDED",
                                      result: StoreCatalog.encode(fingerprint), controllable: false)
    }
}
