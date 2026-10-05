// Author: Timur Isaev

import AlloyProfileCompiler
import Darwin
import Foundation

// Development handoff for an already resolved, trusted local policy tuple.
// This command does not select/sign a profile or authorize/execute a launch.
private struct PolicyInput: Codable {
    let id: String
    let providerDirectory: String
    let resolved: ResolvedProcessPolicy

    var policy: SnapshotPolicy { SnapshotPolicy(id: id, providerDirectory: providerDirectory, resolved: resolved) }
}

private struct ProcessInput: Codable {
    let imageSHA256: String
    let policy: PolicyInput
}

private struct Request: Codable {
    let schemaVersion: String
    let defaultPolicy: PolicyInput
    let processes: [ProcessInput]
}

private struct Report: Encodable {
    let author = "Timur Isaev"
    let format = "alloy-development-policy-export-v2"
    let productionEligible = false
    let runtimeReady: Bool
    let digest: String
    let notYetLowered: [SnapshotCoverageGap]
}

private func export(_ input: String, output: String) throws {
    let bytes = try CanonicalJSON.encode(Data(contentsOf: URL(fileURLWithPath: input)))
    let request = try JSONDecoder().decode(Request.self, from: bytes)
    guard request.schemaVersion == "alloy-resolved-policy-v2-development",
          try CanonicalJSON.encode(request) == bytes else {
        throw CompilerFailure.rejected("noncanonical, unknown or unsupported development request fields")
    }
    let result = try PolicySnapshotExporter.export(
        defaultPolicy: request.defaultPolicy.policy,
        processes: request.processes.map { SnapshotProcess(imageSHA256: $0.imageSHA256, policy: $0.policy.policy) }
    )
    guard mkdir(output, 0o700) == 0 else { throw CompilerFailure.rejected("output directory must be new") }
    let root = URL(fileURLWithPath: output)
    let snapshot = root.appendingPathComponent("policy.snapshot")
    try result.bytes.write(to: snapshot, options: .atomic)
    guard chmod(snapshot.path, 0o400) == 0 else { throw CocoaError(.fileWriteUnknown) }
    try result.source.write(to: root.appendingPathComponent("source.json"), options: .atomic)
    let report = try CanonicalJSON.encode(Report(
        runtimeReady: result.runtimeReady, digest: result.digest, notYetLowered: result.notYetLowered
    ))
    try report.write(to: root.appendingPathComponent("report.json"), options: .atomic)
    FileHandle.standardOutput.write(report + Data("\n".utf8))
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw CompilerFailure.rejected("usage: alloy-snapshot-export RESOLVED-DEVELOPMENT.json NEW_DIRECTORY")
    }
    try export(CommandLine.arguments[1], output: CommandLine.arguments[2])
} catch {
    FileHandle.standardError.write(Data("snapshot-export: \(error)\n".utf8))
    exit(64)
}
