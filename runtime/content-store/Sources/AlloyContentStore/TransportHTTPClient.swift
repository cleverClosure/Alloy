// Author: Timur Isaev

import Foundation

extension ContentStore {
    static let transportCheckpointByteQuantum = 64 * 1024

    /// Streams an HTTP response into a partial file without writing past the
    /// caller-authorized size.
    ///
    /// The callback runs after each durable 64 KiB boundary and once for a
    /// durable final prefix. A `200` response to a resumed request truncates
    /// the partial and reports a clean restart.
    func streamTransportData(
        _ request: TransportStreamRequest,
        checkpoint: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) throws -> TransportStreamResult {
        guard request.isValid else {
            throw ContentTransportError.invalidRecord(
                request.partialURL.lastPathComponent
            )
        }

        let delegate = try TransportStreamingDelegate(
            request: request,
            checkpointQuantum: Self.transportCheckpointByteQuantum,
            checkpoint: checkpoint
        )
        let queue = OperationQueue()
        queue.name = "alloy.content-store.transport"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: transportSessionConfiguration(request),
            delegate: delegate,
            delegateQueue: queue
        )
        defer {
            session.invalidateAndCancel()
            delegate.closePartialFile()
        }

        let task = session.dataTask(with: request.urlRequest)
        task.resume()
        guard delegate.waitForCompletion(timeout: request.resourceTimeout) else {
            delegate.failWithDeadline()
            task.cancel()
            throw ContentTransportError.deadlineExceeded
        }
        return try delegate.result()
    }

    private func transportSessionConfiguration(
        _ request: TransportStreamRequest
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.idleTimeout
        configuration.timeoutIntervalForResource = request.resourceTimeout
        return configuration
    }
}

final class TransportPartialWriter {
    let expectedSize: Int
    let requestedResumeOffset: Int
    private(set) var totalByteCount: Int
    private(set) var bytesTransferred = 0

    private let partialURL: URL
    private let checkpointQuantum: Int
    private let checkpoint: @Sendable (Int) throws -> Void
    private var descriptor: Int32 = -1
    private var nextCheckpointByteCount: Int
    private var lastCheckpointByteCount: Int

    init(
        request: TransportStreamRequest,
        checkpointQuantum: Int,
        checkpoint: @escaping @Sendable (Int) throws -> Void
    ) throws {
        partialURL = request.partialURL
        expectedSize = request.expectedSize
        requestedResumeOffset = request.resumeFromByteCount
        self.checkpointQuantum = checkpointQuantum
        self.checkpoint = checkpoint
        totalByteCount = request.resumeFromByteCount
        lastCheckpointByteCount = request.resumeFromByteCount
        if request.expectedSize == 0 {
            lastCheckpointByteCount = -1
        }
        nextCheckpointByteCount = Self.nextCheckpoint(
            after: request.resumeFromByteCount,
            quantum: checkpointQuantum
        )

        try validateExistingPath()
        descriptor = try openDescriptor()
        do {
            try validateDescriptorAndSeek()
        } catch {
            closeFile()
            throw error
        }
    }

    deinit {
        closeFile()
    }

    func closeFile() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    func restartFromZero() throws {
        try checkpoint(0)
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0,
              fsync(descriptor) == 0 else {
            throw ContentStoreError.systemCall(
                operation: "restart partial download",
                code: errno
            )
        }
        totalByteCount = 0
        bytesTransferred = 0
        nextCheckpointByteCount = checkpointQuantum
        lastCheckpointByteCount = 0
    }

    func append(_ data: Data) throws {
        var dataOffset = 0
        while dataOffset < data.count {
            guard totalByteCount < expectedSize else {
                throw ContentTransportError.responseTooLarge(limit: expectedSize)
            }

            let writeCount = nextWriteCount(
                dataCount: data.count,
                dataOffset: dataOffset
            )
            try write(data, offset: dataOffset, count: writeCount)
            dataOffset += writeCount
            totalByteCount += writeCount
            bytesTransferred += writeCount
            try checkpointAtQuantumBoundary()
        }
    }

    func finish() throws {
        try checkpointDurably()
    }

    private func validateExistingPath() throws {
        var information = stat()
        let result = lstat(partialURL.path, &information)
        if result == 0 {
            guard information.st_mode & S_IFMT == S_IFREG else {
                throw ContentTransportError.invalidPartialFile(partialURL.path)
            }
        } else if errno != ENOENT {
            throw ContentStoreError.systemCall(
                operation: "inspect partial download",
                code: errno
            )
        }
    }

    private func openDescriptor() throws -> Int32 {
        let result = open(
            partialURL.path,
            O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard result >= 0 else {
            throw ContentStoreError.systemCall(
                operation: "open partial download",
                code: errno
            )
        }
        return result
    }

    private func validateDescriptorAndSeek() throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw ContentStoreError.systemCall(
                operation: "inspect partial download",
                code: errno
            )
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              information.st_size <= off_t(Int.max) else {
            throw ContentTransportError.invalidPartialFile(partialURL.path)
        }

        let actualSize = Int(information.st_size)
        guard actualSize == requestedResumeOffset else {
            throw ContentTransportError.invalidResumeOffset(
                expected: requestedResumeOffset,
                actual: actualSize
            )
        }
        guard lseek(descriptor, off_t(requestedResumeOffset), SEEK_SET)
            == off_t(requestedResumeOffset) else {
            throw ContentStoreError.systemCall(
                operation: "seek partial download",
                code: errno
            )
        }
    }

    private func nextWriteCount(dataCount: Int, dataOffset: Int) -> Int {
        let remainingData = dataCount - dataOffset
        let remainingBudget = expectedSize - totalByteCount
        let remainingUntilCheckpoint = nextCheckpointByteCount - totalByteCount
        return min(remainingData, remainingBudget, remainingUntilCheckpoint)
    }

    private func checkpointAtQuantumBoundary() throws {
        guard totalByteCount == nextCheckpointByteCount,
              totalByteCount < expectedSize else {
            return
        }
        try checkpointDurably()
        nextCheckpointByteCount = Self.nextCheckpoint(
            after: nextCheckpointByteCount,
            quantum: checkpointQuantum
        )
    }

    private func write(_ data: Data, offset: Int, count: Int) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var address = baseAddress.advanced(by: offset)
            var remaining = count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw ContentStoreError.systemCall(
                        operation: "write partial download",
                        code: written < 0 ? errno : EIO
                    )
                }
                remaining -= written
                address = address.advanced(by: written)
            }
        }
    }

    private func checkpointDurably() throws {
        guard lastCheckpointByteCount != totalByteCount else {
            return
        }
        guard fsync(descriptor) == 0 else {
            throw ContentStoreError.systemCall(
                operation: "fsync partial download",
                code: errno
            )
        }
        try checkpoint(totalByteCount)
        lastCheckpointByteCount = totalByteCount
    }

    private static func nextCheckpoint(after byteCount: Int, quantum: Int) -> Int {
        let quotient = byteCount / quantum
        let (nextQuotient, quotientOverflow) = quotient.addingReportingOverflow(1)
        let (next, multiplicationOverflow) = nextQuotient.multipliedReportingOverflow(
            by: quantum
        )
        return quotientOverflow || multiplicationOverflow ? Int.max : next
    }
}
