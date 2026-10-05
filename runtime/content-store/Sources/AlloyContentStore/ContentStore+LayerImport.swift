// Author: Timur Isaev

import CryptoKit
import Darwin
import Foundation

extension ContentStore {
    /// Explicitly opts into local, unsigned development metadata. Never a trust-root bypass for releases.
    public func importDevelopmentLayer(from source: URL, descriptor: LayerDescriptor) throws {
        try validateLayerDescriptor(descriptor)
        guard descriptor.mediaType == LayerFormat.mediaType,
            descriptor.size <= LayerFormat.maximumBytes + 65536
        else {
            throw LayerFormat.reject("unsupported development layer")
        }
        try withExclusiveLock {
            let scratch = try layerScratch()
            defer { try? removeLayerScratch(scratch) }
            let snapshot = scratch.appendingPathComponent("archive.zst")
            try copyLayerSnapshot(from: source, to: snapshot, descriptor: descriptor)
            let decoded = try LayerArchive.decode(snapshot, descriptor: descriptor, scratch: scratch)
            let tree = scratch.appendingPathComponent("tree")
            try createDirectory(tree)
            try extractLayer(decoded, into: tree)
            try validateLayerTree(tree, entries: decoded.entries, requireCompleteLinks: false)
            let destination = try objectURL(descriptor.digest)
            try createDirectory(destination.deletingLastPathComponent())
            if pathEntryExists(destination) {
                try validateObject(descriptor)
                return
            }
            guard chmod(snapshot.path, 0o444) == 0, link(snapshot.path, destination.path) == 0 else {
                throw LayerFormat.reject("cannot publish verified layer")
            }
            try syncFile(destination)
            try syncDirectory(destination.deletingLastPathComponent())
        }
    }

    public func activateImportedLayers(
        gameID: String, generationID: String, layers: [LayerDescriptor]
    ) throws -> GenerationReference {
        try validateIdentifier(gameID)
        try validateIdentifier(generationID)
        guard !layers.isEmpty else { throw ContentStoreError.emptyLayerSet }
        return try withExclusiveLock {
            for layer in layers {
                try validateLayerDescriptor(layer)
                guard layer.mediaType == LayerFormat.mediaType else {
                    throw LayerFormat.reject("imported runtime requires v1 layers")
                }
                try validateObject(layer)
            }
            try requireNoPendingActivation(gameID: gameID)
            var operation = ActivationOperation(
                operationID: "\(gameID)-\(generationID)-\(UUID().uuidString.lowercased())",
                gameID: gameID, generationID: generationID, layers: layers, healthOutcome: .pass,
                previousActive: try readReference(.active, gameID: gameID)
            )
            try writeJournal(operation)
            try resume(&operation, faultInjector: nil)
            _ = try synchronizeCatalogUnlocked(faultInjector: nil)
            guard let reference = try readReference(.active, gameID: gameID) else {
                throw ContentStoreError.missingReference("active")
            }
            return reference
        }
    }

    func layerScratch() throws -> URL {
        let directory = root.appendingPathComponent(".layer-\(UUID().uuidString.lowercased())")
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    func removeLayerScratch(_ directory: URL) throws {
        let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil)
        guard chmod(directory.path, 0o700) == 0 else { throw LayerFormat.reject("unseal scratch") }
        while let url = enumerator?.nextObject() as? URL {
            if isDirectory(url), chmod(url.path, 0o700) != 0 { throw LayerFormat.reject("unseal scratch child") }
        }
        try fileManager.removeItem(at: directory)
    }

    func copyLayerSnapshot(from source: URL, to destination: URL, descriptor: LayerDescriptor) throws {
        let inputFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard inputFD >= 0 else { throw LayerFormat.reject("cannot open layer input") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(inputFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size == descriptor.size
        else { throw LayerFormat.reject("layer input type or size") }
        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw LayerFormat.reject("cannot create layer snapshot") }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var hash = SHA256()
        var size = 0
        while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty {
            guard bytes.count <= descriptor.size - size else { throw LayerFormat.reject("layer grew during import") }
            hash.update(data: bytes)
            try output.write(contentsOf: bytes)
            size += bytes.count
        }
        let actual = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == descriptor.size, actual == descriptor.digest else {
            throw ContentStoreError.digestMismatch(expected: descriptor.digest, actual: actual)
        }
        try output.synchronize()
    }

    func extractLayer(_ decoded: DecodedLayer, into tree: URL) throws {
        for entry in decoded.entries where entry.kind == 1 {
            let destination = tree.appendingPathComponent(entry.path)
            if pathEntryExists(destination) {
                guard isDirectory(destination) else { throw LayerFormat.reject("composition directory collision") }
            } else {
                try createDirectory(destination)
            }
        }
        for entry in decoded.entries where entry.kind != 1 {
            let destination = tree.appendingPathComponent(entry.path)
            guard !pathEntryExists(destination) else { throw LayerFormat.reject("composition file collision") }
            if entry.kind == 2 {
                guard symlink(entry.target, destination.path) == 0 else {
                    throw LayerFormat.reject("create layer symlink")
                }
            } else {
                try extractRegularFile(decoded, entry: entry, destination: destination)
            }
        }
        for entry in decoded.entries.reversed() where entry.kind == 1 {
            let directory = tree.appendingPathComponent(entry.path)
            try syncDirectory(directory)
        }
    }

    private func extractRegularFile(_ decoded: DecodedLayer, entry: LayerFileEntry, destination: URL) throws {
        guard let member = decoded.members["files/" + entry.path] else {
            throw LayerFormat.reject("missing tar payload")
        }
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LayerFormat.reject("create extracted file") }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            for offset in stride(from: member.range.lowerBound, to: member.range.upperBound, by: 65536) {
                try output.write(contentsOf: decoded.tar[offset..<min(offset + 65536, member.range.upperBound)])
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        guard chmod(destination.path, mode_t(entry.mode)) == 0 else {
            throw LayerFormat.reject("seal extracted file")
        }
        try verifyDevelopmentNativeCode(destination)
    }

    func verifyDevelopmentNativeCode(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        let prefix = try file.read(upToCount: 4) ?? Data()
        try file.close()
        let magics = [
            Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xcf]),
            Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
            Data([0xce, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xce]),
            Data([0xca, 0xfe, 0xba, 0xbf]), Data([0xbf, 0xba, 0xfe, 0xca])
        ]
        guard magics.contains(prefix) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw LayerFormat.reject("native signature check timeout")
        }
        guard process.terminationStatus == 0 else { throw LayerFormat.reject("invalid native ad-hoc signature") }
    }
}
