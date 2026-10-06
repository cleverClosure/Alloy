// Author: Timur Isaev

import Darwin
import Foundation

extension Directory {
    func cloneTree(to destination: Directory, inventory: TreeInventory,
                   afterFile: () throws -> Void = {}) throws -> (cloned: Int, copied: Int) {
        var cloned = 0
        var copied = 0
        for entry in inventory.entries {
            let components = try relativeComponents(entry.path)
            if entry.sha256 == nil {
                _ = try destination.directory(entry.path, create: true)
                continue
            }
            var sourceParent = self
            var targetParent = destination
            for part in components.dropLast() {
                sourceParent = try sourceParent.child(part)
                targetParent = try targetParent.child(part, create: true)
            }
            let name = components[components.count - 1]
            let source = try sourceParent.file(name)
            defer { close(source) }
            if fclonefileat(source, targetParent.descriptor, name, 0) == 0 {
                cloned += 1
            } else {
                guard [ENOTSUP, EXDEV].contains(errno) else { throw VolumeError.systemCall("clonefile", errno) }
                try copyFile(source, to: targetParent, name: name)
                copied += 1
            }
            let output = try targetParent.file(name)
            defer { close(output) }
            guard fsync(output) == 0 else { throw VolumeError.systemCall("sync clone", errno) }
            try targetParent.sync()
            try afterFile()
        }
        try destination.sync()
        return (cloned, copied)
    }

    private func copyFile(_ source: Int32, to target: Directory, name: String) throws {
        let output = openat(target.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw VolumeError.systemCall("create copy", errno) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw VolumeError.systemCall("read copy", errno) }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { throw VolumeError.integrityMismatch }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, address.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw VolumeError.systemCall("write copy", errno) }
                    offset += written
                }
            }
        }
        guard fsync(output) == 0 else { throw VolumeError.systemCall("sync copy", errno) }
    }
}
