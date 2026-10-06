// Author: Timur Isaev

import CryptoKit
import Darwin
import Foundation

public struct TreeEntry: Codable, Equatable, Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String?
}

public struct TreeInventory: Codable, Equatable, Sendable {
    public let entries: [TreeEntry]
    public var bytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    public var fingerprint: String { get throws { digest(try encoded(self)) } }
}

extension Directory {
    func inventory(limit: Int64) throws -> TreeInventory {
        var result: [TreeEntry] = []
        var remaining = limit
        try inventory(prefix: "", depth: 0, remaining: &remaining, entries: &result)
        return TreeInventory(entries: result.sorted { $0.path < $1.path })
    }

    private func inventory(prefix: String, depth: Int, remaining: inout Int64,
                           entries: inout [TreeEntry]) throws {
        guard depth < 32 else { throw VolumeError.unsafePath }
        for name in try names() {
            _ = try relativeComponents(name)
            guard entries.count < 10_000, let info = try information(name) else {
                throw VolumeError.quotaExceeded
            }
            let path = prefix + name
            if info.st_mode & S_IFMT == S_IFDIR {
                entries.append(TreeEntry(path: path, size: 0, sha256: nil))
                try child(name).inventory(prefix: path + "/", depth: depth + 1,
                                          remaining: &remaining, entries: &entries)
            } else {
                entries.append(try fingerprint(name, path: path, remaining: &remaining))
            }
        }
    }

    private func fingerprint(_ name: String, path: String, remaining: inout Int64) throws -> TreeEntry {
        let handle = try file(name)
        defer { close(handle) }
        var before = stat()
        guard fstat(handle, &before) == 0, before.st_size <= remaining else {
            throw VolumeError.quotaExceeded
        }
        var hash = SHA256()
        var count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let size = Darwin.read(handle, &buffer, buffer.count)
            if size < 0, errno == EINTR { continue }
            guard size >= 0 else { throw VolumeError.systemCall("hash read", errno) }
            if size == 0 { break }
            guard Int64(size) <= remaining else { throw VolumeError.quotaExceeded }
            remaining -= Int64(size)
            count += Int64(size)
            hash.update(data: Data(buffer.prefix(size)))
        }
        var after = stat()
        guard fstat(handle, &after) == 0, count == before.st_size,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw VolumeError.conflict
        }
        return TreeEntry(path: path, size: count,
                         sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
