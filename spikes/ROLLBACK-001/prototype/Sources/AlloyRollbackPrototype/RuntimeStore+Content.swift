// Author: Timur Isaev

import Darwin
import Foundation

extension RuntimeStore {
    func writeDownload(_ payload: Data, operation: ActivationOperation) throws {
        try writeDurable(payload, to: downloadURL(operation), exclusive: true)
    }

    func verifyDownload(_ operation: ActivationOperation) throws {
        let url = downloadURL(operation)
        guard fileManager.fileExists(atPath: url.path) else {
            if fileManager.fileExists(atPath: objectURL(operation.expectedObjectSHA256).path) {
                try validateObject(operation.expectedObjectSHA256)
                return
            }
            throw RuntimeStoreError.missingDownload(operation.operationID)
        }
        let actual = Self.sha256(try Data(contentsOf: url))
        guard actual == operation.expectedObjectSHA256 else {
            throw RuntimeStoreError.digestMismatch(
                expected: operation.expectedObjectSHA256,
                actual: actual
            )
        }
    }

    func publishObject(_ operation: ActivationOperation) throws {
        let destination = objectURL(operation.expectedObjectSHA256)
        let source = downloadURL(operation)
        try createDirectory(destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            try reuseOrQuarantineObject(operation, source: source, destination: destination)
            if !fileManager.fileExists(atPath: source.path) {
                return
            }
        }
        try linkPublishedObject(operation, source: source, destination: destination)
    }

    func reuseOrQuarantineObject(
        _ operation: ActivationOperation,
        source: URL,
        destination: URL
    ) throws {
        do {
            try validateObject(operation.expectedObjectSHA256)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.removeItem(at: source)
            }
        } catch {
            let quarantine = quarantineDirectory.appendingPathComponent(
                "\(operation.expectedObjectSHA256).\(UUID().uuidString.lowercased())"
            )
            try fileManager.moveItem(at: destination, to: quarantine)
            try syncDirectory(destination.deletingLastPathComponent())
        }
    }

    func linkPublishedObject(
        _ operation: ActivationOperation,
        source: URL,
        destination: URL
    ) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw RuntimeStoreError.missingDownload(operation.operationID)
        }
        if link(source.path, destination.path) != 0 {
            guard errno == EEXIST else {
                throw RuntimeStoreError.systemCall(operation: "link CAS object", code: errno)
            }
            try validateObject(operation.expectedObjectSHA256)
        }
        if chmod(destination.path, S_IRUSR | S_IRGRP | S_IROTH) != 0 {
            throw RuntimeStoreError.systemCall(operation: "chmod CAS object", code: errno)
        }
        try syncFile(destination)
        try syncDirectory(destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: source.path) {
            try fileManager.removeItem(at: source)
        }
        try validateObject(operation.expectedObjectSHA256)
    }

    func validateObject(_ digest: String) throws {
        let url = objectURL(digest)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RuntimeStoreError.corruptObject(digest)
        }
        let actual = Self.sha256(try Data(contentsOf: url))
        guard actual == digest else {
            throw RuntimeStoreError.corruptObject(digest)
        }
    }

    func materialize(_ operation: ActivationOperation) throws -> GenerationReference {
        let finalDirectory = generationURL(
            gameID: operation.gameID,
            generationID: operation.generationID
        )
        let manifestData = try encoder.encode(GenerationManifest(
            gameID: operation.gameID,
            generationID: operation.generationID,
            objectSHA256: [operation.expectedObjectSHA256]
        ))
        let reference = GenerationReference(
            generationID: operation.generationID,
            manifestSHA256: Self.sha256(manifestData)
        )

        if fileManager.fileExists(atPath: finalDirectory.path) {
            try validateReference(reference, gameID: operation.gameID)
            return reference
        }
        try publishGeneration(
            operation,
            manifestData: manifestData,
            reference: reference,
            finalDirectory: finalDirectory
        )
        return reference
    }

    func publishGeneration(
        _ operation: ActivationOperation,
        manifestData: Data,
        reference: GenerationReference,
        finalDirectory: URL
    ) throws {
        let gameDirectory = finalDirectory.deletingLastPathComponent()
        try createDirectory(gameDirectory)
        let stagingDirectory = gameDirectory.appendingPathComponent(
            ".\(operation.generationID).\(operation.operationID).staging",
            isDirectory: true
        )
        try prepareStagingDirectory(operation, manifestData: manifestData, at: stagingDirectory)
        if rename(stagingDirectory.path, finalDirectory.path) != 0 {
            guard errno == EEXIST || errno == ENOTEMPTY else {
                throw RuntimeStoreError.systemCall(operation: "publish generation", code: errno)
            }
            try fileManager.removeItem(at: stagingDirectory)
            try validateReference(reference, gameID: operation.gameID)
            return
        }
        try syncDirectory(gameDirectory)
        try sealGeneration(finalDirectory)
        try validateReference(reference, gameID: operation.gameID)
    }

    func prepareStagingDirectory(
        _ operation: ActivationOperation,
        manifestData: Data,
        at stagingDirectory: URL
    ) throws {
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.removeItem(at: stagingDirectory)
        }
        try createDirectory(stagingDirectory)
        let layersDirectory = stagingDirectory.appendingPathComponent("layers", isDirectory: true)
        try createDirectory(layersDirectory)
        let sourceObject = objectURL(operation.expectedObjectSHA256)
        try validateObject(operation.expectedObjectSHA256)
        let materializedObject = layersDirectory.appendingPathComponent(
            "000-\(operation.expectedObjectSHA256)"
        )
        if link(sourceObject.path, materializedObject.path) != 0 {
            throw RuntimeStoreError.systemCall(operation: "link materialized object", code: errno)
        }
        try writeDurable(
            manifestData,
            to: stagingDirectory.appendingPathComponent("manifest.json"),
            exclusive: true
        )
        try syncDirectory(layersDirectory)
        try syncDirectory(stagingDirectory)
    }

    func sealGeneration(_ directory: URL) throws {
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let mode: mode_t = values.isDirectory == true
                ? S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
                : S_IRUSR | S_IRGRP | S_IROTH
            if chmod(url.path, mode) != 0 {
                throw RuntimeStoreError.systemCall(operation: "seal generation item", code: errno)
            }
        }
        if chmod(
            directory.path,
            S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
        ) != 0 {
            throw RuntimeStoreError.systemCall(operation: "seal generation", code: errno)
        }
    }
}
