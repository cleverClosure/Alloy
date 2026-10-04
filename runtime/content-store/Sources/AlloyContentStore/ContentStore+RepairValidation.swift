// Author: Timur Isaev

import Foundation

extension ContentStore {
    func repairGenerations(for descriptors: [LayerDescriptor]) throws -> [RepairGeneration] {
        var authorized: [String: Int] = [:]
        for descriptor in descriptors {
            if let size = authorized[descriptor.digest], size != descriptor.size {
                throw ContentStoreError.invalidLayer("duplicate repair digest has inconsistent size")
            }
            authorized[descriptor.digest] = descriptor.size
        }
        var result: [RepairGeneration] = []
        for gameDirectory in try directoryEntries(generationsDirectory) {
            try requireSafeDirectory(gameDirectory)
            let gameID = gameDirectory.lastPathComponent
            try validateIdentifier(gameID)
            for directory in try directoryEntries(gameDirectory) {
                let manifest = try repairManifest(at: directory, gameID: gameID)
                let reference = GenerationReference(
                    generationID: manifest.generationID,
                    manifestDigest: Self.digest(try Data(contentsOf: directory.appendingPathComponent("manifest.json")))
                )
                try verifyRepairManifestReferences(gameID: gameID, reference: reference)
                let affected = manifest.layers.contains { authorized[$0.digest] != nil }
                try verifyRepairableLayers(manifest, directory: directory, authorized: authorized)
                if affected { result.append(RepairGeneration(gameID: gameID, reference: reference)) }
            }
        }
        return result
    }

    func verifyRepairableLayers(
        _ manifest: GenerationManifest, directory: URL, authorized: [String: Int]
    ) throws {
        try requireSafeDirectory(directory.appendingPathComponent("layers", isDirectory: true))
        for (index, descriptor) in manifest.layers.enumerated() {
            if let size = authorized[descriptor.digest] {
                guard size == descriptor.size else {
                    throw ContentStoreError.invalidLayer("repair size differs from generation descriptor")
                }
                let url = try materializedLayerURL(descriptor, index: index, generationDirectory: directory)
                if pathEntryExists(url), !isRegularFile(url) {
                    throw ContentStoreError.unsafeStoreEntry(url.path)
                }
            } else {
                try validateObject(descriptor)
                try validateMaterializedLayer(descriptor, index: index, generationDirectory: directory)
            }
        }
    }

    func repairManifest(at directory: URL, gameID: String) throws -> GenerationManifest {
        try requireSafeDirectory(directory)
        let generationID = directory.lastPathComponent
        try validateIdentifier(generationID)
        let url = directory.appendingPathComponent("manifest.json")
        guard isRegularFile(url) else { throw ContentStoreError.incompleteGeneration(generationID) }
        let manifest = try decoder.decode(GenerationManifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == GenerationManifest.currentSchemaVersion,
              manifest.gameID == gameID, manifest.generationID == generationID,
              !manifest.layers.isEmpty else {
            throw ContentStoreError.incompleteGeneration(generationID)
        }
        for descriptor in manifest.layers { try validateLayerDescriptor(descriptor) }
        return manifest
    }

    func verifyRepairManifestReferences(gameID: String, reference: GenerationReference) throws {
        for kind in ReferenceKind.allCases {
            let url = referenceURL(kind, gameID: gameID)
            guard pathEntryExists(url) else { continue }
            guard isRegularFile(url) else { throw ContentStoreError.unsafeStoreEntry(url.path) }
            let expected = try decoder.decode(GenerationReference.self, from: Data(contentsOf: url))
            if expected.generationID == reference.generationID, expected != reference {
                throw ContentLifecycleError.changedGeneration(reference.generationID)
            }
        }
        // Exact process leases and their manifest identity survive repair. No
        // lease is removed or fabricated to make a damaged generation collectable.
        for url in try directoryEntries(leasesDirectory) where url.pathExtension == "json" {
            let lease = try readLease(url)
            if lease.gameID == gameID, lease.generationID == reference.generationID,
               lease.manifestDigest != reference.manifestDigest {
                throw ContentLifecycleError.changedGeneration(reference.generationID)
            }
        }
    }
}
