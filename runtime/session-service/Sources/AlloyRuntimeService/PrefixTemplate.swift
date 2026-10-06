// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation

struct PrefixEntry: Codable, Equatable {
    let path: String
    let kind: String
    let value: String
    let mode: UInt16
}

struct PrefixManifest: Codable {
    let format: String
    let generation: String
    let runtimeDigest: String
    let prefixDigest: String
}

/// Cache publication is serialized across daemon/agent processes. Copies share no writable files.
final class PrefixTemplate {
    let root: URL
    private let files = FileManager.default

    init(root: URL) throws {
        self.root = root
        try privateDirectory(root)
    }

    func copy(generation: String, runtimeDigest: String, runtime: URL, destination: URL,
              bootstrap: (URL) throws -> Void) throws -> String {
        let key = ContentStore.digest(Data((generation + ":" + runtimeDigest + ":prefix-v1").utf8)).dropFirst(7)
        let lock = open(root.appendingPathComponent("cache.lock").path,
                        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw RuntimeFailure.status(.failed) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw RuntimeFailure.status(.failed) }
        defer { flock(lock, LOCK_UN) }
        let cached = root.appendingPathComponent(String(key))
        let manifestURL = root.appendingPathComponent(String(key) + ".json")
        if !files.fileExists(atPath: cached.path) {
            let staging = root.appendingPathComponent(".prefix-" + UUID().uuidString)
            try privateDirectory(staging)
            defer { try? files.removeItem(at: staging) }
            try bootstrap(staging)
            try sanitize(staging, runtime: runtime)
            try PrefixNormalization.apply(staging, seed: generation + ":" + runtimeDigest)
            let digest = try Self.digest(staging)
            try files.moveItem(at: staging, to: cached)
            try PrivateRecords.write(PrefixManifest(format: "prefix-v1", generation: generation,
                                                    runtimeDigest: runtimeDigest, prefixDigest: digest),
                                     to: manifestURL)
        }
        let manifest = try PrivateRecords.read(PrefixManifest.self, from: manifestURL)
        guard manifest.format == "prefix-v1", manifest.generation == generation,
              manifest.runtimeDigest == runtimeDigest, try Self.digest(cached) == manifest.prefixDigest else {
            throw RuntimeFailure.status(.conflict)
        }
        guard !files.fileExists(atPath: destination.path) else { throw RuntimeFailure.status(.conflict) }
        try files.copyItem(at: cached, to: destination)
        guard try Self.digest(destination) == manifest.prefixDigest else { throw RuntimeFailure.status(.conflict) }
        return manifest.prefixDigest
    }

    private func sanitize(_ prefix: URL, runtime: URL) throws {
        let prefixPath = prefix.resolvingSymlinksInPath().path
        let runtimePath = runtime.resolvingSymlinksInPath().path
        // Wineboot's default Z: and user-folder links are not part of the title namespace.
        let drives = prefix.appendingPathComponent("dosdevices")
        if files.fileExists(atPath: drives.path) { try files.removeItem(at: drives) }
        try privateDirectory(drives)
        guard let entries = files.enumerator(atPath: prefix.path) else { throw RuntimeFailure.status(.failed) }
        var links: [URL] = []
        while let path = entries.nextObject() as? String {
            let url = prefix.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw RuntimeFailure.status(.failed) }
            if info.st_mode & S_IFMT == S_IFLNK { links.append(url) }
        }
        for link in links {
            let target = link.resolvingSymlinksInPath().path
            if target.hasPrefix(runtimePath + "/") { continue }
            if target.hasPrefix(prefixPath + "/") {
                // Replace absolute bootstrap paths with equivalent relative links before caching.
                let depth = link.deletingLastPathComponent().resolvingSymlinksInPath().path.dropFirst(prefixPath.count)
                    .split(separator: "/").count
                let relative = String(repeating: "../", count: depth) + target.dropFirst(prefixPath.count + 1)
                try files.removeItem(at: link)
                try files.createSymbolicLink(atPath: link.path, withDestinationPath: relative)
            } else {
                try files.removeItem(at: link)
                try privateDirectory(link)
            }
        }
    }

    static func digest(_ root: URL) throws -> String {
        let files = FileManager.default
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
              let walker = files.enumerator(atPath: root.path) else { throw RuntimeFailure.status(.conflict) }
        var entries: [PrefixEntry] = []
        while let path = walker.nextObject() as? String {
            guard entries.count < 16384 else { throw RuntimeFailure.status(.oversized) }
            let url = root.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid() else {
                throw RuntimeFailure.status(.conflict)
            }
            let kind: String
            let value: String
            switch info.st_mode & S_IFMT {
            case S_IFDIR: kind = "directory"; value = ""
            case S_IFLNK: kind = "link"; value = try files.destinationOfSymbolicLink(atPath: url.path)
            case S_IFREG:
                guard info.st_nlink == 1, info.st_size <= 256 << 20 else { throw RuntimeFailure.status(.conflict) }
                kind = "file"; value = try ContentStore.digest(Data(contentsOf: url))
            default: throw RuntimeFailure.status(.conflict)
            }
            entries.append(PrefixEntry(path: path, kind: kind, value: value, mode: info.st_mode & 0o777))
        }
        return try ContentStore.digest(RuntimeEncoding.encode(entries.sorted { $0.path < $1.path }))
    }
}

func privateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw RuntimeFailure.status(.malformed) }
}
