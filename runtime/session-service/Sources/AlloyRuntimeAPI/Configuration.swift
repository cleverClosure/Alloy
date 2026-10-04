// Author: Timur Isaev
import Darwin
import Foundation

/// Development capability. Its containing directory and file must be owner-only.
/// Same-UID malicious code with filesystem access is outside this local boundary.
public struct ServiceConfiguration: Codable, Sendable {
    public let serviceName: String
    public let credential: String
    public let stateRoot: String
    public let contentRoot: String
    public let libraryRoots: [String]?
    public let fixtureMode: Bool?
    public let testFault: String?

    public init(serviceName: String, credential: String, stateRoot: String, contentRoot: String,
                libraryRoots: [String] = [],
                fixtureMode: Bool = false, testFault: String? = nil) {
        self.serviceName = serviceName
        self.credential = credential
        self.stateRoot = stateRoot
        self.contentRoot = contentRoot
        self.libraryRoots = libraryRoots
        self.fixtureMode = fixtureMode
        self.testFault = testFault
    }

    public static func read(_ path: String) throws -> Self {
        let parent = (path as NSString).deletingLastPathComponent
        try validateDirectory(parent)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RuntimeFailure.invalidConfiguration }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 8192 else { throw RuntimeFailure.invalidConfiguration }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw RuntimeFailure.invalidConfiguration }
        let result = try JSONDecoder().decode(Self.self, from: Data(bytes))
        guard result.serviceName.hasPrefix("com.alloy.development."), result.serviceName.count <= 128,
              result.serviceName.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0)
                  || $0 == 46 || $0 == 45 }),
              result.credential.utf8.count == 64,
              result.credential.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RuntimeFailure.invalidConfiguration
        }
        let state = try canonicalPath(result.stateRoot)
        let content = try canonicalPath(result.contentRoot)
        guard state != content,
              !state.hasPrefix(content + "/"), !content.hasPrefix(state + "/") else {
            throw RuntimeFailure.invalidConfiguration
        }
        try validateDirectory(result.stateRoot)
        try validateDirectory(result.contentRoot)
        guard (result.libraryRoots ?? []).count <= 16,
              result.testFault == nil || result.fixtureMode == true else { throw RuntimeFailure.invalidConfiguration }
        for library in result.libraryRoots ?? [] {
            let path = try canonicalPath(library)
            for owned in [state, content] {
                guard path != owned, !path.hasPrefix(owned + "/"), !owned.hasPrefix(path + "/") else {
                    throw RuntimeFailure.invalidConfiguration
                }
            }
        }
        return result
    }

    public static func validateDirectory(_ path: String) throws {
        _ = try canonicalPath(path)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw RuntimeFailure.invalidConfiguration }
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"),
              let resolved = realpath(path, nil) else { throw RuntimeFailure.invalidConfiguration }
        defer { free(resolved) }
        return String(cString: resolved)
    }

}
