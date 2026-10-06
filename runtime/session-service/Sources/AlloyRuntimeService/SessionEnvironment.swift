// Author: Timur Isaev

import AlloyContentStore
import AlloyRuntimeAPI
import AlloyTitleVolumes
import Foundation

public struct PreparedSessionEnvironment: Codable, Sendable {
    public let prefix: URL
    public let templateDigest: String
    public let prefixDigest: String
    public let drivePlan: DriveMappingPlan
    public let environment: [String: String]
}

public struct SessionEnvironmentInput {
    public let runtime: URL
    public let generation: String
    public let runtimeDigest: String
    public let plan: DriveMappingPlan
    public let payload: URL

    public init(runtime: URL, generation: String, runtimeDigest: String, plan: DriveMappingPlan, payload: URL) {
        self.runtime = runtime
        self.generation = generation
        self.runtimeDigest = runtimeDigest
        self.plan = plan
        self.payload = payload
    }
}

public final class SessionEnvironment {
    private let content: URL
    private let templates: PrefixTemplate

    public init(stateRoot: URL, contentRoot: URL) throws {
        content = contentRoot
        templates = try PrefixTemplate(root: stateRoot.appendingPathComponent("prefix-templates"))
    }

    /// Caller holds the generation and title-volume leases and has verified the runtime/payload.
    public func prepare(_ input: SessionEnvironmentInput, sessionRoot: URL,
                        bootstrap: (URL) throws -> Void) throws -> PreparedSessionEnvironment {
        let plan = input.plan
        guard !plan.hostRootMapped, plan.drives.map(\.letter) == ["C", "G", "S", "T"],
              Set(plan.volumeIDs.keys) == ["runtime", "game", "saves", "settings", "cache", "temp"],
              plan.saveRedirections.isEmpty else { throw RuntimeFailure.status(.notReady) }
        try privateDirectory(sessionRoot)
        let prefix = sessionRoot.appendingPathComponent("prefix")
        let digest = try templates.copy(generation: input.generation, runtimeDigest: input.runtimeDigest,
                                        runtime: input.runtime,
                                        destination: prefix, bootstrap: bootstrap)
        try mapDrives(plan, prefix: prefix, sessionRoot: sessionRoot, payload: input.payload)
        let construction = try RuntimeEncoding.encode(PrefixConstruction(templateDigest: digest, drivePlan: plan))
        return PreparedSessionEnvironment(prefix: prefix, templateDigest: digest,
                                           prefixDigest: ContentStore.digest(construction), drivePlan: plan,
                                           environment: Self.scrubbed(runtime: input.runtime, prefix: prefix))
    }

    private func mapDrives(_ plan: DriveMappingPlan, prefix: URL, sessionRoot: URL, payload: URL) throws {
        let volumes = try TitleVolumeStore(root: content)
        let records = try volumes.records(gameID: plan.gameID)
        var bindings = [String: URL]()
        for kind in ["saves", "settings", "cache", "temp"] {
            guard let record = records.first(where: { $0.id == plan.volumeIDs[kind] }),
                  record.kind.rawValue == (kind == "temp" ? "scratch" : kind),
                  kind != "temp" || record.generation == plan.sessionID else {
                throw RuntimeFailure.status(.conflict)
            }
            _ = try volumes.inventory(gameID: plan.gameID, kind: record.kind, generation: record.generation)
            bindings[record.id] = content.appendingPathComponent(record.relativePath)
        }
        let windows = prefix.appendingPathComponent("drive_c")
        let saved = sessionRoot.appendingPathComponent("saved")
        try filesDirectory(windows)
        try filesDirectory(windows.appendingPathComponent("temp"))
        try privateDirectory(saved)
        guard let runtimeID = plan.volumeIDs["runtime"], let gameID = plan.volumeIDs["game"] else {
            throw RuntimeFailure.status(.conflict)
        }
        bindings[runtimeID] = windows
        bindings[gameID] = payload
        let files = FileManager.default
        for drive in plan.drives {
            let target: URL
            if drive.letter == "S" {
                guard drive.bindings.map(\.relativePath) == ["saves", "settings"],
                      drive.bindings.allSatisfy({ $0.access == .readWrite }) else {
                    throw RuntimeFailure.status(.conflict)
                }
                for binding in drive.bindings {
                    guard binding.volumeID == plan.volumeIDs[binding.relativePath],
                          let source = bindings[binding.volumeID] else { throw RuntimeFailure.status(.conflict) }
                    try files.createSymbolicLink(at: saved.appendingPathComponent(binding.relativePath),
                                                withDestinationURL: source)
                }
                target = saved
            } else {
                guard drive.bindings.count == 1, let binding = drive.bindings.first,
                      binding.relativePath.isEmpty, let source = bindings[binding.volumeID],
                      binding.volumeID == plan.volumeIDs[["C": "runtime", "G": "game", "T": "temp"][drive.letter]!],
                      binding.access == (drive.letter == "T" ? .readWrite : .readOnly) else {
                    throw RuntimeFailure.status(.conflict)
                }
                target = source
            }
            let link = prefix.appendingPathComponent("dosdevices/" + drive.letter.lowercased() + ":")
            try files.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }

    public static func scrubbed(runtime: URL, prefix: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": prefix.path, "TMPDIR": prefix.appendingPathComponent("drive_c/temp").path,
         "LANG": "C", "WINEPREFIX": prefix.path, "WINELOADER": runtime.appendingPathComponent("loader/wine").path,
         "WINESERVER": runtime.appendingPathComponent("server/wineserver").path,
         "WINEDEBUG": "-all,+alloy,+loaddll,+xtajit", "WINEDLLOVERRIDES": "mscoree,mshtml=", "FEX_SILENTLOG": "1"]
    }
}

private struct PrefixConstruction: Encodable {
    let templateDigest: String
    let drivePlan: DriveMappingPlan
}

private func filesDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
}
