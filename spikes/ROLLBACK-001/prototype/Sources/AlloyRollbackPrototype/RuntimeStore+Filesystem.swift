// Author: Timur Isaev

import Darwin
import Foundation

extension RuntimeStore {
    func writeAtomic(_ data: Data, to destination: URL) throws {
        try createDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        try writeDurable(data, to: temporary, exclusive: true)
        if rename(temporary.path, destination.path) != 0 {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw RuntimeStoreError.systemCall(operation: "atomic rename", code: code)
        }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    func writeDurable(_ data: Data, to url: URL, exclusive: Bool) throws {
        let flags = O_WRONLY | O_CREAT | (exclusive ? O_EXCL : O_TRUNC)
        let descriptor = open(url.path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RuntimeStoreError.systemCall(operation: "open \(url.lastPathComponent)", code: errno)
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
                    throw RuntimeStoreError.systemCall(
                        operation: "write \(url.lastPathComponent)",
                        code: errno
                    )
                }
                remaining -= written
                address = address.advanced(by: written)
            }
        }
        if fsync(descriptor) != 0 {
            throw RuntimeStoreError.systemCall(operation: "fsync \(url.lastPathComponent)", code: errno)
        }
        if close(descriptor) != 0 {
            closeRequired = false
            throw RuntimeStoreError.systemCall(operation: "close \(url.lastPathComponent)", code: errno)
        }
        closeRequired = false
    }

    func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw RuntimeStoreError.systemCall(operation: "open file for fsync", code: errno)
        }
        defer { close(descriptor) }
        if fsync(descriptor) != 0 {
            throw RuntimeStoreError.systemCall(operation: "fsync file", code: errno)
        }
    }

    func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw RuntimeStoreError.systemCall(operation: "open directory for fsync", code: errno)
        }
        defer { close(descriptor) }
        if fsync(descriptor) != 0 {
            throw RuntimeStoreError.systemCall(operation: "fsync directory", code: errno)
        }
    }

    func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func ensureLockFile() throws {
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RuntimeStoreError.systemCall(operation: "create lock", code: errno)
        }
        close(descriptor)
    }

    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_RDWR)
        guard descriptor >= 0 else {
            throw RuntimeStoreError.systemCall(operation: "open lock", code: errno)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw RuntimeStoreError.systemCall(operation: "lock runtime store", code: errno)
        }
        return try body()
    }

    func validateIdentifier(_ identifier: String) throws {
        let punctuation = "._-".unicodeScalars
        guard !identifier.isEmpty,
              identifier != ".",
              identifier != "..",
              identifier.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || punctuation.contains($0)
              }) else {
            throw RuntimeStoreError.invalidIdentifier(identifier)
        }
    }

    func allObjectURLs() throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: objectsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result.append(url)
            }
        }
        return result
    }

    func objectURL(_ digest: String) -> URL {
        let splitIndex = digest.index(digest.startIndex, offsetBy: min(2, digest.count))
        return objectsDirectory
            .appendingPathComponent(String(digest[..<splitIndex]), isDirectory: true)
            .appendingPathComponent(String(digest[splitIndex...]))
    }

    func generationURL(gameID: String, generationID: String) -> URL {
        generationsDirectory
            .appendingPathComponent(gameID, isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)
    }

    func downloadURL(_ operation: ActivationOperation) -> URL {
        downloadsDirectory.appendingPathComponent("\(operation.operationID).part")
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
        root.appendingPathComponent("metadata/runtime.lock")
    }
}
