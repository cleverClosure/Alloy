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
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 4 else { throw IntegrationError.invalidInput }
            let connection = try DiagnosticConnection(endpoint: args[1])
            let data: Data
            switch args[0] {
            case "observe":
                guard args.count == 4 else { throw IntegrationError.invalidInput }
                data = try DiagnosticsJSON.encode(connection.observe(kind: args[2], identifier: args[3]))
            case "capture":
                guard args.count == 6, let seconds = Double(args[5]), ["terminal", "hang"].contains(args[4]) else {
                    throw IntegrationError.invalidInput
                }
                let capture = try CaptureSession(connection: connection, budgetSeconds: seconds)
                data = try DiagnosticsJSON.encode(capture.capture(kind: args[2], identifier: args[3],
                                                                 sampleHang: args[4] == "hang"))
            default: throw IntegrationError.invalidInput
            }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            // Error payloads can contain local paths or capabilities. Emit only a stable code.
            let code = failureCode(error)
            FileHandle.standardError.write(Data(("DIAG-" + code + "\n").utf8))
            exit(1)
        }
    }
    private static func failureCode(_ error: Error) -> String {
        switch error {
        case let error as IntegrationError: error.rawValue
        case RuntimeFailure.status(let status): status.rawValue
        case is DecodingError: "malformed-data"
        case is RedactionError: "redaction-refused"
        default: "service-or-validation-failure"
        }
    }

}
