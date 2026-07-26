// Author: Timur Isaev

import Darwin
import Foundation

extension ContentStore {
    public static let transportFaultPoints = [
        "after-transport-stream-chunk",
        "before-transport-verification",
        "after-transport-verification",
        "before-transport-publication",
        "after-transport-publication"
    ]

    public static let defaultTransportRedirectLimit = 5

    /// Fetches one caller-authorized descriptor from ordered mirrors and
    /// publishes it through the same hard-link CAS path used by activation.
    @discardableResult
    public func fetchObject(
        _ descriptor: LayerDescriptor,
        from baseURLs: [URL],
        operationID requestedOperationID: String? = nil,
        deadline: TimeInterval = 30,
        redirectLimit: Int = ContentStore.defaultTransportRedirectLimit,
        faultInjector: FaultInjector? = nil
    ) throws -> TransportResult {
        let operationID = try validateTransportInputs(
            descriptor,
            baseURLs: baseURLs,
            requestedOperationID: requestedOperationID,
            deadline: deadline,
            redirectLimit: redirectLimit
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
        let context = TransportFetchContext(
            baseURLs: baseURLs,
            deadline: deadline,
            redirectLimit: redirectLimit,
            faultInjector: faultInjector
        )
        try prepareTransportOperation(initialRecord)
        return try withTransportOperationLock(operationID) {
            try resumeTransportOperation(
                descriptor,
                operationID: operationID,
                context: context
            )
        }
    }

    func validateTransportInputs(
        _ descriptor: LayerDescriptor,
        baseURLs: [URL],
        requestedOperationID: String?,
        deadline: TimeInterval,
        redirectLimit: Int
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
        guard deadline > 0, deadline.isFinite else {
            throw ContentTransportError.deadlineExceeded
        }
        guard redirectLimit >= 0 else {
            throw ContentTransportError.redirectLimitExceeded(limit: redirectLimit)
        }
        let rawDigest = try rawSHA256(descriptor.digest)
        let operationID = requestedOperationID ?? "fetch-\(rawDigest)"
        try validateIdentifier(operationID)
        return operationID
    }

    func resumeTransportOperation(
        _ descriptor: LayerDescriptor,
        operationID: String,
        context: TransportFetchContext
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
              record.baseURLs == context.baseURLs.map(\.absoluteString) else {
            throw ContentTransportError.invalidRecord(operationID)
        }
        if record.state == .downloaded || record.state == .verified {
            return try finishTransportPublication(
                descriptor,
                record: &record,
                faultInjector: context.faultInjector
            )
        }
        guard record.state == .downloading else {
            throw ContentTransportError.invalidRecord(operationID)
        }
        return try downloadTransportObject(
            descriptor,
            record: &record,
            context: context
        )
    }

    func downloadTransportObject(
        _ descriptor: LayerDescriptor,
        record: inout TransportRecord,
        context: TransportFetchContext
    ) throws -> TransportResult {
        let rawDigest = try rawSHA256(descriptor.digest)
        var failures: [String] = []
        for (index, baseURL) in context.baseURLs.enumerated() {
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
                    record: &record,
                    context: context
                )
            } catch let error as ContentTransportError {
                switch error {
                case .digestMismatch,
                     .invalidPartialFile,
                     .invalidRecord,
                     .invalidResumeOffset,
                     .responseTooLarge,
                     .sizeMismatch:
                    if case .responseTooLarge = error {
                        try quarantineTransportOperation(
                            record.operationID,
                            digest: descriptor.digest
                        )
                    }
                    throw error
                default:
                    if context.baseURLs.count == 1 {
                        throw error
                    }
                    record = try readTransportRecord(record.operationID)
                    failures.append(error.description)
                }
            } catch let error as ContentStoreError {
                throw error
            } catch {
                throw error
            }
        }

        throw ContentTransportError.allMirrorsFailed(failures)
    }

    func attemptTransportMirror(
        _ descriptor: LayerDescriptor,
        sourceURL: URL,
        record: inout TransportRecord,
        context: TransportFetchContext
    ) throws -> TransportResult {
        let stagedURL = try transportPayloadURL(
            descriptor, operationID: record.operationID
        )
        try prepareTransportPartialForResume(stagedURL, byteCount: record.byteCount)
        if descriptor.size > 0,
           record.byteCount == descriptor.size,
           isRegularFile(stagedURL) {
            record.state = .downloaded
            try writeTransportRecord(record)
            return try finishTransportPublication(
                descriptor,
                record: &record,
                faultInjector: context.faultInjector
            )
        }

        let transportOperationID = record.operationID
        let streamResult = try streamTransportData(
            TransportStreamRequest(
                sourceURL: sourceURL,
                partialURL: stagedURL,
                expectedSize: descriptor.size,
                resumeFromByteCount: record.byteCount,
                idleTimeout: context.deadline,
                resourceTimeout: context.deadline,
                redirectLimit: context.redirectLimit,
                entityValidator: nil
            ),
            checkpoint: { [self] byteCount in
                try checkpointTransportOperation(
                    transportOperationID,
                    byteCount: byteCount,
                    faultInjector: context.faultInjector
                )
            }
        )
        record = try readTransportRecord(record.operationID)
        guard record.byteCount == streamResult.totalByteCount,
              record.byteCount == descriptor.size else {
            throw ContentTransportError.invalidRecord(record.operationID)
        }
        record.state = .downloaded
        try writeTransportRecord(record)
        return try finishTransportPublication(
            descriptor,
            record: &record,
            faultInjector: context.faultInjector,
            bytesTransferred: streamResult.bytesTransferred,
            resumedFromByteCount: streamResult.resumedFromByteCount
        )
    }

    func finishTransportPublication(
        _ descriptor: LayerDescriptor,
        record: inout TransportRecord,
        faultInjector: FaultInjector?,
        bytesTransferred: Int = 0,
        resumedFromByteCount: Int = 0
    ) throws -> TransportResult {
        let stagedURL = try transportPayloadURL(
            descriptor,
            operationID: record.operationID
        )
        if record.state == .downloaded {
            try faultInjector?("before-transport-verification")
            do {
                try verifyTransportPayload(descriptor, at: stagedURL)
            } catch {
                try quarantineTransportOperation(
                    record.operationID,
                    digest: descriptor.digest
                )
                throw error
            }
            record.state = .verified
            try writeTransportRecord(record)
            try faultInjector?("after-transport-verification")
        }
        guard record.state == .verified else {
            throw ContentTransportError.invalidRecord(record.operationID)
        }

        try faultInjector?("before-transport-publication")
        try publishTransportPayload(
            descriptor,
            record: &record,
            faultInjector: faultInjector
        )
        try removeTransportOperation(record.operationID)
        return TransportResult(
            digest: descriptor.digest,
            objectURL: try objectURL(descriptor.digest),
            sourceURL: record.sourceURL.flatMap(URL.init(string:)),
            mirrorIndex: record.mirrorIndex,
            bytesTransferred: bytesTransferred,
            resumedFromByteCount: resumedFromByteCount,
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

}
