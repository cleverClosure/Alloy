// Author: Timur Isaev

import AlloyTitleVolumes
import Foundation

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
        throw VolumeError.integrityMismatch
    }
    print(text)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 3 else { throw VolumeError.invalidPolicy }
    let command = arguments[0]
    let store = try TitleVolumeStore(root: URL(fileURLWithPath: arguments[1]))
    let gameID = arguments[2]
    switch command {
    case "init":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        try emit(store.createTitle(gameID: gameID))
    case "list":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        try emit(store.records(gameID: gameID))
    case "audit":
        guard arguments.count == 3 else { throw VolumeError.invalidPolicy }
        for record in try store.records(gameID: gameID) {
            try emit(store.inventory(gameID: gameID, kind: record.kind, generation: record.generation))
        }
    case "scratch-create":
        guard arguments.count == 5, let now = Int64(arguments[4]) else { throw VolumeError.invalidPolicy }
        try emit(store.createScratch(gameID: gameID, sessionID: arguments[3], now: now))
    case "scratch-expire":
        guard arguments.count == 4, let now = Int64(arguments[3]) else { throw VolumeError.invalidPolicy }
        try emit(store.expireScratch(gameID: gameID, now: now))
    default: throw VolumeError.invalidPolicy
    }
} catch {
    FileHandle.standardError.write(Data("alloy-volumes: \(error)\n".utf8))
    exit(1)
}
