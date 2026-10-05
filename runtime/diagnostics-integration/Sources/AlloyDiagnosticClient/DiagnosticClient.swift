// Author: Timur Isaev
import AlloyDiagnostics
import AlloyDiagnosticsIntegration
import AlloyRuntimeAPI
import Darwin
import Foundation

@main struct DiagnosticClient {
    static func main() {
        umask(0o077)
        do {
            let data = try run(Array(CommandLine.arguments.dropFirst()))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data(("DIAG-" + failureCode(error) + "\n").utf8))
            exit(1)
        }
    }

    private static func run(_ args: [String]) throws -> Data {
        guard let command = args.first else { throw IntegrationError.invalidInput }
        if command == "init-store", args.count == 2 {
            try BundleLifecycle.initialize(absoluteURL(args[1]))
            return try DiagnosticsJSON.encode(["initialized": true])
        }
        if ["summary", "preview", "export", "delete"].contains(command) {
            return try lifecycle(args)
        }
        guard args.count >= 4 else { throw IntegrationError.invalidInput }
        let connection = try DiagnosticConnection(endpoint: args[1])
        if command == "observe", args.count == 4 {
            return try DiagnosticsJSON.encode(connection.observe(kind: args[2], identifier: args[3]))
        }
        guard (command == "capture" && args.count == 6) || (command == "create" && args.count == 7),
              let seconds = Double(args[5]), ["terminal", "hang"].contains(args[4]) else {
            throw IntegrationError.invalidInput
        }
        let observer = try CaptureSession(connection: connection, budgetSeconds: seconds)
        if command == "create" {
            let store = try BundleLifecycle(root: absoluteURL(args[6]))
            let configuration = connection.client.configuration
            try store.requireSeparate(from: [configuration.stateRoot, configuration.contentRoot, args[1]]
                + (configuration.libraryRoots ?? []))
            let capture = try observer.capture(kind: args[2], identifier: args[3], sampleHang: args[4] == "hang")
            return try DiagnosticsJSON.encode(store.create(capture))
        }
        return try DiagnosticsJSON.encode(observer.capture(kind: args[2], identifier: args[3],
                                                          sampleHang: args[4] == "hang"))
    }

    private static func lifecycle(_ args: [String]) throws -> Data {
        guard args.count == (args[0] == "export" ? 4 : 3) else { throw IntegrationError.invalidInput }
        let store = try BundleLifecycle(root: absoluteURL(args[1]))
        switch args[0] {
        case "delete":
            try store.delete(args[2])
            return try DiagnosticsJSON.encode(["deleted": args[2]])
        case "export":
            try store.export(args[2], to: absoluteURL(args[3]))
            return try DiagnosticsJSON.encode(CaptureBundle.summary(store.inspect(args[2])))
        case "summary": return try DiagnosticsJSON.encode(CaptureBundle.summary(store.inspect(args[2])))
        default:
            let bundle = try store.inspect(args[2])
            return try DiagnosticsJSON.encode(Preview(manifest: bundle.manifest,
                summary: CaptureBundle.summary(bundle), events: bundle.events))
        }
    }

    private struct Preview: Encodable {
        let manifest: BundleManifest
        let summary: FailureSummary
        let events: [StructuredEvent]
    }

    private static func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw IntegrationError.unsafeDestination }
        return URL(fileURLWithPath: path)
    }

    private static func failureCode(_ error: Error) -> String {
        switch error {
        case let error as IntegrationError: error.rawValue
        case RuntimeFailure.status(let status): status.rawValue
        case is DecodingError: "malformed-data"
        case is RedactionError: "redaction-refused"
        case is BundleError: "invalid-bundle"
        default: "service-or-validation-failure"
        }
    }
}
