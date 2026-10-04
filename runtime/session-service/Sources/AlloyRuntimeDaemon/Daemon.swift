// Author: Timur Isaev
import AlloyRuntimeAPI
import AlloyRuntimeService
import Darwin
import Foundation

@main struct Daemon {
    static func main() {
        umask(0o077)
        do {
            guard CommandLine.arguments.count == 2 else { throw RuntimeFailure.invalidConfiguration }
            let configuration = try ServiceConfiguration.read(CommandLine.arguments[1])
            let listener = ServiceListener(configuration: configuration)
            listener.resume()
            withExtendedLifetime(listener) { dispatchMain() }
        } catch {
            FileHandle.standardError.write(Data("runtime service refused startup\n".utf8))
            exit(1)
        }
    }
}
