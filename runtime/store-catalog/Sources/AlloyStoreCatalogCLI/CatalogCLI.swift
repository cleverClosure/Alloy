// Author: Timur Isaev
import AlloyStoreCatalog
import AlloyContentStore
import Foundation
import Darwin

@main
struct CatalogCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2 else {
                throw AlloyStoreCatalog.CatalogError.invalidInput(
                    "usage: alloy-store-catalog list|discover|get|fingerprint LIBRARY [ID]")
            }
            if EngineCommands.commands.contains(args[0]) {
                try EngineCommands(args).run()
                return
            }
            if args[0] == "install-probe" {
                try installProbe(args)
                return
            }
            if args[0] == "journal-probe" {
                try journalProbe(args)
                return
            }
            let catalog = try StoreCatalog(libraryRoots: [URL(fileURLWithPath: args[1])])
            switch args[0] {
            case "list" where args.count == 2: try printJSON(catalog.listGames())
            case "discover" where args.count == 2: try printJSON(catalog.discoverInstallations())
            case "get" where args.count == 3: try printJSON(catalog.getGame(args[2]))
            case "fingerprint" where args.count == 3: try printJSON(catalog.refreshBuildFingerprint(args[2]))
            default: throw AlloyStoreCatalog.CatalogError.invalidInput("unknown command or wrong argument count")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func installProbe(_ args: [String]) throws {
        guard args.count == 3, let baseURL = URL(string: args[2]) else {
            throw AlloyStoreCatalog.CatalogError.invalidInput("install-probe ROOT BASE_URL")
        }
        let root = URL(fileURLWithPath: args[1])
        let point = ProcessInfo.processInfo.environment["ALLOY_CATALOG_FAULT"]
        let engine = try InstallationEngine(root: root.appendingPathComponent("catalog"),
                                             contentRoot: root.appendingPathComponent("content")) { observed in
            if observed == point { kill(getpid(), SIGKILL) }
        }
        let bytes = Data("catalog synthetic runtime layer\n".utf8)
        let descriptor = LayerDescriptor(name: "fixture", version: "1", digest: ContentStore.digest(bytes),
                                         mediaType: "application/octet-stream", size: bytes.count, role: .hostRuntime)
        let plan = try engine.planInstall(gameID: "fixture", installationID: "fixture-install",
                                          generationID: "fixture-generation", layers: [descriptor], baseURLs: [baseURL])
        let operation = try engine.startInstall(planID: plan.planID, idempotencyKey: "fixture-install")
        let result = try engine.run(operation.operationID)
        try printJSON(result)
        if result.state != .succeeded { throw OperationError.cannotControl(result.operationID) }
    }

    static func journalProbe(_ args: [String]) throws {
        guard args.count == 3 else { throw AlloyStoreCatalog.CatalogError.invalidInput("journal-probe ROOT seed|run") }
        let point = ProcessInfo.processInfo.environment["ALLOY_CATALOG_FAULT"]
        let journal = try OperationJournal(root: URL(fileURLWithPath: args[1])) { observed in
            if observed == point { kill(getpid(), SIGKILL) }
        }
        let operation = try journal.create(kind: .install, idempotencyKey: "probe", payload: ["fixture": "known"])
        if args[2] == "run" && operation.state == .queued {
            try printJSON(journal.transition(operation.operationID, to: .running, stage: "RUNNING"))
        } else if args[2] == "seed" {
            try printJSON(operation)
        } else { throw AlloyStoreCatalog.CatalogError.invalidInput("unknown journal probe") }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8))
    }
}
