// Author: Timur Isaev

import CryptoKit
import Foundation

public final class RuntimeStore: @unchecked Sendable {
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

    public init(root: URL) throws {
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
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public func activate(
        gameID: String,
        generationID: String,
        payload: Data,
        expectedSHA256: String? = nil,
        healthOutcome: HealthOutcome = .pass,
        faultInjector: FaultInjector? = nil
    ) throws -> GenerationReference {
        try validateIdentifier(gameID)
        try validateIdentifier(generationID)

        return try withExclusiveLock {
            let digest = expectedSHA256 ?? Self.sha256(payload)
            let operationID = "\(gameID)-\(generationID)-\(UUID().uuidString.lowercased())"
            var operation = ActivationOperation(
                operationID: operationID,
                gameID: gameID,
                generationID: generationID,
                expectedObjectSHA256: digest,
                healthOutcome: healthOutcome,
                previousActive: try readReference(.active, gameID: gameID)
            )
            try writeJournal(operation)
            try writeDownload(payload, operation: operation)
            try faultInjector?("after-download-action")
            operation.state = .downloaded
            try writeJournal(operation)
            try faultInjector?("after-download")
            try resume(&operation, faultInjector: faultInjector)

            guard let active = try readReference(.active, gameID: gameID) else {
                throw RuntimeStoreError.missingReference("active")
            }
            return active
        }
    }

    public func recoverAll(faultInjector: FaultInjector? = nil) throws {
        try withExclusiveLock {
            let journalURLs = try fileManager.contentsOfDirectory(
                at: journalsDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            for journalURL in journalURLs {
                var operation = try readJournal(journalURL)
                if !operation.state.isTerminal {
                    try resume(&operation, faultInjector: faultInjector)
                }
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
        let manifestURL = generationURL(
            gameID: gameID,
            generationID: reference.generationID
        ).appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw RuntimeStoreError.incompleteGeneration(reference.generationID)
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let actualManifestDigest = Self.sha256(manifestData)
        guard actualManifestDigest == reference.manifestSHA256 else {
            throw RuntimeStoreError.digestMismatch(
                expected: reference.manifestSHA256,
                actual: actualManifestDigest
            )
        }

        let manifest = try decoder.decode(GenerationManifest.self, from: manifestData)
        guard manifest.gameID == gameID, manifest.generationID == reference.generationID else {
            throw RuntimeStoreError.incompleteGeneration(reference.generationID)
        }
        for digest in manifest.objectSHA256 {
            try validateObject(digest)
        }
    }
}
