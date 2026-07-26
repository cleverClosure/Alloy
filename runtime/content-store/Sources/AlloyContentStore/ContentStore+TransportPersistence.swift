// Author: Timur Isaev

import Darwin
import Foundation

extension ContentStore {
    func verifyTransportPayload(
        _ descriptor: LayerDescriptor,
        at url: URL
    ) throws {
        let data = try Data(contentsOf: url)
        guard data.count == descriptor.size else {
            throw ContentTransportError.sizeMismatch(
                expected: descriptor.size,
                actual: data.count
            )
        }
        let actual = Self.digest(data)
        guard actual == descriptor.digest else {
            throw ContentTransportError.digestMismatch(
                expected: descriptor.digest,
                actual: actual
            )
        }
    }

    func prepareTransportPartialForResume(
        _ url: URL,
        byteCount: Int
    ) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            if errno == ENOENT, byteCount == 0 {
                return
            }
            if errno == ENOENT {
                throw ContentTransportError.invalidResumeOffset(
                    expected: byteCount,
                    actual: 0
                )
            }
            throw ContentStoreError.systemCall(
                operation: "inspect partial for checkpoint recovery",
                code: errno
            )
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw ContentTransportError.invalidPartialFile(url.path)
        }
        guard information.st_size >= off_t(byteCount) else {
            throw ContentTransportError.invalidResumeOffset(
                expected: byteCount,
                actual: Int(information.st_size)
            )
        }
        guard information.st_size > off_t(byteCount) else {
            return
        }

        let descriptor = open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ContentStoreError.systemCall(
                operation: "open partial for checkpoint recovery",
                code: errno
            )
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(byteCount)) == 0,
              fsync(descriptor) == 0 else {
            throw ContentStoreError.systemCall(
                operation: "truncate partial to durable checkpoint",
                code: errno
            )
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    func checkpointTransportOperation(
        _ operationID: String,
        byteCount: Int,
        faultInjector: FaultInjector?
    ) throws {
        var record = try readTransportRecord(operationID)
        guard record.state == .downloading,
              byteCount >= 0,
              byteCount <= record.expectedSize,
              byteCount == 0 || byteCount >= record.byteCount else {
            throw ContentTransportError.invalidRecord(operationID)
        }
        record.byteCount = byteCount
        try writeTransportRecord(record)
        try faultInjector?("after-transport-stream-chunk")
    }

    func publishTransportPayload(
        _ descriptor: LayerDescriptor,
        record: inout TransportRecord,
        faultInjector: FaultInjector?
    ) throws {
        try withExclusiveLock {
            let operation = ActivationOperation(
                operationID: record.operationID,
                gameID: "transport",
                generationID: record.operationID,
                layers: [descriptor],
                healthOutcome: .pass,
                previousActive: nil
            )
            try publishObject(descriptor, index: 0, operation: operation)
            record.state = .published
            try writeTransportRecord(record)
            try faultInjector?("after-transport-publication")
        }
    }

    func prepareTransportOperation(_ initialRecord: TransportRecord) throws {
        try withExclusiveLock {
            let directory = transportDirectory(initialRecord.operationID)
            if pathEntryExists(directory) {
                let existing = try readTransportRecord(initialRecord.operationID)
                guard existing.operationID == initialRecord.operationID,
                      existing.digest == initialRecord.digest,
                      existing.expectedSize == initialRecord.expectedSize,
                      existing.baseURLs == initialRecord.baseURLs else {
                    throw ContentTransportError.invalidRecord(initialRecord.operationID)
                }
                try ensureTransportLockFile(initialRecord.operationID)
                return
            }
            try createDirectory(directory)
            try ensureTransportLockFile(initialRecord.operationID)
            try writeTransportRecord(initialRecord)
            try syncDirectory(downloadsDirectory)
        }
    }

    func readTransportRecord(_ operationID: String) throws -> TransportRecord {
        let url = transportRecordURL(operationID)
        guard isRegularFile(url) else {
            throw ContentTransportError.invalidRecord(operationID)
        }
        let record: TransportRecord
        do {
            record = try decoder.decode(
                TransportRecord.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw ContentTransportError.invalidRecord(operationID)
        }
        guard record.schemaVersion == TransportRecord.currentSchemaVersion else {
            throw ContentStoreError.unsupportedSchema(
                kind: "transport record",
                version: record.schemaVersion
            )
        }
        guard record.kind == TransportRecord.kind,
              record.operationID == operationID,
              record.expectedSize >= 0,
              record.byteCount >= 0,
              record.byteCount <= record.expectedSize,
              !record.baseURLs.isEmpty,
              record.mirrorIndex >= 0,
              record.mirrorIndex < record.baseURLs.count else {
            throw ContentTransportError.invalidRecord(operationID)
        }
        try validateIdentifier(record.operationID)
        _ = try rawSHA256(record.digest)
        for value in record.baseURLs {
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil,
                  url.user == nil,
                  url.password == nil else {
                throw ContentTransportError.invalidRecord(operationID)
            }
        }
        return record
    }

    func ensureTransportLockFile(_ operationID: String) throws {
        try createDirectory(transportLocksDirectory)
        let descriptor = open(
            transportLockURL(operationID).path,
            O_RDWR | O_CREAT,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ContentStoreError.systemCall(
                operation: "create transport operation lock",
                code: errno
            )
        }
        close(descriptor)
    }

    func withTransportOperationLock<T>(
        _ operationID: String,
        body: () throws -> T
    ) throws -> T {
        let descriptor = open(transportLockURL(operationID).path, O_RDWR)
        guard descriptor >= 0 else {
            throw ContentStoreError.systemCall(
                operation: "open transport operation lock",
                code: errno
            )
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ContentStoreError.systemCall(
                operation: "lock transport operation",
                code: errno
            )
        }
        return try body()
    }

    func removeTransportOperation(_ operationID: String) throws {
        try withExclusiveLock {
            let directory = transportDirectory(operationID)
            if pathEntryExists(directory) {
                try fileManager.removeItem(at: directory)
                try syncDirectory(downloadsDirectory)
            }
        }
    }

    func quarantineTransportOperation(
        _ operationID: String,
        digest: String
    ) throws {
        try withExclusiveLock {
            let source = transportDirectory(operationID)
            guard pathEntryExists(source) else {
                return
            }
            let destination = quarantineDirectory.appendingPathComponent(
                "\(try rawSHA256(digest)).\(UUID().uuidString.lowercased()).transport",
                isDirectory: true
            )
            try fileManager.moveItem(at: source, to: destination)
            try syncDirectory(downloadsDirectory)
            try syncDirectory(quarantineDirectory)
        }
    }

    func writeTransportRecord(_ record: TransportRecord) throws {
        try writeAtomic(
            encoder.encode(record),
            to: transportRecordURL(record.operationID)
        )
    }

    func transportDirectory(_ operationID: String) -> URL {
        downloadsDirectory.appendingPathComponent(operationID, isDirectory: true)
    }

    func transportRecordURL(_ operationID: String) -> URL {
        transportDirectory(operationID).appendingPathComponent("transport.json")
    }

    func transportLockURL(_ operationID: String) -> URL {
        transportLocksDirectory.appendingPathComponent("\(operationID).lock")
    }

    var transportLocksDirectory: URL {
        root.appendingPathComponent("metadata/transport-locks", isDirectory: true)
    }

    func transportPayloadURL(
        _ descriptor: LayerDescriptor,
        operationID: String
    ) throws -> URL {
        transportDirectory(operationID).appendingPathComponent(
            "000-\(try rawSHA256(descriptor.digest)).part"
        )
    }

    func protectedTransportOperationIDsUnlocked() throws -> Set<String> {
        var result = Set<String>()
        for directory in try fileManager.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: nil
        ) where isDirectory(directory) {
            let operationID = directory.lastPathComponent
            guard pathEntryExists(transportRecordURL(operationID)) else {
                continue
            }
            _ = try readTransportRecord(operationID)
            result.insert(operationID)
        }
        return result
    }
}
