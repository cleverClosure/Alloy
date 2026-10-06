// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import AlloyRuntimeService
import AlloyTitleVolumes
import Darwin
import Foundation

func server(runtime: URL, prepared: PreparedSessionEnvironment) throws -> Process {
    let process = Process()
    process.executableURL = runtime.appendingPathComponent("server/wineserver")
    process.arguments = ["-f", "-p"]
    process.environment = prepared.environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func proveServers(runtime: URL, first: PreparedSessionEnvironment,
                  second: PreparedSessionEnvironment) throws -> (LeaseProcessIdentity, LeaseProcessIdentity) {
    let firstServer = try server(runtime: runtime, prepared: first)
    let secondServer = try server(runtime: runtime, prepared: second)
    usleep(300_000)
    guard firstServer.isRunning, secondServer.isRunning,
          let firstID = NativeProcessIdentity.current(firstServer.processIdentifier),
          let secondID = NativeProcessIdentity.current(secondServer.processIdentifier), firstID != secondID else {
        throw RuntimeFailure.status(.failed)
    }
    try WineControl.stop(runtime: runtime, prefix: first.prefix)
    guard !NativeProcessIdentity.mayStillBeLive(firstID), NativeProcessIdentity.isLive(secondID) else {
        throw RuntimeFailure.status(.failed)
    }
    try WineControl.stop(runtime: runtime, prefix: second.prefix)
    guard !NativeProcessIdentity.mayStillBeLive(secondID) else { throw RuntimeFailure.status(.failed) }
    return (firstID, secondID)
}

func createPlan(_ volumes: TitleVolumeStore, runtimeDigest: String) throws -> DriveMappingPlan {
    _ = try volumes.createTitle(gameID: "environment-proof")
    let cache = CacheIdentity(runtimeIdentity: runtimeDigest, providers: ["graphics": "none"],
                              compatibilityInputs: ["proof": "prefix-v1"])
    _ = try volumes.activateCache(gameID: "environment-proof", identity: cache)
    _ = try volumes.createScratch(gameID: "environment-proof", sessionID: "proof", now: 1)
    return try volumes.drivePlan(SessionVolumeRequest(gameID: "environment-proof", sessionID: "proof",
                                                          runtimeVolumeID: "runtime", payloadVolumeID: "payload"),
                                    expectedCacheIdentity: cache, now: 1)
}

func prove() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 4 else { throw RuntimeFailure.status(.malformed) }
    let store = try ContentStore(root: URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath())
    let runtime = try store.verifyDevelopmentRuntime(gameID: arguments[2])
    let lease = try store.acquireLease(gameID: arguments[2], generation: runtime.reference)
    defer { try? store.releaseLease(lease) }
    let root = URL(fileURLWithPath: arguments[3])
    guard mkdir(root.path, 0o700) == 0 else { throw RuntimeFailure.status(.conflict) }
    let content = root.appendingPathComponent("content"), state = root.appendingPathComponent("state")
    let payload = root.appendingPathComponent("payload")
    for url in [content, state, payload] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    let volumes = try TitleVolumeStore(root: content)
    let plan = try createPlan(volumes, runtimeDigest: runtime.treeDigest)
    let environment = try SessionEnvironment(stateRoot: state, contentRoot: content)
    var bootCount = 0
    func prepare(_ name: String) throws -> PreparedSessionEnvironment {
        let input = SessionEnvironmentInput(runtime: runtime.url, generation: runtime.reference.generationID,
                                            runtimeDigest: runtime.treeDigest, plan: plan, payload: payload)
        return try environment.prepare(input,
                                sessionRoot: root.appendingPathComponent(name)) { prefix in
            bootCount += 1
            try WineControl.bootstrap(runtime: runtime.url, prefix: prefix)
        }
    }
    try volumes.withSessionLease(gameID: "environment-proof", sessionID: "proof") { _ in
        let first = try prepare("first")
        let second = try prepare("second")
        defer {
            try? WineControl.stop(runtime: runtime.url, prefix: first.prefix)
            try? WineControl.stop(runtime: runtime.url, prefix: second.prefix)
        }
        guard first.prefixDigest == second.prefixDigest, first.templateDigest == second.templateDigest,
              bootCount == 1 else { throw RuntimeFailure.status(.conflict) }
        let (firstID, secondID) = try proveServers(runtime: runtime.url, first: first, second: second)
        let after = try store.verifyDevelopmentRuntime(gameID: arguments[2])
        guard after.treeDigest == runtime.treeDigest, after.reference == runtime.reference else {
            throw RuntimeFailure.status(.conflict)
        }
        let report: [String: String] = ["author": "Timur Isaev", "status": "pass",
            "runtimeTreeDigest": runtime.treeDigest, "templateDigest": first.templateDigest,
            "prefixDigest": first.prefixDigest, "bootCount": String(bootCount),
            "firstServer": String(firstID.processID), "secondServer": String(secondID.processID),
            "isolation": "stopping first preserved second; neither survives cleanup", "runtimeUnchanged": "true"]
        let bytes = try RuntimeEncoding.encode(report)
        try bytes.write(to: root.appendingPathComponent("proof.json"))
        FileHandle.standardOutput.write(bytes + Data("\n".utf8))
    }
}

umask(0o077)
do { try prove() } catch {
    FileHandle.standardError.write(Data("environment proof: \(error)\n".utf8))
    exit(1)
}
