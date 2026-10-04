// Author: Timur Isaev

import CryptoKit
import Foundation

public final class ContentStore: @unchecked Sendable {
    public static let lifecycleStages = [
        "download",
        "verify",
        "publish-cas",
        "materialize",
        "prepare-candidate",
        "record-rollback",
        "switch-active",
        "health-window",
        "retain-collect"
    ]

    public static var faultPoints: [String] {
        lifecycleStages.flatMap { ["after-\($0)-action", "after-\($0)"] }
    }

    let root: URL
    let fileManager: FileManager
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    public init(root: URL, allowDamagedCatalog: Bool = false) throws {
        self.root = root.standardizedFileURL
        fileManager = FileManager()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        try createDirectory(self.root)
        try createDirectory(downloadsDirectory)
        try createDirectory(objectsDirectory)
        try createDirectory(quarantineDirectory)
        try createDirectory(generationsDirectory)
        try createDirectory(referencesDirectory)
        try createDirectory(journalsDirectory)
        try createDirectory(volumesDirectory)
        try ensureLockFile()
        try withExclusiveLock {
            try recoverMaintenanceUnlocked()
            if !allowDamagedCatalog {
                _ = try ensureCatalogUnlocked(faultInjector: nil)
            }
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ data: Data) -> String {
        "sha256:\(sha256Hex(data))"
    }

    @discardableResult
    public func activate(
        gameID: String,
        generationID: String,
        layers: [LayerInput],
        operationID requestedOperationID: String? = nil,
        healthOutcome: HealthOutcome = .pass,
        availableBytes: UInt64? = nil,
        faultInjector: FaultInjector? = nil
    ) throws -> GenerationReference {
        try validateIdentifier(gameID)
        try validateIdentifier(generationID)
        try validateLayerInputs(layers)
        if let requestedOperationID {
            try validateIdentifier(requestedOperationID)
        }

        return try withExclusiveLock {
            try recoverMaintenanceUnlocked()
            if let result = try resumeRequestedActivation(
                operationID: requestedOperationID, gameID: gameID, generationID: generationID,
                layers: layers, healthOutcome: healthOutcome, faultInjector: faultInjector
            ) {
                return result
            }
            if requestedOperationID != nil { try requireNoPendingActivation(gameID: gameID) }
            if let availableBytes {
                let plan = try preflightDiskSpaceUnlocked(for: layers.map(\.descriptor))
                try plan.requireFits(availableBytes: availableBytes)
            }
            let operationID = requestedOperationID
                ?? "\(gameID)-\(generationID)-\(UUID().uuidString.lowercased())"
            var operation = ActivationOperation(
                operationID: operationID,
                gameID: gameID,
                generationID: generationID,
                layers: layers.map(\.descriptor),
                healthOutcome: healthOutcome,
                previousActive: try readReference(.active, gameID: gameID)
            )
            try writeJournal(operation)
            try writeDownloads(layers, operation: operation)
            try faultInjector?("after-download-action")
            operation.state = .downloaded
            try writeJournal(operation)
            try faultInjector?("after-download")
            try resume(&operation, faultInjector: faultInjector)
            _ = try synchronizeCatalogUnlocked(faultInjector: faultInjector)

            guard let active = try readReference(.active, gameID: gameID) else {
                throw ContentStoreError.missingReference("active")
            }
            return active
        }
    }

    public func recoverAll(faultInjector: FaultInjector? = nil) throws {
        try withExclusiveLock {
            try recoverAllUnlocked(faultInjector: faultInjector)
            _ = try synchronizeCatalogUnlocked(faultInjector: faultInjector)
        }
    }

    func recoverAllUnlocked(faultInjector: FaultInjector? = nil) throws {
        try recoverMaintenanceUnlocked(faultInjector: faultInjector)
        let journalURLs = try fileManager.contentsOfDirectory(
            at: journalsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }

        for journalURL in journalURLs {
            var operation = try readJournal(journalURL)
            if !operation.state.isTerminal {
                try resume(&operation, faultInjector: faultInjector)
            }
        }
    }

    public func writeSave(gameID: String, name: String, data: Data) throws {
        try validateIdentifier(gameID)
        try validateIdentifier(name)
        try withExclusiveLock {
            let saveDirectory = volumesDirectory
                .appendingPathComponent(gameID, isDirectory: true)
                .appendingPathComponent("saves", isDirectory: true)
            try createDirectory(saveDirectory)
            try writeAtomic(data, to: saveDirectory.appendingPathComponent(name))
        }
    }

    public func readSave(gameID: String, name: String) throws -> Data {
        try validateIdentifier(gameID)
        try validateIdentifier(name)
        return try Data(contentsOf: volumesDirectory
            .appendingPathComponent(gameID, isDirectory: true)
            .appendingPathComponent("saves", isDirectory: true)
            .appendingPathComponent(name))
    }

    public func inspect(gameID: String) throws -> StoreInspection {
        try validateIdentifier(gameID)
        return try withExclusiveLock {
            let journalURLs = try fileManager.contentsOfDirectory(
                at: journalsDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            let incompleteCount = try journalURLs.reduce(into: 0) { count, url in
                if !(try readJournal(url).state.isTerminal) {
                    count += 1
                }
            }
            return StoreInspection(
                active: try readReference(.active, gameID: gameID),
                rollback: try readReference(.rollback, gameID: gameID),
                candidate: try readReference(.candidate, gameID: gameID),
                objectCount: try allObjectURLs().count,
                incompleteOperationCount: incompleteCount
            )
        }
    }

    public func validateReference(_ reference: GenerationReference, gameID: String) throws {
        try validateIdentifier(gameID)
        try validateIdentifier(reference.generationID)
        let directory = generationURL(
            gameID: gameID,
            generationID: reference.generationID
        )
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard isRegularFile(manifestURL) else {
            throw ContentStoreError.incompleteGeneration(reference.generationID)
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let actualManifestDigest = Self.digest(manifestData)
        guard actualManifestDigest == reference.manifestDigest else {
            throw ContentStoreError.digestMismatch(
                expected: reference.manifestDigest,
                actual: actualManifestDigest
            )
        }

        let manifest = try decoder.decode(GenerationManifest.self, from: manifestData)
        guard manifest.schemaVersion == GenerationManifest.currentSchemaVersion else {
            throw ContentStoreError.unsupportedSchema(
                kind: "generation manifest",
                version: manifest.schemaVersion
            )
        }
        guard manifest.gameID == gameID,
              manifest.generationID == reference.generationID,
              !manifest.layers.isEmpty else {
            throw ContentStoreError.incompleteGeneration(reference.generationID)
        }
        for (index, descriptor) in manifest.layers.enumerated() {
            try validateLayerDescriptor(descriptor)
            try validateObject(descriptor)
            try validateMaterializedLayer(
                descriptor,
                index: index,
                generationDirectory: directory
            )
        }
    }
}
