// Author: Timur Isaev

import Foundation

enum ReferenceKind: String {
    case active
    case rollback
    case candidate
}

extension RuntimeStore {
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
        gameID: String
    ) throws -> GenerationReference? {
        let url = referenceURL(kind, gameID: gameID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let reference = try decoder.decode(GenerationReference.self, from: Data(contentsOf: url))
        try validateReference(reference, gameID: gameID)
        return reference
    }

    func removeReference(_ kind: ReferenceKind, gameID: String) throws {
        let url = referenceURL(kind, gameID: gameID)
        guard fileManager.fileExists(atPath: url.path) else {
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
        do {
            return try decoder.decode(ActivationOperation.self, from: Data(contentsOf: url))
        } catch {
            throw RuntimeStoreError.invalidJournal(url.deletingPathExtension().lastPathComponent)
        }
    }
}
