// Author: Timur Isaev

import Foundation
import Testing

@testable import AlloyContentStore

func transportPerformance(resume: Bool, iteration: Int) throws -> PerformanceSample {
    let checkpoint = ContentStore.transportCheckpointByteQuantum
    try #require(checkpoint == 65_536)
    let payload = Data((0..<(checkpoint * 3 + 257)).map { UInt8($0 % 251) })
    let descriptor = performanceLayer(payload).descriptor
    let requests = FixtureRequestLog()
    let fixture = try LoopbackHTTPFixture { request in
        requests.append(request)
        if let range = request.headers["range"],
           range == "bytes=\(checkpoint)-" {
            return FixtureHTTPResponse(statusCode: 206, headers: [
                "Content-Range": "bytes \(checkpoint)-\(payload.count - 1)/\(payload.count)",
                "ETag": "\"performance-fixture\""
            ], body: payload.subdata(in: checkpoint..<payload.count))
        }
        return FixtureHTTPResponse(headers: ["ETag": "\"performance-fixture\""], body: payload)
    }
    defer { fixture.stop() }
    return try withPerformanceStore { store in
        if resume {
            #expect(throws: ContentStoreError.injectedTermination("after-transport-stream-chunk")) {
                _ = try store.fetchObject(descriptor, from: [fixture.baseURL], operationID: "performance") { point in
                    if point == "after-transport-stream-chunk" {
                        throw ContentStoreError.injectedTermination(point)
                    }
                }
            }
            #expect(try store.readTransportRecord("performance").byteCount == checkpoint)
        }
        let id = resume ? "transport-resume" : "transport-fresh"
        let (sample, result) = try measurePerformance(
            id: id, iteration: iteration, units: payload.count, fixtureDigest: descriptor.digest
        ) {
            try store.fetchObject(descriptor, from: [fixture.baseURL], operationID: "performance")
        }
        #expect(result.resumedFromByteCount == (resume ? checkpoint : 0))
        #expect(result.bytesTransferred == payload.count - (resume ? checkpoint : 0))
        #expect(try Data(contentsOf: result.objectURL) == payload)
        #expect(requests.snapshot().count == (resume ? 2 : 1))
        #expect(requests.snapshot().last?.headers["range"] == (resume ? "bytes=\(checkpoint)-" : nil))
        return sample
    }
}
