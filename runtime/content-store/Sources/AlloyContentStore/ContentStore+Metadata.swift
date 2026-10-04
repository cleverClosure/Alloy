// Author: Timur Isaev

import Foundation

enum ReferenceKind: String, CaseIterable {
    case active
    case rollback
    case candidate
}

extension ContentStore {
    func writeReference(
        _ reference: GenerationReference,
        kind: ReferenceKind,
        gameID: String
    ) throws {
        try validateReference(reference, gameID: gameID)
        try writeAtomic(encoder.encode(reference), to: referenceURL(kind, gameID: gameID))
    }

    func readReference(
        _ kind: ReferenceKind,
        gameID: String,
        validateContents: Bool = true
    ) throws -> GenerationReference? {
        let url = referenceURL(kind, gameID: gameID)
        guard pathEntryExists(url) else {
            return nil
        }
        guard isRegularFile(url) else {
            throw ContentStoreError.missingReference(kind.rawValue)
        }
        let reference = try decoder.decode(
            GenerationReference.self,
            from: Data(contentsOf: url)
        )
        try validateIdentifier(reference.generationID)
        _ = try rawSHA256(reference.manifestDigest)
        if validateContents { try validateReference(reference, gameID: gameID) }
        return reference
    }

    func removeReference(_ kind: ReferenceKind, gameID: String) throws {
        let url = referenceURL(kind, gameID: gameID)
        guard pathEntryExists(url) else {
            return
        }
        try fileManager.removeItem(at: url)
        try syncDirectory(url.deletingLastPathComponent())
    }

    func referenceURL(_ kind: ReferenceKind, gameID: String) -> URL {
        referencesDirectory
            .appendingPathComponent(gameID, isDirectory: true)
            .appendingPathComponent("\(kind.rawValue).json")
    }

    func writeJournal(_ operation: ActivationOperation) throws {
        try writeAtomic(encoder.encode(operation), to: journalURL(operation.operationID))
    }

    func readJournal(_ url: URL) throws -> ActivationOperation {
        guard isRegularFile(url) else {
            throw ContentStoreError.invalidJournal(url.deletingPathExtension().lastPathComponent)
        }
        let operation: ActivationOperation
        do {
            operation = try decoder.decode(
                ActivationOperation.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw ContentStoreError.invalidJournal(url.deletingPathExtension().lastPathComponent)
        }

        guard operation.schemaVersion == ActivationOperation.currentSchemaVersion else {
            throw ContentStoreError.unsupportedSchema(
                kind: "activation journal",
                version: operation.schemaVersion
            )
        }
        guard operation.kind == ActivationOperation.kind,
              !operation.layers.isEmpty else {
            throw ContentStoreError.invalidJournal(operation.operationID)
        }
        try validateIdentifier(operation.operationID)
        try validateIdentifier(operation.gameID)
        try validateIdentifier(operation.generationID)
        for descriptor in operation.layers {
            try validateLayerDescriptor(descriptor)
        }
        return operation
    }
}
