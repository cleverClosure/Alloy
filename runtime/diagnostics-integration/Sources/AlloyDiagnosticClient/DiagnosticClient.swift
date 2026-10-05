// Author: Timur Isaev
import AlloyDiagnostics
import AlloyDiagnosticsIntegration
import Darwin
import Foundation

@main struct DiagnosticClient {
    static func main() {
        umask(0o077)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 4, args[0] == "observe" else { throw IntegrationError.invalidInput }
            let connection = try DiagnosticConnection(endpoint: args[1])
            let observation = try connection.observe(kind: args[2], identifier: args[3])
            FileHandle.standardOutput.write(try DiagnosticsJSON.encode(observation))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            // Error payloads can contain local paths or capabilities. Emit only a stable code.
            let code = (error as? IntegrationError)?.rawValue ?? "service-or-validation-failure"
            FileHandle.standardError.write(Data(("DIAG-" + code + "\n").utf8))
            exit(1)
        }
    }
}
