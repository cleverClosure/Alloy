// Author: Timur Isaev
import AlloyClientCore
import Foundation

/// Non-GUI contract proof using the exact observable controller used by the app.
@main struct ClientProbe {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5 else { throw ProbeError.arguments }
        let storage = PreferencesStore(directory: URL(fileURLWithPath: arguments[3]))
        let store = ClientStore(storage: storage)
        let controller = RuntimeController(store: store, storage: storage)
        await controller.connect(endpoint: arguments[1], fixture: arguments[2] == "-" ? nil : arguments[2])
        try await perform(arguments, controller: controller)
        let report = ProbeReport(connected: store.snapshot.connected, games: store.snapshot.games,
                                 problem: (controller.problem ?? controller.connectionProblem)?.supportCode,
                                 instanceID: controller.instanceID,
                                 planned: controller.plan != nil, cachedActivities: store.snapshot.activities.count,
                                 operations: controller.operations.map {
                                     ProbeOperation(id: $0.id, state: $0.state, revision: $0.update.revision,
                                                    workerActive: $0.update.workerActive,
                                                    bytesCompleted: $0.update.snapshot.progress.bytesCompleted)
                                 }, sessions: controller.sessions.map {
                                     ProbeSession(id: $0.id, state: $0.state, liveNodes: $0.snapshot.liveNodes,
                                                  finished: $0.finished)
                                 })
        FileHandle.standardOutput.write(try JSONEncoder().encode(report))
        print("")
    }
    @MainActor private static func perform(_ arguments: [String], controller: RuntimeController) async throws {
        let command = arguments[4]
        if ["pause", "resume", "cancel", "run", "session-stop"].contains(command) {
            guard arguments.count == 6 else { throw ProbeError.arguments }
            if command == "session-stop" { await controller.stopSession(arguments[5]) } else {
                await controller.control(arguments[5], command: command)
            }
            return
        }
        switch command {
        case "snapshot": break
        case "plan": await controller.prepareInstall()
        case "install":
            await controller.prepareInstall()
            if controller.problem == nil { await controller.installRuntime() }
        case "inventory": await controller.checkStorage()
        case "session-start": await controller.startDevelopmentSession()
        default: throw ProbeError.arguments
        }
    }
}

private enum ProbeError: Error { case arguments }
private struct ProbeReport: Encodable {
    let connected: Bool
    let games: [LibraryGame]
    let problem: String?
    let instanceID: String?
    let planned: Bool
    let cachedActivities: Int
    let operations: [ProbeOperation]
    let sessions: [ProbeSession]
}
private struct ProbeOperation: Encodable {
    let id: String
    let state: String
    let revision: Int
    let workerActive: Bool
    let bytesCompleted: UInt64
}
private struct ProbeSession: Encodable {
    let id: String
    let state: String
    let liveNodes: [String]
    let finished: Bool
}
