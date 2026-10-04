// Author: Timur Isaev

import Darwin
import Foundation

extension ContentStore {
    func writeDownloads(_ layers: [LayerInput], operation: ActivationOperation) throws {
        let directory = downloadDirectory(operation)
        var wroteDownload = false
        var stagedDigests = Set<String>()
        for (index, layer) in layers.enumerated() {
            guard stagedDigests.insert(layer.descriptor.digest).inserted,
                  (try? validateObject(layer.descriptor)) == nil else {
                continue
            }
            if !wroteDownload {
                try createDirectory(directory)
                wroteDownload = true
            }
            try writeDurable(
                layer.contents,
                to: downloadURL(layer.descriptor, index: index, operation: operation),
                exclusive: true
            )
        }
        if wroteDownload {
            try syncDirectory(directory)
        }
    }

    func verifyDownloads(_ operation: ActivationOperation) throws {
        for (index, descriptor) in operation.layers.enumerated() {
            let url = try downloadURL(descriptor, index: index, operation: operation)
            guard isRegularFile(url) else {
                let storedObject = try objectURL(descriptor.digest)
                if isRegularFile(storedObject) {
                    try validateObject(descriptor)
                    continue
                }
                throw ContentStoreError.missingDownload(operation.operationID)
            }
            let data = try Data(contentsOf: url)
            guard data.count == descriptor.size else {
                throw ContentStoreError.sizeMismatch(expected: descriptor.size, actual: data.count)
            }
            let actual = Self.digest(data)
            guard actual == descriptor.digest else {
                throw ContentStoreError.digestMismatch(
                    expected: descriptor.digest,
                    actual: actual
                )
            }
        }
    }

    func publishObjects(_ operation: ActivationOperation) throws {
        for (index, descriptor) in operation.layers.enumerated() {
            try publishObject(descriptor, index: index, operation: operation)
        }
        let directory = downloadDirectory(operation)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
            try syncDirectory(downloadsDirectory)
        }
    }

    func publishObject(
        _ descriptor: LayerDescriptor,
        index: Int,
        operation: ActivationOperation
    ) throws {
        let destination = try objectURL(descriptor.digest)
        let source = try downloadURL(descriptor, index: index, operation: operation)
        try createDirectory(destination.deletingLastPathComponent())
        if pathEntryExists(destination) {
            try reuseOrQuarantineObject(descriptor, source: source, destination: destination)
            if !pathEntryExists(source) {
                return
            }
        }
        try linkPublishedObject(descriptor, source: source, destination: destination)
    }

    func reuseOrQuarantineObject(
        _ descriptor: LayerDescriptor,
        source: URL,
        destination: URL
    ) throws {
        do {
            try validateObject(descriptor)
            if pathEntryExists(source) {
                try fileManager.removeItem(at: source)
            }
        } catch {
            let quarantine = quarantineDirectory.appendingPathComponent(
                "\(try rawSHA256(descriptor.digest)).\(UUID().uuidString.lowercased())"
            )
            try fileManager.moveItem(at: destination, to: quarantine)
            try syncDirectory(destination.deletingLastPathComponent())
            try syncDirectory(quarantineDirectory)
        }
    }

    func linkPublishedObject(
        _ descriptor: LayerDescriptor,
        source: URL,
        destination: URL
    ) throws {
        guard isRegularFile(source) else {
            throw ContentStoreError.missingDownload(destination.lastPathComponent)
        }
        // The ingest path is untrusted even after the earlier verification
        // checkpoint. Publish a private copy of freshly verified bytes, never
        // a hard link to the caller-mutable download inode.
        let contents = try verifiedIngestSnapshot(descriptor, source: source)
        let publication = source.deletingLastPathComponent().appendingPathComponent(
            ".ingest-\(UUID().uuidString.lowercased()).tmp"
        )
        defer { try? fileManager.removeItem(at: publication) }
        try writeDurable(contents, to: publication, exclusive: true)
        if link(publication.path, destination.path) != 0 {
            guard errno == EEXIST else {
                throw ContentStoreError.systemCall(operation: "link CAS object", code: errno)
            }
            try validateObject(descriptor)
        }
        if chmod(destination.path, S_IRUSR | S_IRGRP | S_IROTH) != 0 {
            throw ContentStoreError.systemCall(operation: "chmod CAS object", code: errno)
        }
        try syncFile(destination)
        try syncDirectory(destination.deletingLastPathComponent())
        if pathEntryExists(source) {
            try fileManager.removeItem(at: source)
        }
        try validateObject(descriptor)
    }

    func validateObject(_ descriptor: LayerDescriptor) throws {
        let url = try objectURL(descriptor.digest)
        guard isRegularFile(url) else {
            throw ContentStoreError.corruptObject(descriptor.digest)
        }
        let data = try Data(contentsOf: url)
        guard data.count == descriptor.size,
              Self.digest(data) == descriptor.digest else {
            throw ContentStoreError.corruptObject(descriptor.digest)
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
            layers: operation.layers
        ))
        let reference = GenerationReference(
            generationID: operation.generationID,
            manifestDigest: Self.digest(manifestData)
        )

        if pathEntryExists(finalDirectory) {
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
        try sealGeneration(stagingDirectory)
        try syncDirectory(stagingDirectory)
        if rename(stagingDirectory.path, finalDirectory.path) != 0 {
            guard errno == EEXIST || errno == ENOTEMPTY else {
                throw ContentStoreError.systemCall(operation: "publish generation", code: errno)
            }
            try removeSealedStagingDirectory(stagingDirectory)
            try validateReference(reference, gameID: operation.gameID)
            return
        }
        try syncDirectory(gameDirectory)
        try validateReference(reference, gameID: operation.gameID)
    }

    func prepareStagingDirectory(
        _ operation: ActivationOperation,
        manifestData: Data,
        at stagingDirectory: URL
    ) throws {
        if pathEntryExists(stagingDirectory) {
            try removeSealedStagingDirectory(stagingDirectory)
        }
        try createDirectory(stagingDirectory)
        let layersDirectory = stagingDirectory.appendingPathComponent("layers", isDirectory: true)
        try createDirectory(layersDirectory)
        for (index, descriptor) in operation.layers.enumerated() {
            try validateObject(descriptor)
            let sourceObject = try objectURL(descriptor.digest)
            let materializedObject = try materializedLayerURL(
                descriptor,
                index: index,
                generationDirectory: stagingDirectory
            )
            if link(sourceObject.path, materializedObject.path) != 0 {
                throw ContentStoreError.systemCall(operation: "link materialized object", code: errno)
            }
        }
        try writeDurable(
            manifestData,
            to: stagingDirectory.appendingPathComponent("manifest.json"),
            exclusive: true
        )
        try syncDirectory(layersDirectory)
        try syncDirectory(stagingDirectory)
    }

    func removeSealedStagingDirectory(_ directory: URL) throws {
        guard pathEntryExists(directory) else {
            return
        }
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if isDirectory(url) {
                if chmod(url.path, S_IRWXU) != 0 {
                    throw ContentStoreError.systemCall(
                        operation: "unseal staging directory",
                        code: errno
                    )
                }
            } else if isRegularFile(url) {
                // Unlink permission belongs to the parent directory. These
                // files may be hard links to CAS and reachable generations;
                // chmod would mutate every link to the shared inode.
            } else {
                throw ContentStoreError.unsafeStoreEntry(url.path)
            }
        }
        if chmod(directory.path, S_IRWXU) != 0 {
            throw ContentStoreError.systemCall(operation: "unseal staging", code: errno)
        }
        try fileManager.removeItem(at: directory)
        try syncDirectory(directory.deletingLastPathComponent())
    }

    func validateMaterializedLayer(
        _ descriptor: LayerDescriptor,
        index: Int,
        generationDirectory: URL
    ) throws {
        let url = try materializedLayerURL(
            descriptor,
            index: index,
            generationDirectory: generationDirectory
        )
        guard isRegularFile(url) else {
            throw ContentStoreError.incompleteGeneration(generationDirectory.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        guard data.count == descriptor.size,
              Self.digest(data) == descriptor.digest else {
            throw ContentStoreError.incompleteGeneration(generationDirectory.lastPathComponent)
        }
    }

    func sealGeneration(_ directory: URL) throws {
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let mode: mode_t
            if isDirectory(url) {
                mode = S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
            } else if isRegularFile(url) {
                mode = S_IRUSR | S_IRGRP | S_IROTH
            } else {
                throw ContentStoreError.incompleteGeneration(directory.lastPathComponent)
            }
            if chmod(url.path, mode) != 0 {
                throw ContentStoreError.systemCall(operation: "seal generation item", code: errno)
            }
        }
        if chmod(
            directory.path,
            S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
        ) != 0 {
            throw ContentStoreError.systemCall(operation: "seal generation", code: errno)
        }
    }
}
