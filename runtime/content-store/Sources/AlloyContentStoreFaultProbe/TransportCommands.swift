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

func fetchTransportCommand(_ arguments: [String]) throws {
    guard arguments.count == 4,
          let baseURL = URL(string: arguments[2]) else {
        throw TransportProbeError.usage
    }
    let store = try ContentStore(
        root: URL(fileURLWithPath: arguments[1], isDirectory: true)
    )
    let result = try store.fetchObject(
        transportDescriptor(),
        from: [baseURL],
        operationID: arguments[3],
        deadline: 10,
        faultInjector: transportFaultInjector()
    )
    guard try Data(contentsOf: result.objectURL) == transportPayload() else {
        throw TransportProbeError.verification("payload changed")
    }
}

func verifyTransportCommand(_ arguments: [String]) throws {
    guard arguments.count == 4,
          let baseURL = URL(string: arguments[2]) else {
        throw TransportProbeError.usage
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let store = try ContentStore(root: root)
    let result = try store.fetchObject(
        transportDescriptor(),
        from: [baseURL],
        operationID: arguments[3],
        deadline: 10
    )
    guard result.reusedExistingObject,
          result.bytesTransferred == 0,
          try Data(contentsOf: result.objectURL) == transportPayload() else {
        throw TransportProbeError.verification("object was not reused")
    }
    let operationDirectory = root
        .appendingPathComponent("downloads", isDirectory: true)
        .appendingPathComponent(arguments[3], isDirectory: true)
    guard !FileManager.default.fileExists(atPath: operationDirectory.path) else {
        throw TransportProbeError.verification("completed staging survived")
    }
    guard try store.inspect(gameID: "transport").objectCount == 1 else {
        throw TransportProbeError.verification("object was not published exactly once")
    }
    try verifyCatalogConsistency(store)
}
