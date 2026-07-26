// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

private func withTransportStore(
    _ body: (URL, ContentStore) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-content-transport-tests-\(UUID().uuidString.lowercased())",
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

private func transportDescriptor(_ data: Data) -> LayerDescriptor {
    LayerDescriptor(
        name: "transport-test",
        version: "1",
        digest: ContentStore.digest(data),
        mediaType: "application/vnd.alloy.test-layer",
        size: data.count,
        role: .hostRuntime
    )
}

@Test("transport follows ordered mirror fallback and publishes through CAS")
func transportMirrorFallbackPublishesCAS() throws {
    let payload = Data("fixture-transport-payload".utf8)
    let descriptor = transportDescriptor(payload)
    let first = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(statusCode: 503, body: Data())
    }
    let second = try LoopbackHTTPFixture { request in
        #expect(request.method == "GET")
        #expect(request.path == "/sha256/\(descriptor.digest.dropFirst("sha256:".count))")
        return FixtureHTTPResponse(body: payload)
    }
    defer {
        first.stop()
        second.stop()
    }

    try withTransportStore { _, store in
        let result = try store.fetchObject(
            descriptor,
            from: [first.baseURL, second.baseURL],
            operationID: "gate1-fallback"
        )

        #expect(result.mirrorIndex == 1)
        #expect(result.sourceURL?.host == "127.0.0.1")
        #expect(result.bytesTransferred == payload.count)
        #expect(try Data(contentsOf: result.objectURL) == payload)
        #expect(try store.inspect(gameID: "unused").objectCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(
            at: store.downloadsDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)

        let reused = try store.fetchObject(
            descriptor,
            from: [first.baseURL],
            operationID: "gate1-reuse"
        )
        #expect(reused.reusedExistingObject)
        #expect(reused.bytesTransferred == 0)
    }
}

@Test("transport quarantines bad verification and creates no object")
func transportBadDigestIsQuarantined() throws {
    let expected = Data("expected".utf8)
    let wrong = Data("bad-byte".utf8)
    let descriptor = transportDescriptor(expected)
    let fixture = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(body: wrong)
    }
    defer { fixture.stop() }

    try withTransportStore { _, store in
        #expect(throws: ContentTransportError.digestMismatch(
            expected: descriptor.digest,
            actual: ContentStore.digest(wrong)
        )) {
            _ = try store.fetchObject(
                descriptor,
                from: [fixture.baseURL],
                operationID: "gate1-bad-digest"
            )
        }

        #expect(!store.pathEntryExists(try store.objectURL(descriptor.digest)))
        let quarantine = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(quarantine.count == 1)
        #expect(quarantine[0].pathExtension == "transport")
        #expect(store.isRegularFile(
            quarantine[0].appendingPathComponent("transport.json")
        ))
    }
}

@Test("live transport sidecar protects staging from garbage collection")
func transportSidecarProtectsStagingFromGarbageCollection() throws {
    let payload = Data("protected-download".utf8)
    let descriptor = transportDescriptor(payload)
    let baseURL = URL(string: "http://127.0.0.1:1")!

    try withTransportStore { _, store in
        let record = TransportRecord(
            operationID: "gate1-live-transport",
            descriptor: descriptor,
            baseURLs: [baseURL]
        )
        try store.prepareTransportOperation(record)
        let abandoned = store.downloadsDirectory.appendingPathComponent(
            "abandoned",
            isDirectory: true
        )
        try store.createDirectory(abandoned)
        try Data("garbage".utf8).write(
            to: abandoned.appendingPathComponent("payload.part")
        )

        let result = try store.collectGarbage()

        #expect(result.downloadsRemoved == 1)
        #expect(store.isDirectory(store.transportDirectory(record.operationID)))
        #expect(!store.pathEntryExists(abandoned))
    }
}

@Test("publication sidecar survives its kill boundary and retry cleans it")
func transportPublicationKillBoundaryRecovers() throws {
    let payload = Data("publish-once".utf8)
    let descriptor = transportDescriptor(payload)
    let fixture = try LoopbackHTTPFixture { _ in
        FixtureHTTPResponse(body: payload)
    }
    defer { fixture.stop() }

    try withTransportStore { _, store in
        #expect(throws: ContentStoreError.injectedTermination(
            "after-transport-publication"
        )) {
            _ = try store.fetchObject(
                descriptor,
                from: [fixture.baseURL],
                operationID: "gate1-published",
                faultInjector: { point in
                    if point == "after-transport-publication" {
                        throw ContentStoreError.injectedTermination(point)
                    }
                }
            )
        }
        #expect(store.isRegularFile(try store.objectURL(descriptor.digest)))
        #expect(try store.readTransportRecord("gate1-published").state == .published)

        let recovered = try store.fetchObject(
            descriptor,
            from: [fixture.baseURL],
            operationID: "gate1-published"
        )
        #expect(recovered.reusedExistingObject)
        #expect(!store.pathEntryExists(store.transportDirectory("gate1-published")))
    }
}
