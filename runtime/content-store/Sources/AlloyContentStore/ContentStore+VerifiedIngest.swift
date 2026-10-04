// Author: Timur Isaev

import Darwin
import Foundation

extension ContentStore {
    /// Reads the untrusted download through one no-follow file descriptor.
    /// The returned value, rather than the input inode, becomes CAS content.
    func verifiedIngestSnapshot(_ descriptor: LayerDescriptor, source: URL) throws -> Data {
        let descriptorFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptorFD >= 0 else {
            throw ContentStoreError.systemCall(operation: "open verified ingest", code: errno)
        }
        defer { close(descriptorFD) }
        var before = stat()
        guard fstat(descriptorFD, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw ContentStoreError.unsafeStoreEntry(source.path)
        }
        guard before.st_size == descriptor.size else {
            throw ContentStoreError.sizeMismatch(expected: descriptor.size, actual: Int(before.st_size))
        }
        let contents = try readIngestSnapshot(descriptorFD, expectedSize: descriptor.size)
        guard contents.count == descriptor.size else {
            throw ContentStoreError.sizeMismatch(expected: descriptor.size, actual: contents.count)
        }
        let actual = Self.digest(contents)
        guard actual == descriptor.digest else {
            throw ContentStoreError.digestMismatch(expected: descriptor.digest, actual: actual)
        }
        var current = stat()
        guard lstat(source.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == before.st_dev, current.st_ino == before.st_ino else {
            throw ContentStoreError.unsafeStoreEntry(source.path)
        }
        return contents
    }

    private func readIngestSnapshot(_ descriptorFD: Int32, expectedSize: Int) throws -> Data {
        var contents = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptorFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ContentStoreError.systemCall(operation: "read verified ingest", code: errno)
            }
            if count == 0 { break }
            guard count <= expectedSize - contents.count else {
                throw ContentStoreError.sizeMismatch(expected: expectedSize, actual: contents.count + count)
            }
            contents.append(contentsOf: buffer.prefix(count))
        }
        return contents
    }
}
