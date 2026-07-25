// Author: Timur Isaev

import AlloyContentStore
import Darwin
import Foundation

private enum CommandError: Error, CustomStringConvertible {
    case usage
    case verification(String)

    var description: String {
        switch self {
        case .usage:
            """
            usage:
              alloy-content-store-fault-probe bootstrap ROOT GAME GENERATION PAYLOAD SAVE
              alloy-content-store-fault-probe update ROOT GAME GENERATION PAYLOAD pass|fail
              alloy-content-store-fault-probe recover ROOT
              alloy-content-store-fault-probe verify ROOT GAME ACTIVE SAVE
              alloy-content-store-fault-probe inspect ROOT GAME
            """
        case let .verification(message):
            "verification failed: \(message)"
        }
    }
}

private func faultInjector() -> FaultInjector {
    let selected = ProcessInfo.processInfo.environment["ALLOY_FAULT_AFTER"]
    return { point in
        if point == selected {
            _exit(97)
        }
    }
}

private func layer(generationID: String, payload: String) -> LayerInput {
    let data = Data(payload.utf8)
    return LayerInput(
        descriptor: LayerDescriptor(
            name: "fault-probe-runtime",
            version: generationID,
            digest: ContentStore.digest(data),
            mediaType: "application/vnd.alloy.test-layer",
            size: data.count,
            role: .hostRuntime,
            sourceRevision: generationID
        ),
        contents: data
    )
}

private func stringData(_ value: String) -> Data {
    Data(value.utf8)
}

private func printInspection(_ inspection: StoreInspection) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(inspection)
    print(try decodeUTF8(data))
}

private func decodeUTF8(_ data: Data) throws -> String {
    guard let result = String(bytes: data, encoding: .utf8) else {
        throw CommandError.verification("invalid UTF-8")
    }
    return result
}

private func bootstrap(_ arguments: [String]) throws {
    guard arguments.count == 6 else {
        throw CommandError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    _ = try store.activate(
        gameID: arguments[2],
        generationID: arguments[3],
        layers: [layer(generationID: arguments[3], payload: arguments[4])]
    )
    try store.writeSave(gameID: arguments[2], name: "save.bin", data: stringData(arguments[5]))
}

private func update(_ arguments: [String]) throws {
    guard arguments.count == 6, let outcome = HealthOutcome(rawValue: arguments[5]) else {
        throw CommandError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    _ = try store.activate(
        gameID: arguments[2],
        generationID: arguments[3],
        layers: [layer(generationID: arguments[3], payload: arguments[4])],
        healthOutcome: outcome,
        faultInjector: faultInjector()
    )
}

private func recover(_ arguments: [String]) throws {
    guard arguments.count == 2 else {
        throw CommandError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    try store.recoverAll()
}

private func verify(_ arguments: [String]) throws {
    guard arguments.count == 5 else {
        throw CommandError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    let inspection = try store.inspect(gameID: arguments[2])
    guard inspection.active?.generationID == arguments[3] else {
        throw CommandError.verification(
            "active \(inspection.active?.generationID ?? "none"), expected \(arguments[3])"
        )
    }
    let save = try decodeUTF8(store.readSave(gameID: arguments[2], name: "save.bin"))
    guard save == arguments[4] else {
        throw CommandError.verification("save sentinel changed")
    }
    guard inspection.incompleteOperationCount == 0 else {
        throw CommandError.verification(
            "\(inspection.incompleteOperationCount) operation(s) remain incomplete"
        )
    }
    if let active = inspection.active {
        try store.validateReference(active, gameID: arguments[2])
    }
}

private func inspect(_ arguments: [String]) throws {
    guard arguments.count == 3 else {
        throw CommandError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    try printInspection(store.inspect(gameID: arguments[2]))
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "bootstrap":
        try bootstrap(arguments)
    case "update":
        try update(arguments)
    case "recover":
        try recover(arguments)
    case "verify":
        try verify(arguments)
    case "inspect":
        try inspect(arguments)
    default:
        throw CommandError.usage
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
