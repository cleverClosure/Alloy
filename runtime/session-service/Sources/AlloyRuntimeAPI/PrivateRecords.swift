// Author: Timur Isaev
import AlloyContentStore
import Darwin
import Foundation

/// Bounded private development records, atomically replaced and synced.
public enum PrivateRecords {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try RuntimeEncoding.encode(value)
        guard data.count <= RuntimeLimits.messageBytes else { throw RuntimeFailure.status(.oversized) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RuntimeFailure.status(.failed) }
        defer { close(descriptor); unlink(temporary.path) }
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            throw RuntimeFailure.status(.failed)
        }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw RuntimeFailure.status(.failed) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw RuntimeFailure.status(.failed) }
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RuntimeFailure.status(.notFound) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size >= 0,
              info.st_size <= RuntimeLimits.messageBytes else { throw RuntimeFailure.status(.malformed) }
        var data = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { throw RuntimeFailure.status(.malformed) }
        return try JSONDecoder().decode(type, from: Data(data))
    }
}

public enum NativeProcessIdentity {
    private enum State { case live(LeaseProcessIdentity), dead, unknown }

    private static func state(_ processID: Int32) -> State {
        guard processID > 0 else { return .dead }
        var names: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = names.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, u_int($0.count), &information, &size, nil, 0)
        }
        guard result == 0 else { return errno == ESRCH || errno == ENOENT ? .dead : .unknown }
        guard size != 0 else { return .dead }
        guard size == MemoryLayout<kinfo_proc>.size, information.kp_proc.p_pid == processID else { return .unknown }
        guard information.kp_proc.p_stat != SZOMB else { return .dead }
        let start = information.kp_proc.p_un.__p_starttime
        guard start.tv_sec >= 0, start.tv_usec >= 0, start.tv_usec < 1_000_000 else { return .unknown }
        return .live(LeaseProcessIdentity(processID: processID, startTimeSeconds: UInt64(start.tv_sec),
                                          startTimeMicroseconds: UInt32(start.tv_usec)))
    }

    public static func current(_ processID: Int32) -> LeaseProcessIdentity? {
        if case let .live(identity) = state(processID) { return identity }
        return nil
    }

    public static func isLive(_ identity: LeaseProcessIdentity) -> Bool { current(identity.processID) == identity }

    public static func mayStillBeLive(_ identity: LeaseProcessIdentity) -> Bool {
        switch state(identity.processID) {
        case .live(let observed): observed == identity
        case .dead: false
        case .unknown: true
        }
    }
}
