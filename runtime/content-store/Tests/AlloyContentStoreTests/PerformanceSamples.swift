// Author: Timur Isaev

import Darwin
import Foundation
import Testing

@testable import AlloyContentStore

struct PerformanceSample: Codable {
    let id: String
    let iteration: Int
    let units: Int
    let fixtureDigest: String
    let seconds: Double
}

func withPerformanceStore<Value>(_ body: (ContentStore) throws -> Value) throws -> Value {
    let parent = try #require(ProcessInfo.processInfo.environment["ALLOY_PERF_FIXTURE_ROOT"])
    let root = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(
        "alloy-content-perf-\(UUID().uuidString.lowercased())", isDirectory: true
    )
    defer {
        let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = entries?.nextObject() as? URL { chmod(url.path, S_IRWXU) }
        chmod(root.path, S_IRWXU)
        try? FileManager.default.removeItem(at: root)
    }
    return try body(ContentStore(root: root))
}

func performanceLayer(_ data: Data) -> LayerInput {
    LayerInput(descriptor: LayerDescriptor(
        name: "synthetic-performance", version: "1", digest: ContentStore.digest(data),
        mediaType: "application/vnd.alloy.test-layer", size: data.count, role: .hostRuntime
    ), contents: data)
}

func measurePerformance<Value>(
    id: String, iteration: Int, units: Int, fixtureDigest: String, body: () throws -> Value
) throws -> (PerformanceSample, Value) {
    if let path = ProcessInfo.processInfo.environment["ALLOY_PERF_HANG_HEARTBEAT"], id == "gc-10" {
        var count = 0
        while true {
            count += 1
            try Data("\(getpid()) \(count)\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    let started = DispatchTime.now().uptimeNanoseconds
    if ProcessInfo.processInfo.environment["ALLOY_PERF_DELAY_CASE"] == id,
       let delay = Double(ProcessInfo.processInfo.environment["ALLOY_PERF_DELAY_SECONDS"] ?? ""),
       delay > 0, delay <= 10 {
        Thread.sleep(forTimeInterval: delay)
    }
    let result = try body()
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    return (PerformanceSample(
        id: id, iteration: iteration, units: units, fixtureDigest: fixtureDigest, seconds: seconds
    ), result)
}

func garbageCollectionPerformance(count: Int, iteration: Int) throws -> PerformanceSample {
    try withPerformanceStore { store in
        let layer = performanceLayer(Data("shared performance payload".utf8))
        for index in 0..<count {
            try store.activate(gameID: "performance", generationID: "generation-\(index)", layers: [layer])
        }
        #expect(try store.catalogInventory().generationCount == count)
        let (sample, result) = try measurePerformance(
            id: "gc-\(count)", iteration: iteration, units: count, fixtureDigest: layer.descriptor.digest
        ) {
            try store.collectGarbage()
        }
        #expect(result.generationsRemoved == count - 2)
        #expect(result.objectsRemoved == 0)
        #expect(try store.catalogInventory().generationCount == 2)
        #expect(try Data(contentsOf: store.objectURL(layer.descriptor.digest)) == layer.contents)
        #expect(try store.inspect(gameID: "performance").active?.generationID == "generation-\(count - 1)")
        #expect(try store.inspect(gameID: "performance").rollback?.generationID == "generation-\(count - 2)")
        #expect(try store.collectGarbage() == .zero)
        return sample
    }
}

func catalogPerformance(count: Int, iteration: Int) throws -> PerformanceSample {
    try withPerformanceStore { store in
        var expectedBytes: UInt64 = 0
        var fixtureBytes = Data()
        for index in 0..<count {
            let data = Data("catalog-performance-object-\(index)".utf8)
            fixtureBytes.append(data)
            fixtureBytes.append(0)
            let path = try store.objectURL(ContentStore.digest(data))
            try store.createDirectory(path.deletingLastPathComponent())
            try data.write(to: path, options: .withoutOverwriting)
            #expect(chmod(path.path, 0o444) == 0)
            expectedBytes += UInt64(data.count)
        }
        let (sample, result) = try measurePerformance(
            id: "catalog-\(count)", iteration: iteration, units: count,
            fixtureDigest: ContentStore.digest(fixtureBytes)
        ) {
            try store.rebuildCatalog()
        }
        #expect(result.action == .rebuilt)
        let inventory = try store.catalogInventory()
        #expect(inventory.objectCount == count)
        #expect(inventory.objectBytes == expectedBytes)
        #expect(inventory.objectReferenceCount == 0)
        #expect(try store.catalogConsistencyReport() == .consistent)
        return sample
    }
}
