// Author: Timur Isaev

import AlloyContentStore
import Foundation

private func transportFault(
    request: StressOperationRequest,
    random: inout SplitMix64,
    model: StressModel
) -> String {
    guard !model.transportObjectPresent else {
        return "none"
    }
    if request.forceFault {
        return "after-transport-stream-chunk"
    }
    return selectedFault(
        from: ContentStore.transportFaultPoints,
        random: &random,
        force: false
    )
}

private func verifyTransportResult(
    _ result: TransportResult
) throws {
    guard result.digest == stressTransportDescriptor.digest,
          try Data(contentsOf: result.objectURL) == stressTransportPayload else {
        throw HarnessError.invariant("transport payload or digest changed")
    }
}

private func requireTransportStagingRemoved(
    root: URL,
    operationID: String
) throws {
    let directory = root
        .appendingPathComponent("downloads", isDirectory: true)
        .appendingPathComponent(operationID, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw HarnessError.invariant(
            "completed transport staging survived for \(operationID)"
        )
    }
}

private func recoverTransport(
    context: StressRunContext,
    operationID: String
) throws -> TransportResult {
    let recovered = try ContentStore(root: context.root).fetchObject(
        stressTransportDescriptor,
        from: [context.baseURL],
        operationID: operationID,
        deadline: 10
    )
    try verifyTransportResult(recovered)
    try requireTransportStagingRemoved(
        root: context.root,
        operationID: operationID
    )
    return recovered
}

private func verifyCheckpointResume(
    _ result: TransportResult,
    fault: String
) throws {
    guard fault == "after-transport-stream-chunk" else {
        return
    }
    guard result.resumedFromByteCount == stressTransportCheckpointByteCount,
          result.bytesTransferred
            == stressTransportPayload.count - stressTransportCheckpointByteCount else {
        throw HarnessError.invariant(
            "transport did not resume its exact durable checkpoint"
        )
    }
}

private func verifyTransportReuse(
    context: StressRunContext,
    operationID: String,
    objectURL: URL
) throws {
    let reused = try ContentStore(root: context.root).fetchObject(
        stressTransportDescriptor,
        from: [context.baseURL],
        operationID: operationID,
        deadline: 10
    )
    try verifyTransportResult(reused)
    guard reused.reusedExistingObject,
          reused.bytesTransferred == 0,
          reused.resumedFromByteCount == 0,
          reused.objectURL == objectURL else {
        throw HarnessError.invariant(
            "completed transport object was not reused exactly"
        )
    }
    try requireTransportStagingRemoved(
        root: context.root,
        operationID: operationID
    )
}

func performDownload(
    context: StressRunContext,
    request: StressOperationRequest,
    random: inout SplitMix64,
    model: inout StressModel
) throws -> StressStepResult {
    let operationID = "seed-\(context.seed)-download-\(request.step)"
    let fault = transportFault(
        request: request,
        random: &random,
        model: model
    )
    let status = try runChild([
        "child-download",
        context.root.path,
        context.baseURL.absoluteString,
        operationID,
        fault
    ])
    try requireChildStatus(status, fault: fault)

    let recovered = try recoverTransport(
        context: context,
        operationID: operationID
    )
    try verifyCheckpointResume(recovered, fault: fault)
    try verifyTransportReuse(
        context: context,
        operationID: operationID,
        objectURL: recovered.objectURL
    )

    model.transportObjectPresent = true
    return StressStepResult(
        detail: "\(operationID),resume=\(recovered.resumedFromByteCount)",
        fault: fault,
        completedSweep: false
    )
}

func childDownload(_ arguments: [String]) throws {
    guard arguments.count == 6 else {
        throw HarnessError.usage
    }
    let baseURL = try requireStressFixtureURL(arguments[3])
    let store = try ContentStore(
        root: URL(fileURLWithPath: arguments[2], isDirectory: true)
    )
    _ = try store.fetchObject(
        stressTransportDescriptor,
        from: [baseURL],
        operationID: arguments[4],
        deadline: 10,
        faultInjector: faultInjector(arguments[5])
    )
}
