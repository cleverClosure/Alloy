// Author: Timur Isaev

import Foundation

extension ContentStore {
    func requestTransportData(
        from url: URL,
        deadline: TimeInterval
    ) throws -> TransportHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = deadline
        configuration.timeoutIntervalForResource = deadline
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let box = TransportResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            box.store(data: data, response: response, error: error)
            semaphore.signal()
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + deadline + 1) == .success else {
            task.cancel()
            throw ContentTransportError.deadlineExceeded
        }
        let result = box.load()
        if let error = result.error as? URLError, error.code == .timedOut {
            throw ContentTransportError.deadlineExceeded
        }
        if let error = result.error {
            throw ContentTransportError.requestFailed(
                url: url.absoluteString,
                reason: error.localizedDescription
            )
        }
        guard let response = result.response as? HTTPURLResponse,
              let data = result.data else {
            throw ContentTransportError.requestFailed(
                url: url.absoluteString,
                reason: "missing HTTP response"
            )
        }
        return TransportHTTPResponse(statusCode: response.statusCode, data: data)
    }
}

struct TransportHTTPResponse {
    let statusCode: Int
    let data: Data
}

private struct TransportResponseSnapshot {
    let data: Data?
    let response: URLResponse?
    let error: Error?
}

private final class TransportResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var response: URLResponse?
    private var error: Error?

    func store(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        self.data = data
        self.response = response
        self.error = error
        lock.unlock()
    }

    func load() -> TransportResponseSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return TransportResponseSnapshot(
            data: data,
            response: response,
            error: error
        )
    }
}
