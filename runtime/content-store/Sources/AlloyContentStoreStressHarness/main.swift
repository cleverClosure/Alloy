// Author: Timur Isaev

import AlloyContentStore
import Darwin
import Foundation

private func faultInjector(_ selected: String) -> FaultInjector {
    { point in
        if point == selected {
            _exit(97)
        }
    }
}

private func runChild(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func requireChildStatus(_ status: Int32, fault: String) throws {
    let expected: Int32 = fault == "none" ? 0 : 97
    guard status == expected else {
        throw HarnessError.invariant(
            "child exit \(status), expected \(expected) for fault \(fault)"
        )
    }
}

private func shuffledOperations(_ random: inout SplitMix64) -> [StressOperation] {
    var operations = StressOperation.allCases
    guard operations.count > 1 else {
        return operations
    }
    for index in stride(from: operations.count - 1, through: 1, by: -1) {
        operations.swapAt(index, random.index(upperBound: index + 1))
    }
    return operations
}

private func selectedFault(
    from points: [String],
    random: inout SplitMix64,
    force: Bool
) -> String {
    if !force, random.next() % 3 == 0 {
        return "none"
    }
    return points[random.index(upperBound: points.count)]
}

private func applyActivation(
    generationID: String,
    payload: String,
    healthOutcome: HealthOutcome,
    to model: inout StressModel
) {
    let previous = model.active
    model.materialized[generationID] = payload
    model.rollback = previous
    if healthOutcome == .pass {
        model.active = generationID
    }
}

private func makeInitialModel(store: ContentStore) throws -> StressModel {
    let baseA = layer(generationID: "base-a", payload: "payload-base-a")
    let baseB = layer(generationID: "base-b", payload: "payload-base-b")
    _ = try store.activate(
        gameID: "stress-game",
        generationID: "base-a",
        layers: [baseA]
    )
    _ = try store.activate(
        gameID: "stress-game",
        generationID: "base-b",
        layers: [baseB]
    )
    try store.writeSave(
        gameID: "stress-game",
        name: "save.bin",
        data: Data("save-sentinel".utf8)
    )
    let initialLease = try store.acquireLease(gameID: "stress-game")
    return StressModel(
        active: "base-b",
        rollback: "base-a",
        materialized: [
            "base-a": "payload-base-a",
            "base-b": "payload-base-b"
        ],
        leases: [initialLease]
    )
}

private func performChildActivation(
    context: StressRunContext,
    request: StressActivationRequest,
    forceFault: Bool,
    random: inout SplitMix64,
    model: inout StressModel
) throws -> String {
    let fault = selectedFault(
        from: ContentStore.faultPoints,
        random: &random,
        force: forceFault
    )
    let status = try runChild([
        "child-activate", context.root.path, "stress-game", request.generationID,
        request.payload, request.healthOutcome.rawValue, fault
    ])
    try requireChildStatus(status, fault: fault)
    applyActivation(
        generationID: request.generationID,
        payload: request.payload,
        healthOutcome: request.healthOutcome,
        to: &model
    )
    return fault
}

private func performPublish(
    context: StressRunContext,
    request: StressOperationRequest,
    random: inout SplitMix64,
    model: inout StressModel
) throws -> StressStepResult {
    let generationID = "seed-\(context.seed)-generation-\(request.step)"
    let payload = "payload-\(context.seed)-\(request.step)-\(random.next())"
    let fault = try performChildActivation(
        context: context,
        request: StressActivationRequest(
            generationID: generationID,
            payload: payload,
            healthOutcome: .fail
        ),
        forceFault: request.forceFault,
        random: &random,
        model: &model
    )
    return StressStepResult(
        detail: generationID,
        fault: fault,
        completedSweep: false
    )
}

private func performActivate(
    context: StressRunContext,
    forceFault: Bool,
    random: inout SplitMix64,
    model: inout StressModel
) throws -> StressStepResult {
    let generationIDs = model.materialized.keys.sorted()
    let generationID = generationIDs[random.index(upperBound: generationIDs.count)]
    guard let payload = model.materialized[generationID] else {
        throw HarnessError.invariant("activation model payload is missing")
    }
    let fault = try performChildActivation(
        context: context,
        request: StressActivationRequest(
            generationID: generationID,
            payload: payload,
            healthOutcome: .pass
        ),
        forceFault: forceFault,
        random: &random,
        model: &model
    )
    return StressStepResult(
        detail: generationID,
        fault: fault,
        completedSweep: false
    )
}

private func performRollback(
    context: StressRunContext,
    forceFault: Bool,
    random: inout SplitMix64,
    model: inout StressModel
) throws -> StressStepResult {
    let generationID = model.rollback
    guard let payload = model.materialized[generationID] else {
        throw HarnessError.invariant("rollback model payload is missing")
    }
    let fault = try performChildActivation(
        context: context,
        request: StressActivationRequest(
            generationID: generationID,
            payload: payload,
            healthOutcome: .pass
        ),
        forceFault: forceFault,
        random: &random,
        model: &model
    )
    return StressStepResult(
        detail: generationID,
        fault: fault,
        completedSweep: false
    )
}

private func performLease(
    store: ContentStore,
    model: inout StressModel
) throws -> StressStepResult {
    let lease = try store.acquireLease(gameID: "stress-game")
    model.leases.append(lease)
    return StressStepResult(
        detail: lease.generationID,
        fault: "none",
        completedSweep: false
    )
}

private func performRelease(
    store: ContentStore,
    random: inout SplitMix64,
    model: inout StressModel
) throws -> StressStepResult {
    if model.leases.isEmpty {
        let lease = try store.acquireLease(gameID: "stress-game")
        model.leases.append(lease)
    }
    let index = random.index(upperBound: model.leases.count)
    let lease = model.leases.remove(at: index)
    try store.releaseLease(lease)
    return StressStepResult(
        detail: lease.generationID,
        fault: "none",
        completedSweep: false
    )
}

private func performSweep(
    context: StressRunContext,
    forceFault: Bool,
    random: inout SplitMix64,
    model: inout StressModel
) throws -> StressStepResult {
    let fault = selectedFault(
        // Per-item boundaries require a matching kind of garbage. The full
        // matrix seeds those targets; every model reaches completion points.
        from: stressCollectionFaultPoints,
        random: &random,
        force: forceFault
    )
    let status = try runChild(["child-collect", context.root.path, fault])
    try requireChildStatus(status, fault: fault)
    if status == 97 {
        _ = try ContentStore(root: context.root).collectGarbage()
    }
    let reachable = model.reachableGenerations
    model.materialized = model.materialized.filter {
        reachable.contains($0.key)
    }
    return StressStepResult(
        detail: "roots=\(reachable.sorted().joined(separator: ","))",
        fault: fault,
        completedSweep: true
    )
}

private func perform(
    context: StressRunContext,
    request: StressOperationRequest,
    random: inout SplitMix64,
    model: inout StressModel
) throws -> StressStepResult {
    switch request.operation {
    case .publish:
        try performPublish(
            context: context,
            request: request,
            random: &random,
            model: &model
        )
    case .activate:
        try performActivate(
            context: context,
            forceFault: request.forceFault,
            random: &random,
            model: &model
        )
    case .rollback:
        try performRollback(
            context: context,
            forceFault: request.forceFault,
            random: &random,
            model: &model
        )
    case .lease:
        try performLease(store: context.store, model: &model)
    case .release:
        try performRelease(store: context.store, random: &random, model: &model)
    case .sweep:
        try performSweep(
            context: context,
            forceFault: request.forceFault,
            random: &random,
            model: &model
        )
    }
}

private func runStress(root: URL, seed: UInt64, steps: Int) throws {
    let store = try ContentStore(root: root)
    let context = StressRunContext(root: root, store: store, seed: seed)
    var model = try makeInitialModel(store: store)
    var random = SplitMix64(state: seed)
    let coveragePrefix = shuffledOperations(&random)

    for step in 0..<steps {
        let operation = step < coveragePrefix.count
            ? coveragePrefix[step]
            : StressOperation.allCases[random.index(upperBound: StressOperation.allCases.count)]
        let result = try perform(
            context: context,
            request: StressOperationRequest(
                operation: operation,
                step: step,
                forceFault: step < coveragePrefix.count
            ),
            random: &random,
            model: &model
        )

        let recoveredStore = try ContentStore(root: root)
        try recoveredStore.recoverAll()
        try verifyModel(
            store: recoveredStore,
            root: root,
            model: model,
            requireExactReachability: result.completedSweep
        )
        print(
            "seed=\(seed) step=\(step) op=\(operation.rawValue) "
                + "detail=\(result.detail) fault=\(result.fault) pass"
        )
    }
    print("SEED PASS seed=\(seed) steps=\(steps)")
}

private func childActivate(_ arguments: [String]) throws {
    guard arguments.count == 8, let outcome = HealthOutcome(rawValue: arguments[6]) else {
        throw HarnessError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[2], isDirectory: true))
    _ = try store.activate(
        gameID: arguments[3],
        generationID: arguments[4],
        layers: [layer(generationID: arguments[4], payload: arguments[5])],
        healthOutcome: outcome,
        faultInjector: faultInjector(arguments[7])
    )
}

private func childCollect(_ arguments: [String]) throws {
    guard arguments.count == 4 else {
        throw HarnessError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[2], isDirectory: true))
    _ = try store.collectGarbage(faultInjector: faultInjector(arguments[3]))
}

private func run() throws {
    let arguments = CommandLine.arguments
    switch arguments.dropFirst().first {
    case "run":
        guard arguments.count == 5,
              let seed = UInt64(arguments[3]),
              let steps = Int(arguments[4]),
              steps >= StressOperation.allCases.count else {
            throw HarnessError.usage
        }
        try runStress(
            root: URL(fileURLWithPath: arguments[2], isDirectory: true),
            seed: seed,
            steps: steps
        )
    case "child-activate":
        try childActivate(arguments)
    case "child-collect":
        try childCollect(arguments)
    default:
        throw HarnessError.usage
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
