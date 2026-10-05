// Author: Timur Isaev

import Darwin
import Foundation

public struct MaterializedRuntime: Sendable {
    public let url: URL
    public let treeDigest: String
    public let reference: GenerationReference
}

extension ContentStore {
    /// Materializes only the currently active generation and verifies every byte before returning it.
    public func materializeDevelopmentRuntime(gameID: String) throws -> MaterializedRuntime {
        try materializeRuntime(gameID: gameID, requireExisting: false)
    }

    private func materializeRuntime(gameID: String, requireExisting: Bool) throws -> MaterializedRuntime {
        try validateIdentifier(gameID)
        return try withExclusiveLock {
            let (reference, descriptors) = try activeRuntimeDescriptors(gameID: gameID)
            let parent = root.appendingPathComponent("runtime-trees", isDirectory: true)
            try createDirectory(parent)
            let destination = parent.appendingPathComponent(try rawSHA256(reference.manifestDigest))
            guard !requireExisting || pathEntryExists(destination) else {
                throw LayerFormat.reject("runtime tree has not been materialized")
            }
            let scratch = try layerScratch()
            defer { try? removeLayerScratch(scratch) }
            // Darwin needs write permission on a directory when reparenting it.
            // Seal and rename within one parent so publication remains atomic.
            let tree = parent.appendingPathComponent(".runtime-\(UUID().uuidString.lowercased())")
            try fileManager.createDirectory(
                at: tree, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { if pathEntryExists(tree) { try? removeLayerScratch(tree) } }
            var combined: [String: LayerFileEntry] = [:]
            for (index, descriptor) in descriptors.enumerated() {
                let decodeDirectory = scratch.appendingPathComponent("layer-\(index)")
                try createDirectory(decodeDirectory)
                let archive = decodeDirectory.appendingPathComponent("archive.zst")
                try copyLayerSnapshot(from: objectURL(descriptor.digest), to: archive, descriptor: descriptor)
                let decoded = try LayerArchive.decode(archive, descriptor: descriptor, scratch: decodeDirectory)
                try mergeLayerEntries(decoded.entries, into: &combined)
                if !pathEntryExists(destination) { try extractLayer(decoded, into: tree) }
            }
            let entries = combined.values.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            _ = try LayerFormat.decodeTable(LayerFormat.encodeTable(entries))
            let treeDigest = Self.digest(LayerFormat.encodeTable(entries))
            if !pathEntryExists(destination) {
                try validateLayerTree(tree, entries: entries, requireCompleteLinks: true)
                for entry in entries.reversed() where entry.kind == 1 {
                    let directory = tree.appendingPathComponent(entry.path)
                    guard chmod(directory.path, 0o555) == 0 else { throw LayerFormat.reject("seal runtime directory") }
                    try syncDirectory(directory)
                }
                guard chmod(tree.path, 0o555) == 0 else { throw LayerFormat.reject("seal runtime root") }
                try syncDirectory(tree)
                guard renamex_np(tree.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw ContentStoreError.systemCall(operation: "publish runtime tree", code: errno)
                }
                try syncDirectory(parent)
            }
            try validateLayerTree(destination, entries: entries, requireCompleteLinks: true, sealed: true)
            return MaterializedRuntime(url: destination, treeDigest: treeDigest, reference: reference)
        }
    }

    /// Checks the existing tree; it never repairs or silently replaces tampered content.
    public func verifyDevelopmentRuntime(gameID: String) throws -> MaterializedRuntime {
        try materializeRuntime(gameID: gameID, requireExisting: true)
    }

    private func activeRuntimeDescriptors(gameID: String) throws -> (GenerationReference, [LayerDescriptor]) {
        guard let reference = try readReference(.active, gameID: gameID) else {
            throw ContentStoreError.missingReference("active")
        }
        try validateReference(reference, gameID: gameID)
        let directory = generationURL(gameID: gameID, generationID: reference.generationID)
        let manifest = try decoder.decode(
            GenerationManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.layers.allSatisfy({ $0.mediaType == LayerFormat.mediaType }) else {
            throw LayerFormat.reject("runtime generation contains an unsupported layer")
        }
        return (reference, manifest.layers)
    }

    private func mergeLayerEntries(_ entries: [LayerFileEntry], into combined: inout [String: LayerFileEntry]) throws {
        for entry in entries {
            if let previous = combined[entry.path] {
                guard previous.kind == 1, previous == entry else {
                    throw LayerFormat.reject("runtime layers overlap a nondirectory path")
                }
            } else {
                combined[entry.path] = entry
            }
        }
    }

    func validateLayerTree(
        _ tree: URL, entries: [LayerFileEntry], requireCompleteLinks: Bool, sealed: Bool = false
    ) throws {
        guard isDirectory(tree) else { throw LayerFormat.reject("runtime root is not a directory") }
        let expected = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        var observed = Set<String>()
        guard let enumerator = fileManager.enumerator(atPath: tree.path) else {
            throw LayerFormat.reject("cannot enumerate runtime")
        }
        while let relative = enumerator.nextObject() as? String {
            let url = tree.appendingPathComponent(relative)
            guard let entry = expected[relative], observed.insert(relative).inserted else {
                throw LayerFormat.reject("extra runtime path: \(relative)")
            }
            try validateTreeEntry(
                url, entry: entry, expected: expected,
                requireCompleteLinks: requireCompleteLinks, sealed: sealed)
        }
        guard observed == Set(expected.keys) else { throw LayerFormat.reject("missing runtime file") }
        if sealed {
            var info = stat()
            guard lstat(tree.path, &info) == 0, info.st_mode & 0o7777 == 0o555 else {
                throw LayerFormat.reject("runtime root is writable")
            }
        }
    }

    private func validateTreeEntry(
        _ url: URL, entry: LayerFileEntry, expected: [String: LayerFileEntry],
        requireCompleteLinks: Bool, sealed: Bool
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw LayerFormat.reject("missing runtime path") }
        let kind = info.st_mode & S_IFMT
        switch entry.kind {
        case 0:
            guard kind == S_IFREG, info.st_nlink == 1, info.st_size == entry.size,
                Int(info.st_mode & 0o7777) == entry.mode
            else {
                throw LayerFormat.reject("runtime file metadata")
            }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard LayerArchive.hash(bytes, range: 0..<bytes.count) == entry.digest else {
                throw LayerFormat.reject("modified runtime file: \(entry.path)")
            }
        case 1:
            guard kind == S_IFDIR, !sealed || Int(info.st_mode & 0o7777) == entry.mode else {
                throw LayerFormat.reject("runtime directory metadata")
            }
        case 2:
            guard kind == S_IFLNK,
                try fileManager.destinationOfSymbolicLink(atPath: url.path) == entry.target
            else {
                throw LayerFormat.reject("runtime symlink metadata")
            }
            if requireCompleteLinks { try validateRuntimeLink(entry, entries: expected) }
        default: throw LayerFormat.reject("unsupported runtime path")
        }
    }

    private func validateRuntimeLink(_ entry: LayerFileEntry, entries: [String: LayerFileEntry]) throws {
        var target = try LayerFormat.linkTarget(entry)
        var seen = Set([entry.path])
        while true {
            guard seen.count <= 32, seen.insert(target).inserted,
                let destination = entries[target]
            else { throw LayerFormat.reject("dangling or cyclic runtime link") }
            var parts = target.split(separator: "/").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                guard entries[parts.joined(separator: "/")]?.kind == 1 else {
                    throw LayerFormat.reject("runtime link traverses another link")
                }
            }
            if destination.kind == 0 { return }
            guard destination.kind == 2 else { throw LayerFormat.reject("runtime directory links are unsupported") }
            target = try LayerFormat.linkTarget(destination)
        }
    }
}
