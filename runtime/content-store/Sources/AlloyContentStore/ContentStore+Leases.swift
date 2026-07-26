// Author: Timur Isaev

import Darwin
import Foundation

extension ContentStore {
    /// Durably pins every CAS object referenced by a generation for this process.
    ///
    /// When `generation` is nil, the game's current active generation is leased.
    /// A caller must acquire the lease before exposing generation paths to a
    /// launcher and explicitly release it after the launched process has exited.
    public func acquireLease(
        gameID: String,
        generation: GenerationReference? = nil,
        holderProcessID: Int32? = nil
    ) throws -> GenerationLease {
        try validateIdentifier(gameID)
        return try withExclusiveLock {
            let selected = try generation ?? readReference(.active, gameID: gameID)
            guard let selected else {
                throw ContentStoreError.missingReference("active")
            }
            let processID = holderProcessID ?? Int32(getpid())
            return try acquireLeaseUnlocked(
                gameID: gameID,
                generation: selected,
                holder: requireProcessIdentity(pid_t(processID)),
                createdAtUnixSeconds: Int64(Date().timeIntervalSince1970)
            )
        }
    }

    /// Releases a previously acquired lease. Releasing an already absent lease
    /// is safe so cleanup can be retried after uncertain caller failures.
    public func releaseLease(_ lease: GenerationLease) throws {
        try validateIdentifier(lease.leaseID)
        try withExclusiveLock {
            let url = leaseURL(lease.leaseID)
            guard pathEntryExists(url) else {
                return
            }
            let persisted = try readLease(url)
            guard persisted == lease else {
                throw ContentStoreError.invalidLease(lease.leaseID)
            }
            try fileManager.removeItem(at: url)
            try syncDirectory(leasesDirectory)
        }
    }

    /// Returns live leases after atomically removing records whose exact process
    /// identity no longer exists. Timestamps never decide liveness.
    public func liveLeases() throws -> [GenerationLease] {
        try withExclusiveLock {
            try liveLeaseRecordsPruningStaleUnlocked()
        }
    }

    func acquireLeaseUnlocked(
        gameID: String,
        generation: GenerationReference,
        holder: LeaseProcessIdentity,
        createdAtUnixSeconds: Int64,
        leaseID: String = UUID().uuidString.lowercased()
    ) throws -> GenerationLease {
        try validateIdentifier(leaseID)
        try validateReference(generation, gameID: gameID)
        let manifest = try readGenerationManifest(generation, gameID: gameID)
        let objectDigests = Array(Set(manifest.layers.map(\.digest))).sorted()
        let lease = GenerationLease(
            leaseID: leaseID,
            gameID: gameID,
            generation: generation,
            objectDigests: objectDigests,
            holder: holder,
            createdAtUnixSeconds: createdAtUnixSeconds
        )

        try createDirectory(leasesDirectory)
        try writeAtomic(encoder.encode(lease), to: leaseURL(leaseID))
        return lease
    }

    func liveLeaseRecordsPruningStaleUnlocked() throws -> [GenerationLease] {
        try createDirectory(leasesDirectory)
        let urls = try fileManager.contentsOfDirectory(
            at: leasesDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }

        var live: [GenerationLease] = []
        var removedAny = false
        for url in urls {
            let lease = try readLease(url)
            if processIdentityIsLive(lease.holder) {
                live.append(lease)
            } else {
                try fileManager.removeItem(at: url)
                removedAny = true
            }
        }
        if removedAny {
            try syncDirectory(leasesDirectory)
        }
        return live
    }

    func liveLeaseObjectDigestsPruningStaleUnlocked() throws -> Set<String> {
        Set(try liveLeaseRecordsPruningStaleUnlocked().flatMap(\.objectDigests))
    }

    func readLease(_ url: URL) throws -> GenerationLease {
        let leaseID = url.deletingPathExtension().lastPathComponent
        guard isRegularFile(url) else {
            throw ContentStoreError.invalidLease(leaseID)
        }

        let data = try Data(contentsOf: url)
        try validateLeaseDocumentShape(data, leaseID: leaseID)
        let lease: GenerationLease
        do {
            lease = try decoder.decode(GenerationLease.self, from: data)
        } catch {
            throw ContentStoreError.invalidLease(leaseID)
        }
        guard lease.schemaVersion == GenerationLease.currentSchemaVersion else {
            throw ContentStoreError.unsupportedSchema(
                kind: "generation lease",
                version: lease.schemaVersion
            )
        }
        guard url.deletingPathExtension().lastPathComponent == lease.leaseID else {
            throw ContentStoreError.invalidLease(lease.leaseID)
        }
        try validateIdentifier(lease.leaseID)
        try validateIdentifier(lease.gameID)
        try validateIdentifier(lease.generationID)
        _ = try rawSHA256(lease.manifestDigest)
        guard !lease.objectDigests.isEmpty,
              lease.objectDigests == Array(Set(lease.objectDigests)).sorted(),
              lease.holder.processID > 0,
              lease.holder.startTimeMicroseconds < 1_000_000 else {
            throw ContentStoreError.invalidLease(lease.leaseID)
        }
        for digest in lease.objectDigests {
            _ = try rawSHA256(digest)
        }
        return lease
    }

    func validateLeaseDocumentShape(_ data: Data, leaseID: String) throws {
        let document = try? JSONSerialization.jsonObject(with: data)
        guard let object = document as? [String: Any],
              Set(object.keys) == [
                  "schemaVersion",
                  "leaseId",
                  "gameId",
                  "generationId",
                  "manifestDigest",
                  "objectDigests",
                  "holder",
                  "createdAtUnixSeconds"
              ],
              let holder = object["holder"] as? [String: Any],
              Set(holder.keys) == [
                  "processId",
                  "startTimeSeconds",
                  "startTimeMicroseconds"
              ] else {
            throw ContentStoreError.invalidLease(leaseID)
        }
    }

    func readGenerationManifest(
        _ generation: GenerationReference,
        gameID: String
    ) throws -> GenerationManifest {
        let url = generationURL(
            gameID: gameID,
            generationID: generation.generationID
        ).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        guard Self.digest(data) == generation.manifestDigest else {
            throw ContentStoreError.digestMismatch(
                expected: generation.manifestDigest,
                actual: Self.digest(data)
            )
        }
        return try decoder.decode(GenerationManifest.self, from: data)
    }

    func requireProcessIdentity(_ processID: pid_t) throws -> LeaseProcessIdentity {
        guard let identity = processIdentity(processID) else {
            throw ContentStoreError.processIdentityUnavailable(Int32(processID))
        }
        return identity
    }

    func processIdentity(_ processID: pid_t) -> LeaseProcessIdentity? {
        switch processState(processID) {
        case let .live(identity):
            identity
        case .dead, .unknown:
            nil
        }
    }

    func processIdentityIsLive(_ identity: LeaseProcessIdentity) -> Bool {
        switch processState(pid_t(identity.processID)) {
        case let .live(current):
            current == identity
        case .dead:
            false
        case .unknown:
            // Never collect a live launch merely because a kernel identity
            // query failed transiently.
            true
        }
    }

    func processState(_ processID: pid_t) -> LeaseProcessState {
        guard processID > 0 else {
            return .dead
        }
        var names: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        errno = 0
        let result = names.withUnsafeMutableBufferPointer { buffer in
            sysctl(
                buffer.baseAddress,
                u_int(buffer.count),
                &information,
                &size,
                nil,
                0
            )
        }
        guard result == 0 else {
            return errno == ESRCH || errno == ENOENT ? .dead : .unknown
        }
        guard size != 0 else {
            return .dead
        }
        guard size == MemoryLayout<kinfo_proc>.size,
              information.kp_proc.p_pid == processID else {
            return .unknown
        }
        guard information.kp_proc.p_stat != SZOMB else {
            return .dead
        }
        let startTime = information.kp_proc.p_un.__p_starttime
        guard startTime.tv_sec >= 0,
              startTime.tv_usec >= 0,
              startTime.tv_usec < 1_000_000 else {
            return .unknown
        }
        return .live(LeaseProcessIdentity(
            processID: Int32(processID),
            startTimeSeconds: UInt64(startTime.tv_sec),
            startTimeMicroseconds: UInt32(startTime.tv_usec)
        ))
    }

    func leaseURL(_ leaseID: String) -> URL {
        leasesDirectory.appendingPathComponent("\(leaseID).json")
    }

    var leasesDirectory: URL {
        root.appendingPathComponent("metadata/leases", isDirectory: true)
    }
}

enum LeaseProcessState {
    case live(LeaseProcessIdentity)
    case dead
    case unknown
}
