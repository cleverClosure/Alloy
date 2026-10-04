// Author: Timur Isaev
import AlloyRuntimeAPI
import Darwin
import Foundation

@main struct ClientCLI {
    static func main() {
        do {
            guard CommandLine.arguments.count >= 3 else { throw RuntimeFailure.invalidConfiguration }
            let configuration = try ServiceConfiguration.read(CommandLine.arguments[1])
            let client = RuntimeClient(configuration: configuration)
            let method = CommandLine.arguments[2]
            let response: RuntimeResponse
            if method == "raw" {
                let bytes = FileHandle.standardInput.readData(ofLength: RuntimeLimits.messageBytes + 1)
                response = try JSONDecoder().decode(RuntimeResponse.self, from: client.exchange(bytes))
            } else {
                response = try client.call(method)
            }
            let payload = try JSONSerialization.jsonObject(with: response.payload)
            let output: [String: Any] = ["requestID": response.requestID, "code": response.status.code.rawValue,
                                         "supportCode": response.status.supportCode, "payload": payload]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
            FileHandle.standardOutput.write(Data("\n".utf8))
            if response.status.code != .ok { exit(2) }
        } catch {
            FileHandle.standardError.write(Data("runtime client request failed\n".utf8))
            exit(1)
        }
    }
}
