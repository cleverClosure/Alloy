// Author: Timur Isaev

import CryptoKit
import Darwin
import Foundation

final class Directory {
    let descriptor: Int32
    let device: dev_t

    init(descriptor: Int32, privateMode: Bool = true) throws {
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw VolumeError.systemCall("open directory", errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & (privateMode ? 0o077 : 0o022) == 0 else {
            close(descriptor)
            throw VolumeError.unsafePath
        }
        self.descriptor = descriptor
        device = info.st_dev
    }

    deinit { close(descriptor) }

    static func root(_ url: URL) throws -> Directory {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/" else { throw VolumeError.unsafePath }
        let components = url.path.split(separator: "/").map(String.init)
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw VolumeError.systemCall("open root", errno) }
        for (index, component) in components.enumerated() {
            if index == components.count - 1, mkdirat(current, component, 0o700) != 0, errno != EEXIST {
                let code = errno
                close(current)
                throw VolumeError.systemCall("mkdir root", code)
            }
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw VolumeError.unsafePath }
            current = next
        }
        return try Directory(descriptor: current, privateMode: false)
    }

    func child(_ name: String, create: Bool = false, privateMode: Bool = true) throws -> Directory {
        try component(name)
        if create {
            try rejectAlias(name)
            if mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST {
                throw VolumeError.systemCall("mkdir", errno)
            }
            try sync()
        }
        let result = try Directory(descriptor: openat(
            descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ), privateMode: privateMode)
        guard result.device == device else { throw VolumeError.unsafePath }
        return result
    }

    func directory(_ path: String, create: Bool = false) throws -> Directory {
        var current = self
        for part in try relativeComponents(path) { current = try current.child(part, create: create) }
        return current
    }

    func information(_ name: String) throws -> stat? {
        try component(name)
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw VolumeError.systemCall("fstatat", errno)
        }
        return info
    }

    func names() throws -> [String] {
        let copied = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copied >= 0 else { throw VolumeError.systemCall("open enumeration", errno) }
        guard let stream = fdopendir(copied) else {
            close(copied)
            throw VolumeError.systemCall("fdopendir", errno)
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= 10_000 else { throw VolumeError.quotaExceeded }
            errno = 0
        }
        guard errno == 0 else { throw VolumeError.systemCall("readdir", errno) }
        let folded = result.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(folded).count == result.count else { throw VolumeError.unsafePath }
        return result.sorted()
    }

    func rejectAlias(_ name: String) throws {
        let folded = name.precomposedStringWithCanonicalMapping.lowercased()
        guard try !names().contains(where: { $0 != name && $0.lowercased() == folded }) else {
            throw VolumeError.unsafePath
        }
    }

    func file(_ name: String) throws -> Int32 {
        try component(name)
        let handle = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard handle >= 0 else { throw VolumeError.unsafeFile }
        var info = stat()
        guard fstat(handle, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_dev == device,
              info.st_mode & 0o077 == 0 else {
            close(handle)
            throw VolumeError.unsafeFile
        }
        return handle
    }

    func read(_ name: String, limit: Int = 8 << 20) throws -> Data {
        let handle = try file(name)
        defer { close(handle) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(handle, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw VolumeError.systemCall("read", errno) }
            if count == 0 { return data }
            guard data.count <= limit - count else { throw VolumeError.quotaExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    func write(_ name: String, data: Data, exclusive: Bool = false) throws {
        try component(name)
        try rejectAlias(name)
        if let info = try information(name) {
            guard !exclusive, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw VolumeError.unsafeFile
            }
        }
        let temporary = ".tmp-\(UUID().uuidString.lowercased())"
        let handle = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard handle >= 0 else { throw VolumeError.systemCall("create file", errno) }
        defer {
            close(handle)
            unlinkat(descriptor, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { throw VolumeError.integrityMismatch }
                let count = Darwin.write(handle, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw VolumeError.systemCall("write", errno) }
                offset += count
            }
        }
        guard fsync(handle) == 0 else { throw VolumeError.systemCall("fsync file", errno) }
        guard renameat(descriptor, temporary, descriptor, name) == 0 else {
            throw VolumeError.systemCall("rename file", errno)
        }
        try sync()
    }

    func sync() throws {
        guard fsync(descriptor) == 0 else { throw VolumeError.systemCall("fsync directory", errno) }
    }

    func remove(_ name: String) throws {
        guard let info = try information(name) else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            let nested = try child(name)
            for entry in try nested.names() { try nested.remove(entry) }
            guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                throw VolumeError.systemCall("remove directory", errno)
            }
        } else {
            let handle = try file(name)
            close(handle)
            guard unlinkat(descriptor, name, 0) == 0 else { throw VolumeError.systemCall("unlink", errno) }
        }
        try sync()
    }

    private func component(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\0"), name.utf8.count <= 255 else { throw VolumeError.unsafePath }
    }
}
