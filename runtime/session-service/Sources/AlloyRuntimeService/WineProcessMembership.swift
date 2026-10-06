// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation

/// The trace supplies a Unix PID, not authority to signal a reused PID. Bind a
/// live birth identity to the exact loader and prefix through kernel procargs.
enum WineProcessMembership {
    static func observe(_ pid: Int32, executable: URL, prefix: URL) -> LeaseProcessIdentity? {
        guard let identity = NativeProcessIdentity.current(pid) else { return nil }
        var names: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: 1 << 20)
        var size = bytes.count
        let status = names.withUnsafeMutableBufferPointer { names in
            bytes.withUnsafeMutableBytes { buffer in
                sysctl(names.baseAddress, u_int(names.count), buffer.baseAddress, &size, nil, 0)
            }
        }
        guard status == 0, matchesProcargs(bytes, count: size, executable: executable, prefix: prefix),
              NativeProcessIdentity.isLive(identity) else { return nil }
        return identity
    }

    static func matchesProcargs(_ bytes: [UInt8], count size: Int, executable: URL, prefix: URL) -> Bool {
        guard size > 4, size <= bytes.count, size <= 1 << 20 else { return false }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return false }
        var cursor = 4
        func string() -> String? {
            guard cursor < size, let end = bytes[cursor..<size].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(bytes: bytes[cursor..<end], encoding: .utf8)
        }
        guard let image = string(), canonical(image) == canonical(executable.path) else { return false }
        while cursor < size, bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc { guard string() != nil else { return false } }
        // Wine's rebuild_argv shifts its strings and zero-fills the removed
        // loader argument without changing the kernel's original argc. The
        // retained environment begins after that NUL padding.
        while cursor < size, bytes[cursor] == 0 { cursor += 1 }
        var matched = false
        while cursor < size, let value = string(), !value.isEmpty {
            if value.hasPrefix("WINEPREFIX=") {
                matched = canonical(String(value.dropFirst(11))) == canonical(prefix.path)
                break
            }
        }
        return matched
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
