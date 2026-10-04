// Author: Timur Isaev
import Foundation

/// A connection per request makes reconnect explicit and avoids retaining a dead proxy.
/// Blocking calls belong off the UI thread; future clients can wrap them in a worker task.
public struct RuntimeClient: Sendable {
    public let configuration: ServiceConfiguration
    public init(configuration: ServiceConfiguration) { self.configuration = configuration }

    public func call(_ method: String, payload: Data = Data("{}".utf8),
                     timeout: TimeInterval = 10) throws -> RuntimeResponse {
        let request = RuntimeRequest(method: method, payload: payload, credential: configuration.credential)
        let raw = try exchange(RuntimeEncoding.encode(request), timeout: timeout)
        let response = try JSONDecoder().decode(RuntimeResponse.self, from: raw)
        guard response.apiVersion == 1, response.requestID == request.requestID else {
            throw RuntimeFailure.transport
        }
        return response
    }

    public func exchange(_ bytes: Data, timeout: TimeInterval = 10) throws -> Data {
        guard bytes.count <= RuntimeLimits.messageBytes, timeout > 0, timeout <= 30 else {
            throw RuntimeFailure.status(.oversized)
        }
        let connection = NSXPCConnection(machServiceName: configuration.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: RuntimeWire.self)
        let result = ReplyBox()
        connection.interruptionHandler = { result.finish(.failure(RuntimeFailure.transport)) }
        connection.invalidationHandler = { result.finish(.failure(RuntimeFailure.transport)) }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            result.finish(.failure(RuntimeFailure.transport))
        }) as? RuntimeWire else { throw RuntimeFailure.transport }
        proxy.exchange(bytes) { reply in
            if reply.count > RuntimeLimits.messageBytes {
                result.finish(.failure(RuntimeFailure.status(.oversized)))
            } else {
                result.finish(.success(reply))
            }
        }
        guard result.semaphore.wait(timeout: .now() + timeout) == .success else { throw RuntimeFailure.transport }
        return try result.value().get()
    }
}

private final class ReplyBox: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Data, any Error>?

    func finish(_ value: Result<Data, any Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func value() -> Result<Data, any Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(RuntimeFailure.transport)
    }
}
