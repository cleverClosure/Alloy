// Author: Timur Isaev
import AlloyRuntimeAPI
import Darwin
import Foundation

/// Only empty directories or roots previously initialized here can be adopted.
/// The marker is ownership metadata, not an authentication signature.
enum OwnedRoots {
    static func prepare(_ path: String) throws {
        try ServiceConfiguration.validateDirectory(path)
        let root = URL(fileURLWithPath: path)
        let marker = root.appendingPathComponent(".alloy-runtime-service-v1")
        let bytes = Data("alloy-private-runtime-root-v1\n".utf8)
        if FileManager.default.fileExists(atPath: marker.path) {
            let descriptor = open(marker.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw RuntimeFailure.invalidConfiguration }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_size == bytes.count else {
                throw RuntimeFailure.invalidConfiguration
            }
            var readBytes = [UInt8](repeating: 0, count: bytes.count)
            let count = readBytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard count == bytes.count, Data(readBytes) == bytes else { throw RuntimeFailure.invalidConfiguration }
        } else {
            guard try FileManager.default.contentsOfDirectory(atPath: path).isEmpty else {
                throw RuntimeFailure.invalidConfiguration
            }
            let descriptor = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw RuntimeFailure.invalidConfiguration }
            defer { close(descriptor) }
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard count == bytes.count, fsync(descriptor) == 0 else { throw RuntimeFailure.invalidConfiguration }
        }
    }
}
