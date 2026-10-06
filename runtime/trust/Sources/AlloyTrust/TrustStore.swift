// Author: Timur Isaev

import Darwin
import Foundation

struct TrustState: Codable {
    var rotations: [Data] = []
    var root: Data
    var pin: String
    var lastTime: Double
    var versions: [String: AcceptedVersion] = [:]
    var bundle: MetadataBundle?
    var revokedKeys: Set<String> = []
    var revokedProfiles: Set<ProfileRevision> = []
    var revokedDigests: Set<String> = []
}

/// Per-user local state. Pin comes from a trusted out-of-band development channel.
/// A removed/corrupt state file is an error; only explicit bootstrap creates one.
public struct TrustStore: Sendable {
    public let directory: URL
    public let pinnedRootDigest: String

    public init(directory: URL, pinnedRootDigest: String) {
        self.directory = directory
        self.pinnedRootDigest = pinnedRootDigest
    }

    public static func bootstrap(
        directory: URL, root: Data, pinnedRootDigest: String, now: Date
    ) throws -> Self {
        guard TrustCanonicalJSON.digest(root) == pinnedRootDigest else { throw TrustError.invalidRoot }
        _ = try ChainValidation.root(root, now: now)
        // Never reset an existing directory's high-water marks.
        guard mkdir(directory.path, 0o700) == 0 else { throw TrustError.state("bootstrap requires new directory") }
        let store = Self(directory: directory, pinnedRootDigest: pinnedRootDigest)
        try store.locked {
            try store.save(TrustState(root: root, pin: pinnedRootDigest, lastTime: now.timeIntervalSince1970))
        }
        return store
    }

    public func refresh(_ bundle: MetadataBundle, now: Date) throws {
        try locked {
            var state = try load(now: now)
            let root = try ChainValidation.currentRoot(state, now: now)
            let (verifier, versions) = try ChainValidation.verify(
                bundle, root: root, state: state, now: now
            )
            state.bundle = bundle
            state.versions = versions
            state.revokedKeys = verifier.revokedKeys
            state.revokedProfiles = verifier.revokedProfiles
            state.revokedDigests = verifier.revokedDigests
            try save(state)
        }
    }

    /// The lock spans the consumer closure so a refresh cannot interleave with a
    /// launch compilation. Do not re-enter this store or retain the verifier.
    public func withVerifier<T>(now: Date, _ body: (TrustVerifier) throws -> T) throws -> T {
        try locked {
            let state = try load(now: now)
            guard let bundle = state.bundle else { throw TrustError.state("metadata not initialized") }
            let root = try ChainValidation.currentRoot(state, now: now)
            let (verifier, _) = try ChainValidation.verify(
                bundle, root: root, state: state, now: now
            )
            defer { verifier.lease.end() }
            return try body(verifier)
        }
    }

    public func verify(_ bytes: Data, type: String, now: Date) throws -> TrustedPayload {
        try withVerifier(now: now) { try $0.verify(bytes, type: type) }
    }

    func load(now: Date) throws -> TrustState {
        let fd = open(directory.appendingPathComponent("state.json").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TrustError.state("missing state") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 16 * 1024 * 1024 else {
            throw TrustError.state("unsafe state file")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let bytes = try handle.readToEnd() else { throw TrustError.state("empty state") }
        var state = try JSONDecoder().decode(TrustState.self, from: bytes)
        guard state.pin == pinnedRootDigest, TrustCanonicalJSON.digest(state.root) == pinnedRootDigest else {
            throw TrustError.invalidRoot
        }
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= state.lastTime else {
            throw TrustError.freeze
        }
        // Persist observed time even when untrusted input later fails. Rolling
        // the clock back must not resurrect an expiry already observed.
        state.lastTime = now.timeIntervalSince1970
        try save(state)
        return state
    }

    func locked<T>(_ body: () throws -> T) throws -> T {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TrustError.state("unsafe state directory")
        }
        let fd = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TrustError.state("lock open") }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, flock(fd, LOCK_EX) == 0 else { throw TrustError.state("lock") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    func save(_ state: TrustState) throws {
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= 16 * 1024 * 1024 else { throw TrustError.state("state size bound") }
        let temporary = directory.appendingPathComponent(".state-\(UUID().uuidString)")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TrustError.state("state create") }
        defer { close(fd); unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: bytes)
        guard fsync(fd) == 0, rename(temporary.path, directory.appendingPathComponent("state.json").path) == 0 else {
            throw TrustError.state("state commit")
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw TrustError.state("directory sync open") }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw TrustError.state("directory sync") }
    }
}
