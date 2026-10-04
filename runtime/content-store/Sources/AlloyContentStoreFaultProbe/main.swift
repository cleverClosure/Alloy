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
              alloy-content-store-fault-probe seed-gc-leftovers ROOT
              alloy-content-store-fault-probe collect ROOT
              alloy-content-store-fault-probe verify-gc ROOT GAME ACTIVE SAVE OBJECTS REMOVED_GENERATION
              alloy-content-store-fault-probe transport ROOT BASE_URL OPERATION
              alloy-content-store-fault-probe transport-handshake ROOT BASE_URL OPERATION POINT REACHED CONTINUE
              alloy-content-store-fault-probe transport-announced ROOT BASE_URL OPERATION ENTERED DONE
              alloy-content-store-fault-probe verify-transport ROOT BASE_URL OPERATION [EXPECTED_OBJECTS]
              alloy-content-store-fault-probe verify-transport-staging ROOT OPERATION downloading|published|absent
              alloy-content-store-fault-probe wait-marker PATH
              alloy-content-store-fault-probe write-marker PATH
              alloy-content-store-fault-probe lease-hold ROOT GAME READY RELEASE ATTEMPTED DONE
              alloy-content-store-fault-probe lease-hold-contended ROOT GAME READY RELEASE ATTEMPTED DONE
              alloy-content-store-fault-probe collect-handshake ROOT POINT REACHED CONTINUE
              alloy-content-store-fault-probe collect-announced ROOT ENTERED DONE
              alloy-content-store-fault-probe update-handshake ROOT GAME GEN PAYLOAD OUTCOME POINT REACHED CONTINUE
              alloy-content-store-fault-probe update-announced ROOT GAME GEN PAYLOAD OUTCOME ENTERED DONE
              alloy-content-store-fault-probe verify-generation ROOT GAME GENERATION present|absent
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

func markerURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: false)
}

func writeMarker(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("ready\n".utf8).write(to: url, options: .atomic)
}

private func waitForMarker(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: url.path) {
        return
    }

    let directoryDescriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
    guard directoryDescriptor >= 0 else {
        throw CommandError.verification("cannot watch marker directory")
    }
    defer { close(directoryDescriptor) }
    let queue = kqueue()
    guard queue >= 0 else {
        throw CommandError.verification("cannot create marker event queue")
    }
    defer { close(queue) }

    var change = kevent(
        ident: UInt(directoryDescriptor),
        filter: Int16(EVFILT_VNODE),
        flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
        fflags: UInt32(NOTE_WRITE | NOTE_RENAME | NOTE_EXTEND),
        data: 0,
        udata: nil
    )
    guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
        throw CommandError.verification("cannot register marker event")
    }

    while !FileManager.default.fileExists(atPath: url.path) {
        var event = kevent()
        var timeout = timespec(tv_sec: 30, tv_nsec: 0)
        let result = kevent(queue, nil, 0, &event, 1, &timeout)
        if result < 0, errno == EINTR {
            continue
        }
        guard result > 0 else {
            throw CommandError.verification("timed out waiting for marker \(url.lastPathComponent)")
        }
    }
}

func handshakeInjector(
    point: String,
    reached: URL,
    continuation: URL
) -> FaultInjector {
    { observed in
        guard observed == point else {
            return
        }
        try writeMarker(reached)
        try waitForMarker(continuation)
    }
}

func requireExclusiveLockIsContended(_ root: URL) throws {
    let lock = root.appendingPathComponent("metadata/content-store.lock")
    let descriptor = open(lock.path, O_RDWR)
    guard descriptor >= 0 else {
        throw CommandError.verification("cannot open content-store lock")
    }
    defer { close(descriptor) }

    errno = 0
    let result = flock(descriptor, LOCK_EX | LOCK_NB)
    if result == 0 {
        flock(descriptor, LOCK_UN)
        throw CommandError.verification("content-store lock was not contended")
    }
    guard errno == EWOULDBLOCK || errno == EAGAIN else {
        throw CommandError.verification("unexpected nonblocking lock error \(errno)")
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

func verifyCatalogConsistency(_ store: ContentStore) throws {
    let report = try store.catalogConsistencyReport()
    guard report.isConsistent else {
        throw CommandError.verification(
            "catalog diverged: \(report.catalogAhead.count) catalog-ahead, "
                + "\(report.diskAhead.count) disk-ahead record(s)"
        )
    }
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
    guard inspection.candidate == nil else {
        throw CommandError.verification("candidate reference survived recovery")
    }
    if let active = inspection.active {
        try store.validateReference(active, gameID: arguments[2])
    }
    if let rollback = inspection.rollback {
        try store.validateReference(rollback, gameID: arguments[2])
    }
    try verifyCatalogConsistency(store)
}

private func inspect(_ arguments: [String]) throws {
    guard arguments.count == 3 else {
        throw CommandError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    try printInspection(store.inspect(gameID: arguments[2]))
}

private func seedGarbageCollectionLeftovers(_ arguments: [String]) throws {
    guard arguments.count == 2 else {
        throw CommandError.usage
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let download = root
        .appendingPathComponent("downloads/abandoned", isDirectory: true)
    let quarantine = root.appendingPathComponent("quarantine", isDirectory: true)
    try FileManager.default.createDirectory(
        at: download,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: quarantine,
        withIntermediateDirectories: true
    )
    try stringData("abandoned-download").write(
        to: download.appendingPathComponent("payload.part")
    )
    try stringData("quarantine-leftover").write(
        to: quarantine.appendingPathComponent("orphan")
    )
}

private func collect(_ arguments: [String]) throws {
    guard arguments.count == 2 else {
        throw CommandError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    _ = try store.collectGarbage(faultInjector: faultInjector())
}

private func verifyGarbageCollection(_ arguments: [String]) throws {
    guard arguments.count == 7, let expectedObjects = Int(arguments[5]) else {
        throw CommandError.usage
    }
    try verify(Array(arguments[0...4]))
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let store = try ContentStore(root: root)
    let inspection = try store.inspect(gameID: arguments[2])
    guard inspection.objectCount == expectedObjects else {
        throw CommandError.verification(
            "objects \(inspection.objectCount), expected \(expectedObjects)"
        )
    }
    let removedGeneration = root
        .appendingPathComponent("generations", isDirectory: true)
        .appendingPathComponent(arguments[2], isDirectory: true)
        .appendingPathComponent(arguments[6], isDirectory: true)
    guard !FileManager.default.fileExists(atPath: removedGeneration.path) else {
        throw CommandError.verification(
            "unreachable generation \(arguments[6]) survived collection"
        )
    }
    for relativePath in ["downloads/abandoned", "quarantine/orphan"] {
        guard !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(relativePath).path
        ) else {
            throw CommandError.verification("\(relativePath) survived collection")
        }
    }
    let secondPass = try store.collectGarbage()
    guard secondPass == .zero else {
        throw CommandError.verification("second collection was not exact zero")
    }
    try verifyCatalogConsistency(store)
}

private func waitMarker(_ arguments: [String]) throws {
    guard arguments.count == 2 else {
        throw CommandError.usage
    }
    try waitForMarker(markerURL(arguments[1]))
}

private func writeMarkerCommand(_ arguments: [String]) throws {
    guard arguments.count == 2 else {
        throw CommandError.usage
    }
    try writeMarker(markerURL(arguments[1]))
}

private func holdLease(
    _ arguments: [String],
    requireReleaseContention: Bool
) throws {
    guard arguments.count == 7 else {
        throw CommandError.usage
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let store = try ContentStore(root: root)
    let lease = try store.acquireLease(gameID: arguments[2])
    try writeMarker(markerURL(arguments[3]))
    try waitForMarker(markerURL(arguments[4]))
    if requireReleaseContention {
        try requireExclusiveLockIsContended(root)
    }
    try writeMarker(markerURL(arguments[5]))
    try store.releaseLease(lease)
    try writeMarker(markerURL(arguments[6]))
}

private func holdLeaseUncontended(_ arguments: [String]) throws {
    try holdLease(arguments, requireReleaseContention: false)
}

private func holdLeaseContended(_ arguments: [String]) throws {
    try holdLease(arguments, requireReleaseContention: true)
}

private func collectWithHandshake(_ arguments: [String]) throws {
    guard arguments.count == 5 else {
        throw CommandError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    _ = try store.collectGarbage(faultInjector: handshakeInjector(
        point: arguments[2],
        reached: markerURL(arguments[3]),
        continuation: markerURL(arguments[4])
    ))
}

private func collectAnnounced(_ arguments: [String]) throws {
    guard arguments.count == 4 else {
        throw CommandError.usage
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    try requireExclusiveLockIsContended(root)
    try writeMarker(markerURL(arguments[2]))
    let store = try ContentStore(root: root)
    _ = try store.collectGarbage()
    try writeMarker(markerURL(arguments[3]))
}

private func updateWithHandshake(_ arguments: [String]) throws {
    guard arguments.count == 9, let outcome = HealthOutcome(rawValue: arguments[5]) else {
        throw CommandError.usage
    }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
    _ = try store.activate(
        gameID: arguments[2],
        generationID: arguments[3],
        layers: [layer(generationID: arguments[3], payload: arguments[4])],
        healthOutcome: outcome,
        faultInjector: handshakeInjector(
            point: arguments[6],
            reached: markerURL(arguments[7]),
            continuation: markerURL(arguments[8])
        )
    )
}

private func updateAnnounced(_ arguments: [String]) throws {
    guard arguments.count == 8, let outcome = HealthOutcome(rawValue: arguments[5]) else {
        throw CommandError.usage
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    try requireExclusiveLockIsContended(root)
    try writeMarker(markerURL(arguments[6]))
    let store = try ContentStore(root: root)
    _ = try store.activate(
        gameID: arguments[2],
        generationID: arguments[3],
        layers: [layer(generationID: arguments[3], payload: arguments[4])],
        healthOutcome: outcome
    )
    try writeMarker(markerURL(arguments[7]))
}

private func verifyGeneration(_ arguments: [String]) throws {
    guard arguments.count == 5,
          arguments[4] == "present" || arguments[4] == "absent" else {
        throw CommandError.usage
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let generationDirectory = root
        .appendingPathComponent("generations", isDirectory: true)
        .appendingPathComponent(arguments[2], isDirectory: true)
        .appendingPathComponent(arguments[3], isDirectory: true)
    let exists = FileManager.default.fileExists(atPath: generationDirectory.path)
    guard exists == (arguments[4] == "present") else {
        throw CommandError.verification(
            "generation \(arguments[3]) was \(exists ? "present" : "absent")"
        )
    }
    let store = try ContentStore(root: root)
    try verifyCatalogConsistency(store)
    guard exists else {
        return
    }
    let manifest = try Data(contentsOf: generationDirectory.appendingPathComponent("manifest.json"))
    let reference = GenerationReference(
        generationID: arguments[3],
        manifestDigest: ContentStore.digest(manifest)
    )
    try store.validateReference(reference, gameID: arguments[2])
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if try runLifecycleCommand(arguments) { return }
    let commands: [String: ([String]) throws -> Void] = [
        "bootstrap": bootstrap,
        "update": update,
        "recover": recover,
        "verify": verify,
        "inspect": inspect,
        "seed-gc-leftovers": seedGarbageCollectionLeftovers,
        "collect": collect,
        "verify-gc": verifyGarbageCollection,
        "transport": fetchTransportCommand,
        "transport-handshake": fetchTransportWithHandshakeCommand,
        "transport-announced": fetchTransportAnnouncedCommand,
        "verify-transport": verifyTransportCommand,
        "verify-transport-staging": verifyTransportStagingCommand,
        "wait-marker": waitMarker,
        "write-marker": writeMarkerCommand,
        "lease-hold": holdLeaseUncontended,
        "lease-hold-contended": holdLeaseContended,
        "collect-handshake": collectWithHandshake,
        "collect-announced": collectAnnounced,
        "update-handshake": updateWithHandshake,
        "update-announced": updateAnnounced,
        "verify-generation": verifyGeneration
    ]
    guard let name = arguments.first, let command = commands[name] else {
        throw CommandError.usage
    }
    try command(arguments)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
