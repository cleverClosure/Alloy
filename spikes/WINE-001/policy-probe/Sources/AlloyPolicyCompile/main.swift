// Author: Timur Isaev

import AlloyPolicySnapshot
import Darwin
import Foundation

private enum CommandError: Error, CustomStringConvertible {
    case usage

    var description: String {
        """
        usage:
          alloy-policy-compile compile SOURCE.json SNAPSHOT.bin
          alloy-policy-compile inspect SNAPSHOT.bin
          alloy-policy-compile compile-v2 SOURCE.json SNAPSHOT.bin
          alloy-policy-compile inspect-v2 SNAPSHOT.bin [EXPECTED_SHA256]
          alloy-policy-compile sha256 FILE
        """
    }
}

private func compile(source: String, output: String, version2: Bool = false) throws {
    let sourceURL = URL(fileURLWithPath: source)
    let outputURL = URL(fileURLWithPath: output)
    let source = try Data(contentsOf: sourceURL)
    let snapshot = try version2
        ? PolicySnapshotV2.compile(source: source) : PolicySnapshotCompiler.compile(source: source)
    try snapshot.write(to: outputURL, options: .atomic)
    guard chmod(outputURL.path, S_IRUSR | S_IRGRP | S_IROTH) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    print("snapshot=\(outputURL.path)")
    print("sha256=\(PolicySnapshotCompiler.sha256(snapshot))")
    print("bytes=\(snapshot.count)")
}

private func inspect(path: String) throws {
    let inspection = try PolicySnapshotCompiler.inspect(
        snapshot: Data(contentsOf: URL(fileURLWithPath: path))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(inspection)
    guard let output = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    print(output)
}

private func sha256(path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    print(PolicySnapshotCompiler.sha256(data))
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "compile" where arguments.count == 3:
        try compile(source: arguments[1], output: arguments[2])
    case "compile-v2" where arguments.count == 3:
        try compile(source: arguments[1], output: arguments[2], version2: true)
    case "inspect-v2" where (2...3).contains(arguments.count):
        let result = try PolicySnapshotV2.inspect(
            snapshot: Data(contentsOf: URL(fileURLWithPath: arguments[1])),
            expectedDigest: arguments.count == 3 ? arguments[2] : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(result))
        print()
    case "inspect" where arguments.count == 2:
        try inspect(path: arguments[1])
    case "sha256" where arguments.count == 2:
        try sha256(path: arguments[1])
    default:
        throw CommandError.usage
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(64)
}
