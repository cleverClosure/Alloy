// Author: Timur Isaev

import Darwin
import Foundation

extension ContentStore {
    /// Fetches one caller-authorized descriptor from ordered mirrors and
    /// publishes it through the same hard-link CAS path used by activation.
    @discardableResult
    public func fetchObject(
        _ descriptor: LayerDescriptor,
        from baseURLs: [URL],
        operationID requestedOperationID: String? = nil,
        deadline: TimeInterval = 30,
        faultInjector: FaultInjector? = nil
    ) throws -> TransportResult {
        let operationID = try validateTransportInputs(
            descriptor,
            baseURLs: baseURLs,
            requestedOperationID: requestedOperationID,
            deadline: deadline
        )
        if let existing = try existingTransportResult(
            descriptor,
            operationID: operationID,
            cleanupMatchingOperation: false
        ) {
            return existing
        }

        let initialRecord = TransportRecord(
            operationID: operationID,
            descriptor: descriptor,
            baseURLs: baseURLs
        )
        try prepareTransportOperation(initialRecord)
        return try withTransportOperationLock(operationID) {
            try resumeTransportOperation(
                descriptor,
                baseURLs: baseURLs,
                deadline: deadline,
                operationID: operationID,
                faultInjector: faultInjector
            )
        }
    }

    func validateTransportInputs(
        _ descriptor: LayerDescriptor,
        baseURLs: [URL],
        requestedOperationID: String?,
        deadline: TimeInterval
    ) throws -> String {
        try validateLayerDescriptor(descriptor)
        guard !baseURLs.isEmpty else {
            throw ContentTransportError.noBaseURLs
        }
        for baseURL in baseURLs {
            guard let scheme = baseURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  baseURL.host != nil,
                  baseURL.user == nil,
                  baseURL.password == nil else {
                throw ContentTransportError.invalidBaseURL(baseURL.absoluteString)
            }
        }
        guard deadline > 0 else {
            throw ContentTransportError.deadlineExceeded
        }
        let rawDigest = try rawSHA256(descriptor.digest)
        let operationID = requestedOperationID ?? "fetch-\(rawDigest)"
        try validateIdentifier(operationID)
        return operationID
    }

    func resumeTransportOperation(
        _ descriptor: LayerDescriptor,
        baseURLs: [URL],
        deadline: TimeInterval,
        operationID: String,
        faultInjector: FaultInjector?
    ) throws -> TransportResult {
        if let existing = try existingTransportResult(
            descriptor,
            operationID: operationID,
            cleanupMatchingOperation: true
        ) {
            return existing
        }
        var record = try readTransportRecord(operationID)
        guard record.digest == descriptor.digest,
              record.expectedSize == descriptor.size,
              record.baseURLs == baseURLs.map(\.absoluteString) else {
            throw ContentTransportError.invalidRecord(operationID)
        }
        if record.state == .downloaded || record.state == .verified {
            return try finishTransportPublication(
                descriptor,
                record: &record,
                faultInjector: faultInjector
            )
        }
        guard record.state == .downloading else {
            throw ContentTransportError.invalidRecord(operationID)
        }
        return try downloadTransportObject(
            descriptor,
            baseURLs: baseURLs,
            deadline: deadline,
            record: &record,
            faultInjector: faultInjector
        )
    }

    func downloadTransportObject(
        _ descriptor: LayerDescriptor,
        baseURLs: [URL],
        deadline: TimeInterval,
        record: inout TransportRecord,
        faultInjector: FaultInjector?
    ) throws -> TransportResult {
        let rawDigest = try rawSHA256(descriptor.digest)
        var failures: [String] = []
        for (index, baseURL) in baseURLs.enumerated() {
            let sourceURL = baseURL
                .appendingPathComponent("sha256", isDirectory: true)
                .appendingPathComponent(rawDigest, isDirectory: false)
            record.mirrorIndex = index
            record.sourceURL = sourceURL.absoluteString
            try writeTransportRecord(record)

            do {
                return try attemptTransportMirror(
                    descriptor,
                    sourceURL: sourceURL,
                    deadline: deadline,
                    record: &record,
                    faultInjector: faultInjector
                )
            } catch let error as ContentTransportError {
                switch error {
                case .digestMismatch, .sizeMismatch:
                    throw error
                default:
                    failures.append(error.description)
                }
            } catch let error as ContentStoreError {
                throw error
            } catch {
                failures.append(ContentTransportError.requestFailed(
                    url: sourceURL.absoluteString,
                    reason: String(describing: error)
                ).description)
            }
        }

        throw ContentTransportError.allMirrorsFailed(failures)
    }

    func attemptTransportMirror(
        _ descriptor: LayerDescriptor,
        sourceURL: URL,
        deadline: TimeInterval,
        record: inout TransportRecord,
        faultInjector: FaultInjector?
    ) throws -> TransportResult {
        let response = try requestTransportData(from: sourceURL, deadline: deadline)
        guard (200..<300).contains(response.statusCode) else {
            throw ContentTransportError.httpStatus(
                url: sourceURL.absoluteString,
                statusCode: response.statusCode
            )
        }
        let stagedURL = try transportPayloadURL(
            descriptor,
            operationID: record.operationID
        )
        try writeDurable(response.data, to: stagedURL, exclusive: true)
        try syncDirectory(transportDirectory(record.operationID))
        record.byteCount = response.data.count
        record.state = .downloaded
        try writeTransportRecord(record)
        do {
            try verifyTransportPayload(descriptor, at: stagedURL)
        } catch {
            try quarantineTransportOperation(
                record.operationID,
                digest: descriptor.digest
            )
            throw error
        }
        return try finishTransportPublication(
            descriptor,
            record: &record,
            faultInjector: faultInjector
        )
    }

    func finishTransportPublication(
        _ descriptor: LayerDescriptor,
        record: inout TransportRecord,
        faultInjector: FaultInjector?
    ) throws -> TransportResult {
        let stagedURL = try transportPayloadURL(
            descriptor,
            operationID: record.operationID
        )
        if record.state == .downloaded {
            try verifyTransportPayload(descriptor, at: stagedURL)
            record.state = .verified
            try writeTransportRecord(record)
        }
        guard record.state == .verified else {
            throw ContentTransportError.invalidRecord(record.operationID)
        }

        try publishTransportPayload(descriptor, record: &record)
        try faultInjector?("after-transport-publication")
        try removeTransportOperation(record.operationID)
        return TransportResult(
            digest: descriptor.digest,
            objectURL: try objectURL(descriptor.digest),
            sourceURL: record.sourceURL.flatMap(URL.init(string:)),
            mirrorIndex: record.mirrorIndex,
            bytesTransferred: record.byteCount,
            resumedFromByteCount: 0,
            reusedExistingObject: false
        )
    }

    func existingTransportResult(
        _ descriptor: LayerDescriptor,
        operationID: String,
        cleanupMatchingOperation: Bool
    ) throws -> TransportResult? {
        try withExclusiveLock {
            guard (try? validateObject(descriptor)) != nil else {
                return nil
            }
            let directory = transportDirectory(operationID)
            if pathEntryExists(directory) {
                guard cleanupMatchingOperation else {
                    return nil
                }
                if let record = try? readTransportRecord(operationID),
                   record.operationID == operationID,
                   record.digest == descriptor.digest {
                    try fileManager.removeItem(at: directory)
                    try syncDirectory(downloadsDirectory)
                }
            }
            return TransportResult(
                digest: descriptor.digest,
                objectURL: try objectURL(descriptor.digest),
                sourceURL: nil,
                mirrorIndex: nil,
                bytesTransferred: 0,
                resumedFromByteCount: 0,
                reusedExistingObject: true
            )
        }
    }

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

    func publishTransportPayload(
        _ descriptor: LayerDescriptor,
        record: inout TransportRecord
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
        transportDirectory(operationID).appendingPathComponent("operation.lock")
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
