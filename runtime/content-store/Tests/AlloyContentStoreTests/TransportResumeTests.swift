// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private let gate2Checkpoint = ContentStore.transportCheckpointByteQuantum

private func withGate2TransportStore(
    _ body: (URL, ContentStore) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-content-transport-gate2-\(UUID().uuidString.lowercased())",
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

private func gate2Payload() -> Data {
    Data((0..<(gate2Checkpoint * 3 + 257)).map { UInt8($0 % 251) })
}

private func gate2Descriptor(_ data: Data) -> LayerDescriptor {
    LayerDescriptor(
        name: "transport-resume-test",
        version: "2",
        digest: ContentStore.digest(data),
        mediaType: "application/vnd.alloy.test-layer",
        size: data.count,
        role: .hostRuntime
    )
}

private func gate2RangeOffset(_ request: FixtureHTTPRequest) -> Int? {
    guard let value = request.headers["range"],
          value.hasPrefix("bytes="),
          value.hasSuffix("-") else {
        return nil
    }
    return Int(value.dropFirst("bytes=".count).dropLast())
}

private func gate2RangeResponse(
    payload: Data,
    offset: Int
) -> FixtureHTTPResponse {
    FixtureHTTPResponse(
        statusCode: 206,
        headers: [
            "Content-Range": "Bytes \(offset)-\(payload.count - 1)/\(payload.count)",
            "ETag": "\"alloy-gate2\""
        ],
        body: payload.subdata(in: offset..<payload.count)
    )
}

private func gate2LinkCount(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.referenceCount] as? NSNumber)?.intValue ?? 0
}

private func gate2InterruptAtFirstCheckpoint(
    store: ContentStore,
    descriptor: LayerDescriptor,
    baseURL: URL,
    operationID: String
) throws {
    #expect(throws: ContentStoreError.injectedTermination(
        "after-transport-stream-chunk"
    )) {
        _ = try store.fetchObject(
            descriptor,
            from: [baseURL],
            operationID: operationID,
            faultInjector: { point in
                if point == "after-transport-stream-chunk" {
                    throw ContentStoreError.injectedTermination(point)
                }
            }
        )
    }
}

private func gate2ResumeFromFixture(
    store: ContentStore,
    fixture: LoopbackHTTPFixture,
    requests: FixtureRequestLog,
    payload: Data,
    descriptor: LayerDescriptor
) throws -> Data {
    let operationID = "gate2-range-resume"
    try gate2InterruptAtFirstCheckpoint(
        store: store,
        descriptor: descriptor,
        baseURL: fixture.baseURL,
        operationID: operationID
    )
    let record = try store.readTransportRecord(operationID)
    let partialURL = try store.transportPayloadURL(
        descriptor,
        operationID: operationID
    )
    #expect(record.state == .downloading)
    #expect(record.byteCount == gate2Checkpoint)
    #expect(try Data(contentsOf: partialURL) == payload.prefix(gate2Checkpoint))
    #expect(!store.pathEntryExists(try store.objectURL(descriptor.digest)))

    let result = try store.fetchObject(
        descriptor,
        from: [fixture.baseURL],
        operationID: operationID
    )
    let resultPayload = try Data(contentsOf: result.objectURL)
    #expect(result.resumedFromByteCount == gate2Checkpoint)
    #expect(result.bytesTransferred == payload.count - gate2Checkpoint)
    #expect(resultPayload == payload)
    #expect(!store.pathEntryExists(store.transportDirectory(operationID)))

    let snapshot = requests.snapshot()
    try #require(snapshot.count == 2)
    #expect(snapshot[0].headers["range"] == nil)
    #expect(snapshot[1].headers["range"] == "bytes=\(gate2Checkpoint)-")
    return resultPayload
}

private func gate2UninterruptedPayload(
    _ descriptor: LayerDescriptor,
    payload: Data
) throws -> Data {
    let fixture = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(body: payload)
    }
    defer { fixture.stop() }
    var resultPayload: Data?
    try withGate2TransportStore { _, store in
        let result = try store.fetchObject(
            descriptor,
            from: [fixture.baseURL],
            operationID: "gate2-uninterrupted-control"
        )
        resultPayload = try Data(contentsOf: result.objectURL)
    }
    return try #require(resultPayload)
}

private let gate2LifecycleFaultPoints = [
    "before-transport-verification",
    "after-transport-verification",
    "before-transport-publication",
    "after-transport-publication"
]

extension SerializedTransportTests {
    @Test("transport resumes an exact durable checkpoint with a Range request")
    func transportResumesExactDurableCheckpoint() throws {
    let payload = gate2Payload()
    let descriptor = gate2Descriptor(payload)
    let requests = FixtureRequestLog()
    let fixture = try LoopbackHTTPFixture { request in
        requests.append(request)
        guard let offset = gate2RangeOffset(request) else {
            return FixtureHTTPResponse(
                headers: ["ETag": "\"alloy-gate2\""],
                body: payload
            )
        }
        return gate2RangeResponse(payload: payload, offset: offset)
    }
    defer { fixture.stop() }

    try withGate2TransportStore { _, store in
        let resumedPayload = try gate2ResumeFromFixture(
            store: store,
            fixture: fixture,
            requests: requests,
            payload: payload,
            descriptor: descriptor
        )
        let controlPayload = try gate2UninterruptedPayload(
            descriptor,
            payload: payload
        )
        #expect(controlPayload == resumedPayload)
        #expect(ContentStore.digest(controlPayload) == descriptor.digest)
    }
    }

    @Test("a server that ignores Range causes a clean restart from byte zero")
    func transportIgnoredRangeRestartsCleanly() throws {
    let payload = gate2Payload()
    let descriptor = gate2Descriptor(payload)
    let requests = FixtureRequestLog()
    let fixture = try LoopbackHTTPFixture { request in
        requests.append(request)
        return FixtureHTTPResponse(
            headers: ["ETag": "\"alloy-gate2-restart\""],
            body: payload
        )
    }
    defer { fixture.stop() }

    try withGate2TransportStore { _, store in
        let operationID = "gate2-range-ignored"
        try gate2InterruptAtFirstCheckpoint(
            store: store,
            descriptor: descriptor,
            baseURL: fixture.baseURL,
            operationID: operationID
        )

        let result = try store.fetchObject(
            descriptor,
            from: [fixture.baseURL],
            operationID: operationID
        )

        #expect(result.resumedFromByteCount == 0)
        #expect(result.bytesTransferred == payload.count)
        #expect(try Data(contentsOf: result.objectURL) == payload)
        #expect(!store.pathEntryExists(store.transportDirectory(operationID)))

        let snapshot = requests.snapshot()
        try #require(snapshot.count == 2)
        #expect(snapshot[0].headers["range"] == nil)
        #expect(snapshot[1].headers["range"] == "bytes=\(gate2Checkpoint)-")
    }
    }

    @Test("mirror fallback keeps the latest durable resume checkpoint")
    func transportMirrorFallbackKeepsCheckpoint() throws {
    let payload = gate2Payload()
    let descriptor = gate2Descriptor(payload)
    let firstBody = Data(payload.prefix(gate2Checkpoint + 37))
    let secondRequests = FixtureRequestLog()
    let first = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(
            body: firstBody,
            automaticallySetsContentLength: false
        )
    }
    let second = try LoopbackHTTPFixture { request in
        secondRequests.append(request)
        guard let offset = gate2RangeOffset(request) else {
            return FixtureHTTPResponse(body: payload)
        }
        return gate2RangeResponse(payload: payload, offset: offset)
    }
    defer {
        first.stop()
        second.stop()
    }

    try withGate2TransportStore { _, store in
        let result = try store.fetchObject(
            descriptor,
            from: [first.baseURL, second.baseURL],
            operationID: "gate2-mirror-checkpoint"
        )

        #expect(result.mirrorIndex == 1)
        #expect(result.resumedFromByteCount == gate2Checkpoint)
        #expect(result.bytesTransferred == payload.count - gate2Checkpoint)
        #expect(try Data(contentsOf: result.objectURL) == payload)
        let request = try #require(secondRequests.snapshot().first)
        #expect(request.headers["range"] == "bytes=\(gate2Checkpoint)-")
    }
    }

    @Test("an authorized empty object completes through transport")
    func transportPublishesEmptyObject() throws {
    let payload = Data()
    let descriptor = gate2Descriptor(payload)
    let fixture = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(body: payload)
    }
    defer { fixture.stop() }

    try withGate2TransportStore { _, store in
        let result = try store.fetchObject(
            descriptor,
            from: [fixture.baseURL],
            operationID: "gate2-empty"
        )
        let reused = try store.fetchObject(
            descriptor,
            from: [fixture.baseURL],
            operationID: "gate2-empty-reuse"
        )

        #expect(try Data(contentsOf: result.objectURL).isEmpty)
        #expect(!result.reusedExistingObject)
        #expect(reused.reusedExistingObject)
        #expect(try store.inspect(gameID: "unused").objectCount == 1)
    }
    }

    @Test(
        "transport recovery completes exactly once at verification and publication kills",
        arguments: gate2LifecycleFaultPoints
    )
    func transportLifecycleKillRecoversExactlyOnce(faultPoint: String) throws {
    let payload = Data("gate2-lifecycle-\(faultPoint)".utf8)
    let descriptor = gate2Descriptor(payload)
    let requests = FixtureRequestLog()
    let fixture = try LoopbackHTTPFixture { request in
        requests.append(request)
        return FixtureHTTPResponse(body: payload)
    }
    defer { fixture.stop() }

    try withGate2TransportStore { _, store in
        let operationID = "gate2-\(faultPoint)"
        #expect(throws: ContentStoreError.injectedTermination(faultPoint)) {
            _ = try store.fetchObject(
                descriptor,
                from: [fixture.baseURL],
                operationID: operationID,
                faultInjector: { point in
                    if point == faultPoint {
                        throw ContentStoreError.injectedTermination(point)
                    }
                }
            )
        }

        let objectURL = try store.objectURL(descriptor.digest)
        #expect(
            store.isRegularFile(objectURL)
                == (faultPoint == "after-transport-publication")
        )

        let recovered = try store.fetchObject(
            descriptor,
            from: [fixture.baseURL],
            operationID: operationID
        )
        let reused = try store.fetchObject(
            descriptor,
            from: [fixture.baseURL],
            operationID: "\(operationID)-reuse"
        )

        #expect(try Data(contentsOf: recovered.objectURL) == payload)
        #expect(reused.reusedExistingObject)
        #expect(try gate2LinkCount(objectURL) == 1)
        #expect(requests.snapshot().count == 1)
        #expect(!store.pathEntryExists(store.transportDirectory(operationID)))
    }
    }
}
