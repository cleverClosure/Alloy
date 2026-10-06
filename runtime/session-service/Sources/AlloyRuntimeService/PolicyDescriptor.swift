// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import Darwin
import Foundation

/// No writable handle or pathname survives publication of the policy transport.
final class PolicyDescriptor {
    static let inheritedFD: Int32 = 198
    let descriptor: Int32
    let digest: String

    init(bytes: Data, expectedDigest: String, directory: URL) throws {
        guard bytes.count <= 8 << 20, ContentStore.digest(bytes) == expectedDigest else {
            throw RuntimeFailure.status(.policyIntegrity)
        }
        let path = directory.appendingPathComponent(".snapshot-" + UUID().uuidString).path
        let writer = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard writer >= 0 else { throw RuntimeFailure.status(.failed) }
        defer { unlink(path) }
        do {
            let count = bytes.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }
            guard count == bytes.count, fsync(writer) == 0, fchmod(writer, 0o400) == 0 else {
                throw RuntimeFailure.status(.failed)
            }
        } catch { close(writer); throw error }
        close(writer)
        let reader = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard reader >= 0 else { throw RuntimeFailure.status(.failed) }
        descriptor = reader
        digest = expectedDigest
    }

    deinit { close(descriptor) }

    func environment(_ base: [String: String]) -> [String: String] {
        var result = base
        result["ALLOY_POLICY_SNAPSHOT_FD"] = String(Self.inheritedFD)
        result["ALLOY_POLICY_SNAPSHOT_SHA256"] = String(digest.dropFirst(7))
        result["ALLOY_POLICY_REQUIRED"] = "1"
        return result
    }
}

struct SpawnedWine {
    let identity: LeaseProcessIdentity
    let processID: Int32

    static func start(executable: URL, arguments: [String], environment: [String: String],
                      policy: PolicyDescriptor, log: Int32) throws -> Self {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw RuntimeFailure.status(.failed)
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, log, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, log, STDERR_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, policy.descriptor, PolicyDescriptor.inheritedFD) == 0 else {
            throw RuntimeFailure.status(.failed)
        }
        var processID: pid_t = 0
        let status = cStrings([executable.path] + arguments) { argv in
            let values = policy.environment(environment).sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
            return cStrings(values) { env in
                posix_spawn(&processID, executable.path, &actions, &attributes, argv, env)
            }
        }
        guard status == 0 else { throw RuntimeFailure.status(.failed) }
        guard let identity = NativeProcessIdentity.current(processID) else {
            // This PID is still our unreaped child, so it cannot have been reused.
            kill(processID, SIGKILL)
            var exitStatus: Int32 = 0
            waitpid(processID, &exitStatus, 0)
            throw RuntimeFailure.status(.failed)
        }
        return Self(identity: identity, processID: processID)
    }

    func pollExit() -> Int32? {
        var status: Int32 = 0
        guard waitpid(processID, &status, WNOHANG) == processID else { return nil }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}

private func cStrings<T>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
