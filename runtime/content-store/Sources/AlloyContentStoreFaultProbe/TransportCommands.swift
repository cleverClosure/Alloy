// Author: Timur Isaev

import AlloyContentStore
import Darwin
import Foundation

private enum TransportProbeError: Error, CustomStringConvertible {
    case usage
    case verification(String)

    var description: String {
        switch self {
        case .usage:
            "invalid transport probe arguments"
        case let .verification(message):
            "transport verification failed: \(message)"
        }
    }
}

private struct TransportProbeRequest {
    let root: URL
    let baseURL: URL
    let operationID: String
}

private func transportFaultInjector() -> FaultInjector {
    let selected = ProcessInfo.processInfo.environment["ALLOY_FAULT_AFTER"]
    return { point in
        if point == selected {
            _exit(97)
        }
    }
}

private func transportPayload() -> Data {
    let byteCount = 64 * 1024 * 3 + 257
    return Data((0..<byteCount).map { UInt8($0 % 251) })
}

private func transportDescriptor() -> LayerDescriptor {
    let data = transportPayload()
    return LayerDescriptor(
        name: "fault-probe-transport",
        version: "1",
        digest: ContentStore.digest(data),
        mediaType: "application/vnd.alloy.test-layer",
        size: data.count,
        role: .hostRuntime
    )
}

private func transportProbeRequest(
    _ arguments: [String]
) throws -> TransportProbeRequest {
    guard arguments.count >= 4,
          let baseURL = URL(string: arguments[2]) else {
        throw TransportProbeError.usage
    }
    return TransportProbeRequest(
        root: URL(fileURLWithPath: arguments[1], isDirectory: true),
        baseURL: baseURL,
        operationID: arguments[3]
    )
}

private func fetchTransport(
    _ request: TransportProbeRequest,
    faultInjector: FaultInjector?
) throws {
    let store = try ContentStore(
        root: request.root
    )
    let result = try store.fetchObject(
        transportDescriptor(),
        from: [request.baseURL],
        operationID: request.operationID,
        deadline: 10,
        faultInjector: faultInjector
    )
    guard try Data(contentsOf: result.objectURL) == transportPayload() else {
        throw TransportProbeError.verification("payload changed")
    }
}

func fetchTransportCommand(_ arguments: [String]) throws {
    guard arguments.count == 4 else {
        throw TransportProbeError.usage
    }
    try fetchTransport(
        try transportProbeRequest(arguments),
        faultInjector: transportFaultInjector()
    )
}

func fetchTransportWithHandshakeCommand(_ arguments: [String]) throws {
    guard arguments.count == 7 else {
        throw TransportProbeError.usage
    }
    try fetchTransport(
        try transportProbeRequest(arguments),
        faultInjector: handshakeInjector(
            point: arguments[4],
            reached: markerURL(arguments[5]),
            continuation: markerURL(arguments[6])
        )
    )
}

func fetchTransportAnnouncedCommand(_ arguments: [String]) throws {
    guard arguments.count == 6 else {
        throw TransportProbeError.usage
    }
    let request = try transportProbeRequest(arguments)
    try requireExclusiveLockIsContended(request.root)
    try writeMarker(markerURL(arguments[4]))
    try fetchTransport(request, faultInjector: nil)
    try writeMarker(markerURL(arguments[5]))
}

func verifyTransportCommand(_ arguments: [String]) throws {
    guard arguments.count == 4 || arguments.count == 5 else {
        throw TransportProbeError.usage
    }
    let request = try transportProbeRequest(arguments)
    let expectedObjectCount: Int
    if arguments.count == 5, let count = Int(arguments[4]) {
        expectedObjectCount = count
    } else if arguments.count == 4 {
        expectedObjectCount = 1
    } else {
        throw TransportProbeError.usage
    }
    let store = try ContentStore(root: request.root)
    let result = try store.fetchObject(
        transportDescriptor(),
        from: [request.baseURL],
        operationID: request.operationID,
        deadline: 10
    )
    guard result.reusedExistingObject,
          result.bytesTransferred == 0,
          try Data(contentsOf: result.objectURL) == transportPayload() else {
        throw TransportProbeError.verification("object was not reused")
    }
    let operationDirectory = request.root
        .appendingPathComponent("downloads", isDirectory: true)
        .appendingPathComponent(request.operationID, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: operationDirectory.path) else {
        throw TransportProbeError.verification("completed staging survived")
    }
    guard try store.inspect(gameID: "transport").objectCount == expectedObjectCount else {
        throw TransportProbeError.verification("object was not published exactly once")
    }
    try verifyCatalogConsistency(store)
}

func verifyTransportStagingCommand(_ arguments: [String]) throws {
    guard arguments.count == 4,
          ["downloading", "published", "absent"].contains(arguments[3]) else {
        throw TransportProbeError.usage
    }
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        .appendingPathComponent("downloads", isDirectory: true)
        .appendingPathComponent(arguments[2], isDirectory: true)
    let exists = FileManager.default.fileExists(atPath: directory.path)
    guard exists == (arguments[3] != "absent") else {
        throw TransportProbeError.verification(
            "staging \(arguments[2]) was \(exists ? "present" : "absent")"
        )
    }
    guard exists else {
        return
    }
    try verifyTransportStaging(directory, expectedState: arguments[3])
}

private func verifyTransportStaging(
    _ directory: URL,
    expectedState: String
) throws {
    let byteCount = try verifiedTransportByteCount(
        directory,
        expectedState: expectedState
    )
    let entries = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    let partials = entries.filter { $0.pathExtension == "part" }
    if expectedState == "published" {
        try verifyPublishedTransportStaging(directory, partials: partials)
        return
    }
    try verifyDownloadingTransportStaging(
        partials,
        entries: entries,
        byteCount: byteCount
    )
}

private func verifiedTransportByteCount(
    _ directory: URL,
    expectedState: String
) throws -> Int {
    let recordURL = directory.appendingPathComponent("transport.json")
    let recordData = try Data(contentsOf: recordURL)
    let descriptor = transportDescriptor()
    guard let record = try JSONSerialization.jsonObject(with: recordData)
            as? [String: Any],
          record["schemaVersion"] as? String == "1.0",
          record["kind"] as? String == "fetch-object",
          record["operationId"] as? String == directory.lastPathComponent,
          record["digest"] as? String == descriptor.digest,
          (record["expectedSize"] as? NSNumber)?.intValue == descriptor.size,
          record["state"] as? String == expectedState,
          let byteCount = (record["byteCount"] as? NSNumber)?.intValue,
          byteCount > 0,
          byteCount <= descriptor.size,
          expectedState != "published" || byteCount == descriptor.size else {
        throw TransportProbeError.verification("live transport record is invalid")
    }
    return byteCount
}

private func verifyPublishedTransportStaging(
    _ directory: URL,
    partials: [URL]
) throws {
    guard partials.isEmpty else {
        throw TransportProbeError.verification(
            "published transport retained \(partials.count) partial(s)"
        )
    }
    let rawDigest = String(
        transportDescriptor().digest.dropFirst("sha256:".count)
    )
    let root = directory
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let objectURL = root
        .appendingPathComponent("objects/sha256", isDirectory: true)
        .appendingPathComponent(String(rawDigest.prefix(2)), isDirectory: true)
        .appendingPathComponent(String(rawDigest.dropFirst(2)))
    guard try Data(contentsOf: objectURL) == transportPayload() else {
        throw TransportProbeError.verification(
            "published transport CAS object is missing or corrupt"
        )
    }
}

private func verifyDownloadingTransportStaging(
    _ partials: [URL],
    entries: [URL],
    byteCount: Int
) throws {
    guard partials.count == 1 else {
        throw TransportProbeError.verification(
            "expected one durable transport partial, found \(partials.count); "
                + "entries=\(entries.map(\.lastPathComponent).sorted())"
        )
    }
    let attributes = try FileManager.default.attributesOfItem(
        atPath: partials[0].path
    )
    guard let size = attributes[.size] as? NSNumber else {
        throw TransportProbeError.verification(
            "durable transport partial size is unavailable; byteCount=\(byteCount)"
        )
    }
    guard size.intValue >= byteCount else {
        throw TransportProbeError.verification(
            "durable transport partial is shorter than its record; "
                + "byteCount=\(byteCount), actualSize=\(size.intValue)"
        )
    }
}
