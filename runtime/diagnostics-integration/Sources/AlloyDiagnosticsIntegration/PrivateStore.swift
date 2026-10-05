// Author: Timur Isaev
import Darwin
import Foundation

public enum PrivateStore {
    public static func directory(_ path: URL) throws {
        guard path.isFileURL, path.path.hasPrefix("/"), !path.path.contains("\0"),
              path.standardizedFileURL.path == path.resolvingSymlinksInPath().path else {
            throw IntegrationError.unsafeDestination
        }
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw IntegrationError.unsafeDestination
        }
    }

    public static func newDestination(_ path: URL) throws {
        try directory(path.deletingLastPathComponent())
        guard path.lastPathComponent != ".", path.lastPathComponent != "..",
              path.standardizedFileURL.path == path.path else { throw IntegrationError.unsafeDestination }
        var info = stat()
        guard lstat(path.path, &info) != 0, errno == ENOENT else { throw IntegrationError.unsafeDestination }
    }

    public static func read(_ file: URL, limit: Int = 1_048_576) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw IntegrationError.invalidBundle }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else { throw IntegrationError.invalidBundle }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, result.count + count <= limit else { throw IntegrationError.invalidBundle }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    public static func writeNew(_ data: Data, to file: URL) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw IntegrationError.unsafeDestination }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: written), bytes.count - written)
                guard count > 0 else { throw IntegrationError.invalidBundle }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw IntegrationError.invalidBundle }
    }
}
