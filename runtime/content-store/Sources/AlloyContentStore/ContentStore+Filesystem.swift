// Author: Timur Isaev

import Darwin
import Foundation

extension ContentStore {
    func writeAtomic(_ data: Data, to destination: URL) throws {
        try createDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        try writeDurable(data, to: temporary, exclusive: true)
        if rename(temporary.path, destination.path) != 0 {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw ContentStoreError.systemCall(operation: "atomic rename", code: code)
        }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    func writeDurable(_ data: Data, to url: URL, exclusive: Bool) throws {
        let flags = O_WRONLY | O_CREAT | (exclusive ? O_EXCL : O_TRUNC)
        let descriptor = open(url.path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ContentStoreError.systemCall(operation: "open \(url.lastPathComponent)", code: errno)
        }
        var closeRequired = true
        defer {
            if closeRequired {
                close(descriptor)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else {
                return
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ContentStoreError.systemCall(
                        operation: "write \(url.lastPathComponent)",
                        code: errno
                    )
                }
                remaining -= written
                address = address.advanced(by: written)
            }
        }
        if fsync(descriptor) != 0 {
            throw ContentStoreError.systemCall(operation: "fsync \(url.lastPathComponent)", code: errno)
        }
        if close(descriptor) != 0 {
            closeRequired = false
            throw ContentStoreError.systemCall(operation: "close \(url.lastPathComponent)", code: errno)
        }
        closeRequired = false
    }

    func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ContentStoreError.systemCall(operation: "open file for fsync", code: errno)
        }
        defer { close(descriptor) }
        if fsync(descriptor) != 0 {
            throw ContentStoreError.systemCall(operation: "fsync file", code: errno)
        }
    }

    func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ContentStoreError.systemCall(operation: "open directory for fsync", code: errno)
        }
        defer { close(descriptor) }
        if fsync(descriptor) != 0 {
            throw ContentStoreError.systemCall(operation: "fsync directory", code: errno)
        }
    }

    func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func ensureLockFile() throws {
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ContentStoreError.systemCall(operation: "create lock", code: errno)
        }
        close(descriptor)
    }

    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_RDWR)
        guard descriptor >= 0 else {
            throw ContentStoreError.systemCall(operation: "open lock", code: errno)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ContentStoreError.systemCall(operation: "lock content store", code: errno)
        }
        return try body()
    }

    func validateIdentifier(_ identifier: String) throws {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        guard !identifier.isEmpty,
              identifier != ".",
              identifier != "..",
              identifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ContentStoreError.invalidIdentifier(identifier)
        }
    }

    func validateLayerInputs(_ layers: [LayerInput]) throws {
        guard !layers.isEmpty else {
            throw ContentStoreError.emptyLayerSet
        }
        for layer in layers {
            try validateLayerDescriptor(layer.descriptor)
            guard layer.contents.count == layer.descriptor.size else {
                throw ContentStoreError.sizeMismatch(
                    expected: layer.descriptor.size,
                    actual: layer.contents.count
                )
            }
            let actual = Self.digest(layer.contents)
            guard actual == layer.descriptor.digest else {
                throw ContentStoreError.digestMismatch(
                    expected: layer.descriptor.digest,
                    actual: actual
                )
            }
        }
    }

    func validateLayerDescriptor(_ descriptor: LayerDescriptor) throws {
        guard !descriptor.name.isEmpty,
              !descriptor.version.isEmpty,
              !descriptor.mediaType.isEmpty,
              descriptor.size >= 0 else {
            throw ContentStoreError.invalidLayer("name, version, media type, and nonnegative size are required")
        }
        _ = try rawSHA256(descriptor.digest)
        for relatedDigest in [descriptor.sbomDigest, descriptor.symbolsDigest].compactMap({ $0 }) {
            _ = try rawSHA256(relatedDigest)
        }
    }

    func rawSHA256(_ digest: String) throws -> String {
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else {
            throw ContentStoreError.invalidLayer("digest must use the sha256: prefix")
        }
        let hex = String(digest.dropFirst(prefix.count))
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard hex.count == 64,
              hex.unicodeScalars.allSatisfy({ lowercaseHex.contains($0) }) else {
            throw ContentStoreError.invalidLayer("digest must contain 64 lowercase hexadecimal characters")
        }
        return hex
    }

    func allObjectURLs() throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: objectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if isRegularFile(url) {
                result.append(url)
            }
        }
        return result
    }

    func pathEntryExists(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
    }

    func isRegularFile(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            return false
        }
        return information.st_mode & S_IFMT == S_IFREG
    }

    func isDirectory(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            return false
        }
        return information.st_mode & S_IFMT == S_IFDIR
    }

    func objectURL(_ digest: String) throws -> URL {
        let hex = try rawSHA256(digest)
        let splitIndex = hex.index(hex.startIndex, offsetBy: 2)
        return objectsDirectory
            .appendingPathComponent(String(hex[..<splitIndex]), isDirectory: true)
            .appendingPathComponent(String(hex[splitIndex...]))
    }

    func generationURL(gameID: String, generationID: String) -> URL {
        generationsDirectory
            .appendingPathComponent(gameID, isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)
    }

    func downloadDirectory(_ operation: ActivationOperation) -> URL {
        downloadsDirectory.appendingPathComponent(operation.operationID, isDirectory: true)
    }

    func downloadURL(
        _ descriptor: LayerDescriptor,
        index: Int,
        operation: ActivationOperation
    ) throws -> URL {
        let canonicalIndex = operation.layers.firstIndex {
            $0.digest == descriptor.digest
        } ?? index
        return downloadDirectory(operation).appendingPathComponent(
            String(
                format: "%03d-%@.part",
                canonicalIndex,
                try rawSHA256(descriptor.digest)
            )
        )
    }

    func materializedLayerURL(
        _ descriptor: LayerDescriptor,
        index: Int,
        generationDirectory: URL
    ) throws -> URL {
        generationDirectory
            .appendingPathComponent("layers", isDirectory: true)
            .appendingPathComponent(
                String(format: "%03d-%@", index, try rawSHA256(descriptor.digest))
            )
    }

    func journalURL(_ operationID: String) -> URL {
        journalsDirectory.appendingPathComponent("\(operationID).json")
    }

    var downloadsDirectory: URL {
        root.appendingPathComponent("downloads", isDirectory: true)
    }

    var objectsDirectory: URL {
        root.appendingPathComponent("objects/sha256", isDirectory: true)
    }

    var quarantineDirectory: URL {
        root.appendingPathComponent("quarantine", isDirectory: true)
    }

    var generationsDirectory: URL {
        root.appendingPathComponent("generations", isDirectory: true)
    }

    var referencesDirectory: URL {
        root.appendingPathComponent("references", isDirectory: true)
    }

    var journalsDirectory: URL {
        root.appendingPathComponent("metadata/journal", isDirectory: true)
    }

    var volumesDirectory: URL {
        root.appendingPathComponent("volumes", isDirectory: true)
    }

    var lockURL: URL {
        root.appendingPathComponent("metadata/content-store.lock")
    }
}
