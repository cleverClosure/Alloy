// Author: Timur Isaev
import AlloyContentStore
import AlloyStoreCatalog
import Darwin
import Foundation

struct EngineCommands {
    static let commands: Set<String> = [
        "plan-install", "start-install", "plan-uninstall", "start-uninstall", "repair",
        "inventory", "gc", "run", "pause", "resume", "cancel", "operation", "operations",
        "discover-operation", "fingerprint-operation"
    ]

    let command: String
    let arguments: [String]
    let engine: InstallationEngine

    init(_ input: [String]) throws {
        guard input.count >= 3 else {
            throw AlloyStoreCatalog.CatalogError.invalidInput("engine command requires STATE_ROOT CONTENT_ROOT")
        }
        command = input[0]
        arguments = Array(input.dropFirst(3))
        let root = URL(fileURLWithPath: input[1])
        let content = URL(fileURLWithPath: input[2])
        let environment = ProcessInfo.processInfo.environment
        let fault = environment["ALLOY_CATALOG_FAULT"]
        let control = environment["ALLOY_CATALOG_CONTROL"]
        let controlID = environment["ALLOY_CATALOG_CONTROL_OPERATION"]
        engine = try InstallationEngine(root: root, contentRoot: content) { point in
            if point == fault { kill(getpid(), SIGKILL) }
            if point == "FETCHING_0.action-complete", let control, let controlID {
                let worker = try InstallationEngine(root: root, contentRoot: content) { observed in
                    if observed == fault { kill(getpid(), SIGKILL) }
                }
                if control == "pause" { _ = try worker.pauseOperation(controlID) }
                if control == "cancel" { _ = try worker.cancelOperation(controlID) }
            }
        }
    }

    // A flat dispatch keeps each CLI command's arity visible beside its API call.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func run() throws {
        switch command {
        case "plan-install": try planInstall()
        case "start-install":
            try count(2)
            try CatalogCLI.printJSON(engine.startInstall(planID: arguments[0], idempotencyKey: arguments[1]))
        case "plan-uninstall":
            try count(2)
            try CatalogCLI.printJSON(engine.planUninstall(gameID: arguments[0], installationID: arguments[1]))
        case "start-uninstall":
            try count(2)
            try CatalogCLI.printJSON(engine.startUninstall(planID: arguments[0], idempotencyKey: arguments[1]))
        case "repair":
            try count(2)
            try CatalogCLI.printJSON(engine.repairInstallation(arguments[0], idempotencyKey: arguments[1]))
        case "inventory":
            try count(1)
            try CatalogCLI.printJSON(engine.getStorageInventory(idempotencyKey: arguments[0]))
        case "gc":
            try count(1)
            try CatalogCLI.printJSON(engine.collectGarbage(idempotencyKey: arguments[0]))
        case "run":
            try count(1)
            let result = try engine.run(arguments[0])
            try CatalogCLI.printJSON(result)
            if result.state == .failed { throw OperationError.cannotControl(result.error ?? result.operationID) }
        case "pause":
            try count(1)
            try CatalogCLI.printJSON(engine.pauseOperation(arguments[0]))
        case "resume":
            try count(1)
            let result = try engine.resumeOperation(arguments[0])
            try CatalogCLI.printJSON(result)
            if result.state == .failed { throw OperationError.cannotControl(result.error ?? result.operationID) }
        case "cancel":
            try count(1)
            try CatalogCLI.printJSON(engine.cancelOperation(arguments[0]))
        case "operation":
            try count(1)
            try CatalogCLI.printJSON(engine.journal.get(arguments[0]))
        case "operations":
            try count(0)
            try CatalogCLI.printJSON(engine.journal.list())
        case "discover-operation":
            guard arguments.count >= 2 else { throw AlloyStoreCatalog.CatalogError.invalidInput(command) }
            try CatalogCLI.printJSON(engine.discoverInstallations(
                libraryRoots: arguments.dropFirst().map { URL(fileURLWithPath: $0) }, idempotencyKey: arguments[0]))
        case "fingerprint-operation":
            guard arguments.count >= 3 else { throw AlloyStoreCatalog.CatalogError.invalidInput(command) }
            try CatalogCLI.printJSON(engine.refreshBuildFingerprint(
                installationID: arguments[1], libraryRoots: arguments.dropFirst(2).map { URL(fileURLWithPath: $0) },
                idempotencyKey: arguments[0]))
        default: throw AlloyStoreCatalog.CatalogError.invalidInput(command)
        }
    }

    private func planInstall() throws {
        guard arguments.count >= 5 else {
            throw AlloyStoreCatalog.CatalogError.invalidInput(
                "plan-install needs GAME INSTALL GENERATION LAYERS_JSON URL...")
        }
        let layers = try JSONDecoder().decode([LayerDescriptor].self,
                                              from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let mirrors = try arguments.dropFirst(4).map { text in
            guard let url = URL(string: text) else {
                throw AlloyStoreCatalog.CatalogError.invalidInput("bad mirror")
            }
            return url
        }
        try CatalogCLI.printJSON(engine.planInstall(
            gameID: arguments[0], installationID: arguments[1], generationID: arguments[2],
            layers: layers, baseURLs: mirrors))
    }

    private func count(_ expected: Int) throws {
        guard arguments.count == expected else {
            throw AlloyStoreCatalog.CatalogError.invalidInput(
                "\(command) expects \(expected) arguments after the roots")
        }
    }
}
