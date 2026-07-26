// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private let gate3RedirectLimit = 5

private func withGate3TransportStore(
    _ body: (URL, ContentStore) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-content-transport-gate3-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            chmod(url.path, S_IRWXU)
        }
        chmod(root.path, S_IRWXU)
        try? FileManager.default.removeItem(at: root)
    }
    try body(root, ContentStore(root: root))
}

private func gate3Descriptor(
    _ data: Data,
    name: String = "hostile-response"
) -> LayerDescriptor {
    LayerDescriptor(
        name: name,
        version: "3",
        digest: ContentStore.digest(data),
        mediaType: "application/vnd.alloy.test-layer",
        size: data.count,
        role: .hostRuntime
    )
}

private func gate3ExpectRefusalThenControl(
    store: ContentStore,
    descriptor: LayerDescriptor,
    fixture: LoopbackHTTPFixture,
    operationID: String,
    expectedError: ContentTransportError,
    deadline: TimeInterval = 2
) throws {
    #expect(throws: expectedError) {
        _ = try store.fetchObject(
            descriptor,
            from: [fixture.baseURL],
            operationID: operationID,
            deadline: deadline
        )
    }
    fixture.stop()

    #expect(!store.pathEntryExists(try store.objectURL(descriptor.digest)))

    let controlPayload = Data("healthy-control-\(operationID)".utf8)
    let controlDescriptor = gate3Descriptor(
        controlPayload,
        name: "healthy-control"
    )
    let control = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(body: controlPayload)
    }
    defer { control.stop() }

    let result = try store.fetchObject(
        controlDescriptor,
        from: [control.baseURL],
        operationID: "\(operationID)-control"
    )
    #expect(try Data(contentsOf: result.objectURL) == controlPayload)
}

extension SerializedTransportTests {
    @Test("wrong response bytes return digestMismatch and publish no object")
    func transportRejectsWrongBytes() throws {
    let expectedPayload = Data("right-byte".utf8)
    let wrongPayload = Data("wrong-byte".utf8)
    let descriptor = gate3Descriptor(expectedPayload)
    let fixture = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(body: wrongPayload)
    }

    try withGate3TransportStore { _, store in
        try gate3ExpectRefusalThenControl(
            store: store,
            descriptor: descriptor,
            fixture: fixture,
            operationID: "gate3-wrong-bytes",
            expectedError: .digestMismatch(
                expected: descriptor.digest,
                actual: ContentStore.digest(wrongPayload)
            )
        )
    }
    }

    @Test("a truncated response returns truncatedBody and publish no object")
    func transportRejectsTruncatedBody() throws {
    let payload = Data("complete-hostile-payload".utf8)
    let truncated = Data(payload.prefix(7))
    let descriptor = gate3Descriptor(payload)
    let fixture = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(
            body: truncated,
            automaticallySetsContentLength: false
        )
    }

    try withGate3TransportStore { _, store in
        try gate3ExpectRefusalThenControl(
            store: store,
            descriptor: descriptor,
            fixture: fixture,
            operationID: "gate3-truncated",
            expectedError: .truncatedBody(
                expected: payload.count,
                actual: truncated.count
            )
        )
    }
    }

    @Test("an unbounded response aborts at the authorized size")
    func transportRejectsOversizedBodyWithoutContentLength() throws {
    let expectedPayload = Data("declared".utf8)
    let oversizedPayload = expectedPayload + Data("-too-large".utf8)
    let descriptor = gate3Descriptor(expectedPayload)
    let fixture = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(
            body: oversizedPayload,
            automaticallySetsContentLength: false
        )
    }

    try withGate3TransportStore { _, store in
        try gate3ExpectRefusalThenControl(
            store: store,
            descriptor: descriptor,
            fixture: fixture,
            operationID: "gate3-oversized",
            expectedError: .responseTooLarge(limit: expectedPayload.count)
        )
        let quarantine = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectory,
            includingPropertiesForKeys: nil
        )
        let quarantineDirectory = try #require(quarantine.first)
        let entries = try FileManager.default.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: nil
        )
        let partial = try #require(
            entries.first(where: { $0.pathExtension == "part" })
        )
        #expect(try Data(contentsOf: partial).count == expectedPayload.count)
    }
    }

    @Test("a stalled response returns deadlineExceeded")
    func transportRejectsStalledResponse() throws {
    let payload = Data("stalled-response".utf8)
    let descriptor = gate3Descriptor(payload)
    let fixture = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(
            headers: ["Content-Length": String(payload.count)],
            body: Data(),
            automaticallySetsContentLength: false,
            stallsAfterHeaders: true
        )
    }

    try withGate3TransportStore { _, store in
        try gate3ExpectRefusalThenControl(
            store: store,
            descriptor: descriptor,
            fixture: fixture,
            operationID: "gate3-stalled",
            expectedError: .deadlineExceeded,
            deadline: 0.25
        )
    }
    }

    @Test("Content-Length disagreement is rejected before publication")
    func transportRejectsContentLengthDisagreement() throws {
    let payload = Data("length-disagreement".utf8)
    let descriptor = gate3Descriptor(payload)
    let advertisedLength = payload.count - 1
    let fixture = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(
            headers: ["Content-Length": String(advertisedLength)],
            body: payload,
            automaticallySetsContentLength: false
        )
    }

    try withGate3TransportStore { _, store in
        try gate3ExpectRefusalThenControl(
            store: store,
            descriptor: descriptor,
            fixture: fixture,
            operationID: "gate3-content-length",
            expectedError: .contentLengthMismatch(
                expected: payload.count,
                actual: advertisedLength
            )
        )
    }
    }

    @Test("redirect targets containing user information are refused")
    func transportRejectsRedirectUserInformation() throws {
    let payload = Data("redirect-user-information".utf8)
    let descriptor = gate3Descriptor(payload)
    let fixture = try LoopbackHTTPFixture { request in
        let host = request.headers["host"] ?? "127.0.0.1"
        return FixtureHTTPResponse(
            statusCode: 302,
            headers: ["Location": "http://user:secret@\(host)/target"],
            body: Data()
        )
    }

    try withGate3TransportStore { _, store in
        let host = fixture.baseURL.host ?? "127.0.0.1"
        let port = try #require(fixture.baseURL.port)
        try gate3ExpectRefusalThenControl(
            store: store,
            descriptor: descriptor,
            fixture: fixture,
            operationID: "gate3-redirect-userinfo",
            expectedError: .invalidBaseURL(
                "http://user:secret@\(host):\(port)/target"
            )
        )
    }
    }

    @Test("redirect loops stop at the fixed redirect limit")
    func transportRejectsRedirectLoop() throws {
    let payload = Data("redirect-target".utf8)
    let descriptor = gate3Descriptor(payload)
    let requests = FixtureRequestLog()
    let fixture = try LoopbackHTTPFixture { request in
        requests.append(request)
        return FixtureHTTPResponse(
            statusCode: 302,
            headers: ["Location": request.path],
            body: Data()
        )
    }

    try withGate3TransportStore { _, store in
        try gate3ExpectRefusalThenControl(
            store: store,
            descriptor: descriptor,
            fixture: fixture,
            operationID: "gate3-redirect-loop",
            expectedError: .redirectLimitExceeded(limit: gate3RedirectLimit)
        )
        #expect(requests.snapshot().count == gate3RedirectLimit + 1)
    }
    }
}
