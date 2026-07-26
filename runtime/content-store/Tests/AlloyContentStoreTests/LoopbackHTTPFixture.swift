// Author: Timur Isaev

import Darwin
import Foundation

struct FixtureHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
}

struct FixtureHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

final class LoopbackHTTPFixture: @unchecked Sendable {
    private let socketDescriptor: Int32
    private let queue = DispatchQueue(label: "alloy.content-store.fixture-http")
    private let handler: @Sendable (FixtureHTTPRequest) -> FixtureHTTPResponse
    private let stateLock = NSLock()
    private var running = true
    let baseURL: URL

    init(
        handler: @escaping @Sendable (FixtureHTTPRequest) -> FixtureHTTPResponse
    ) throws {
        self.handler = handler
        let endpoint = try Self.makeListeningSocket()
        socketDescriptor = endpoint.descriptor
        baseURL = URL(string: "http://127.0.0.1:\(endpoint.port)")!
        queue.async { [self] in
            serve()
        }
    }

    private static func makeListeningSocket() throws -> (
        descriptor: Int32,
        port: UInt16
    ) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.ENOTSOCK)
        }

        var reuse: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse))
        ) == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        return (descriptor, UInt16(bigEndian: boundAddress.sin_port))
    }

    deinit {
        stop()
    }

    func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()
        if wasRunning {
            shutdown(socketDescriptor, SHUT_RDWR)
            close(socketDescriptor)
        }
    }

    private func serve() {
        while isRunning {
            let client = accept(socketDescriptor, nil, nil)
            if client < 0 {
                if !isRunning {
                    return
                }
                continue
            }
            var noSignal: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))
            )
            handle(client)
            close(client)
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func handle(_ client: Int32) {
        guard let request = readRequest(client) else {
            return
        }
        let response = handler(request)
        let reason: String
        switch response.statusCode {
        case 200:
            reason = "OK"
        case 404:
            reason = "Not Found"
        case 503:
            reason = "Service Unavailable"
        default:
            reason = "Fixture"
        }
        var headers = response.headers
        headers["Content-Length"] = headers["Content-Length"]
            ?? String(response.body.count)
        headers["Connection"] = "close"
        var head = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        writeAll(Data(head.utf8), to: client)
        writeAll(response.body, to: client)
    }

    private func readRequest(_ client: Int32) -> FixtureHTTPRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let delimiter = Data("\r\n\r\n".utf8)
        while data.range(of: delimiter) == nil, data.count < 64 * 1024 {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                return nil
            }
            data.append(buffer, count: count)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = string.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        guard first.count >= 2 else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            headers[String(line[..<separator]).lowercased()] = String(
                line[line.index(after: separator)...]
            ).trimmingCharacters(in: .whitespaces)
        }
        return FixtureHTTPRequest(method: first[0], path: first[1], headers: headers)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else {
                return
            }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    return
                }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
        }
    }
}
