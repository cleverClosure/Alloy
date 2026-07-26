// Author: Timur Isaev

import Foundation

private func parseTransportDecimal<S: StringProtocol>(_ value: S) -> Int? {
    guard !value.isEmpty,
          value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
        return nil
    }
    return Int(value)
}

private struct TransportContentRange {
    let start: Int
    let end: Int
    let total: Int

    init(headerValue: String?) throws {
        guard let value = headerValue else {
            throw ContentTransportError.invalidRangeResponse(
                "missing bytes Content-Range"
            )
        }
        let fields = value.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard fields.count == 2, fields[0].lowercased() == "bytes" else {
            throw ContentTransportError.invalidRangeResponse(value)
        }
        let components = fields[1].split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let total = parseTransportDecimal(components[1]) else {
            throw ContentTransportError.invalidRangeResponse(value)
        }
        let bounds = components[0].split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = parseTransportDecimal(bounds[0]),
              let end = parseTransportDecimal(bounds[1]),
              start >= 0,
              end >= start,
              total > end else {
            throw ContentTransportError.invalidRangeResponse(value)
        }
        self.start = start
        self.end = end
        self.total = total
    }

    var length: Int {
        end - start + 1
    }
}

final class TransportStreamingDelegate:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable {
    private let request: TransportStreamRequest
    private let writer: TransportPartialWriter
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    private var redirectCount = 0
    private var responseReceived = false
    private var statusCode: Int?
    private var finalURL: URL?
    private var resumedFromByteCount = 0
    private var restartedFromZero = false
    private var entityTag: String?
    private var lastModified: String?
    private var failure: Error?

    init(
        request: TransportStreamRequest,
        checkpointQuantum: Int,
        checkpoint: @escaping @Sendable (Int) throws -> Void
    ) throws {
        self.request = request
        writer = try TransportPartialWriter(
            request: request,
            checkpointQuantum: checkpointQuantum,
            checkpoint: checkpoint
        )
        super.init()
    }

    func waitForCompletion(timeout: TimeInterval) -> Bool {
        completion.wait(timeout: .now() + timeout) == .success
    }

    func failWithDeadline() {
        lock.lock()
        if failure == nil {
            failure = ContentTransportError.deadlineExceeded
        }
        lock.unlock()
    }

    func result() throws -> TransportStreamResult {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
        guard let statusCode, let finalURL, responseReceived else {
            throw missingResponseError
        }
        return TransportStreamResult(
            statusCode: statusCode,
            finalURL: finalURL,
            totalByteCount: writer.totalByteCount,
            bytesTransferred: writer.bytesTransferred,
            resumedFromByteCount: resumedFromByteCount,
            restartedFromZero: restartedFromZero,
            entityTag: entityTag,
            lastModified: lastModified
        )
    }

    func closePartialFile() {
        lock.lock()
        writer.closeFile()
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard failure == nil else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        do {
            try prepare(response)
            lock.unlock()
            completionHandler(.allow)
        } catch {
            failure = error
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard failure == nil, responseReceived else {
            lock.unlock()
            return
        }
        do {
            try writer.append(data)
            lock.unlock()
        } catch {
            failure = error
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        guard failure == nil else {
            lock.unlock()
            completionHandler(nil)
            return
        }
        redirectCount += 1
        guard redirectCount <= self.request.redirectLimit else {
            failure = ContentTransportError.redirectLimitExceeded(
                limit: self.request.redirectLimit
            )
            lock.unlock()
            completionHandler(nil)
            return
        }
        guard var redirectedRequest = validatedRedirect(request) else {
            lock.unlock()
            completionHandler(nil)
            return
        }
        addTransportHeaders(to: &redirectedRequest)
        lock.unlock()
        completionHandler(redirectedRequest)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        defer {
            lock.unlock()
            completion.signal()
        }
        guard failure == nil else {
            return
        }
        if let completionFailure = completionFailure(for: error) {
            failure = completionFailure
            return
        }
        do {
            try writer.finish()
        } catch {
            failure = error
        }
    }

    private func prepare(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw ContentTransportError.requestFailed(
                url: request.sourceURL.absoluteString,
                reason: "non-HTTP response"
            )
        }
        let responseURL = response.url ?? request.sourceURL
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw ContentTransportError.httpStatus(
                url: responseURL.absoluteString,
                statusCode: response.statusCode
            )
        }

        let expectedResponseLength = try prepareBody(for: response)
        try validateContentLength(
            response.value(forHTTPHeaderField: "Content-Length"),
            expected: expectedResponseLength
        )
        responseReceived = true
        statusCode = response.statusCode
        finalURL = responseURL
        entityTag = response.value(forHTTPHeaderField: "ETag")
        lastModified = response.value(forHTTPHeaderField: "Last-Modified")
    }

    private func prepareBody(for response: HTTPURLResponse) throws -> Int {
        guard response.statusCode == 206 else {
            if request.resumeFromByteCount > 0 {
                try writer.restartFromZero()
                restartedFromZero = true
            }
            return request.expectedSize
        }

        let contentRange = try TransportContentRange(
            headerValue: response.value(forHTTPHeaderField: "Content-Range")
        )
        try validate(contentRange)
        resumedFromByteCount = request.resumeFromByteCount
        return contentRange.length
    }

    private func validate(_ range: TransportContentRange) throws {
        guard range.start == request.resumeFromByteCount else {
            throw ContentTransportError.invalidRangeResponse(
                "expected start \(request.resumeFromByteCount), got \(range.start)"
            )
        }
        guard range.total == request.expectedSize else {
            throw ContentTransportError.invalidRangeResponse(
                "expected total \(request.expectedSize), got \(range.total)"
            )
        }
        guard range.end == request.expectedSize - 1 else {
            throw ContentTransportError.invalidRangeResponse(
                "expected end \(request.expectedSize - 1), got \(range.end)"
            )
        }
    }

    private func validateContentLength(
        _ value: String?,
        expected: Int
    ) throws {
        guard let value else {
            return
        }
        guard let actual = parseTransportDecimal(value) else {
            throw ContentTransportError.contentLengthMismatch(
                expected: expected,
                actual: -1
            )
        }
        guard actual == expected else {
            throw ContentTransportError.contentLengthMismatch(
                expected: expected,
                actual: actual
            )
        }
    }

    private func completionFailure(for error: Error?) -> Error? {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return ContentTransportError.deadlineExceeded
        }
        if let error {
            if responseReceived, writer.totalByteCount < request.expectedSize {
                return truncatedBodyError
            }
            return ContentTransportError.requestFailed(
                url: (finalURL ?? request.sourceURL).absoluteString,
                reason: error.localizedDescription
            )
        }
        guard responseReceived else {
            return missingResponseError
        }
        return writer.totalByteCount == request.expectedSize
            ? nil
            : truncatedBodyError
    }

    private func validatedRedirect(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            failure = ContentTransportError.invalidBaseURL(
                request.url?.absoluteString ?? "missing redirect URL"
            )
            return nil
        }
        return request
    }

    private func addTransportHeaders(to request: inout URLRequest) {
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        guard self.request.resumeFromByteCount > 0 else {
            return
        }
        request.setValue(
            "bytes=\(self.request.resumeFromByteCount)-",
            forHTTPHeaderField: "Range"
        )
        if let validator = self.request.entityValidator {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
    }

    private var truncatedBodyError: ContentTransportError {
        ContentTransportError.truncatedBody(
            expected: request.expectedSize,
            actual: writer.totalByteCount
        )
    }

    private var missingResponseError: ContentTransportError {
        ContentTransportError.requestFailed(
            url: request.sourceURL.absoluteString,
            reason: "missing HTTP response"
        )
    }
}
