// Author: Timur Isaev
import Darwin
import Foundation

/// Only UI preferences belong here. Endpoint credentials and service payloads never do.
public struct PreferencesStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func read() throws -> ClientPreferences {
        try prepareDirectory()
        let path = directory.appendingPathComponent("preferences.json").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return ClientPreferences() }
        guard descriptor >= 0 else { throw PreferencesError.unsafeStorage }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0,
              metadata.st_size <= 65_536 else { throw PreferencesError.unsafeStorage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.readToEnd() ?? Data()
        return try JSONDecoder().decode(ClientPreferences.self, from: bytes)
    }

    public func write(_ preferences: ClientPreferences) throws {
        try prepareDirectory()
        let bytes = try JSONEncoder().encode(preferences)
        let temporary = directory.appendingPathComponent(".preferences-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PreferencesError.unsafeStorage }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        guard rename(temporary.path, directory.appendingPathComponent("preferences.json").path) == 0 else {
            throw PreferencesError.unsafeStorage
        }
    }

    private func prepareDirectory() throws {
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else { throw PreferencesError.unsafeStorage }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &metadata) == 0 else { throw PreferencesError.unsafeStorage }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else {
            throw PreferencesError.unsafeStorage
        }
    }
}

public enum PreferencesError: Error { case unsafeStorage }
