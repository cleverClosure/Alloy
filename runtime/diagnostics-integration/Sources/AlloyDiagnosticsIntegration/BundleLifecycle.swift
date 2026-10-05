// Author: Timur Isaev
import AlloyDiagnostics
import Foundation

public struct BundleLifecycle {
    public let root: URL
    private let seconds: Double

    public init(root: URL, seconds: Double = 10) throws {
        guard seconds > 0, seconds <= 10, seconds.isFinite else { throw IntegrationError.invalidInput }
        try PrivateStore.directory(root)
        let marker = try StrictJSON.decode([String: String].self,
            from: PrivateStore.read(root.appendingPathComponent("diagnostic-store.json"), limit: 1024))
        guard marker["format"] == "alloy-local-diagnostics-v1", marker.count == 2,
              UUID(uuidString: marker["identity"] ?? "") != nil else { throw IntegrationError.invalidBundle }
        self.root = root
        self.seconds = seconds
    }

    public static func initialize(_ root: URL) throws {
        try PrivateStore.newDestination(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let marker = ["format": "alloy-local-diagnostics-v1", "identity": UUID().uuidString]
            try PrivateStore.writeNew(DiagnosticsJSON.encode(marker),
                                      to: root.appendingPathComponent("diagnostic-store.json"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    public func requireSeparate(from paths: [String]) throws {
        for path in paths {
            let other = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard root.path != other, !root.path.hasPrefix(other + "/"), !other.hasPrefix(root.path + "/") else {
                throw IntegrationError.unsafeDestination
            }
        }
    }

    public func create(_ capture: FailureCapture) throws -> FailureSummary {
        let start = ProcessInfo.processInfo.systemUptime
        let prepared = try CaptureBundle.prepare(capture)
        try checkTime(start)
        let destination = try path(prepared.manifest.bundleID)
        do {
            try prepared.export(to: destination)
            let bundle = try inspect(prepared.manifest.bundleID)
            try checkTime(start)
            return try CaptureBundle.summary(bundle)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func inspect(_ identifier: String) throws -> SealedBundle {
        let start = ProcessInfo.processInfo.systemUptime
        let directory = try path(identifier)
        try PrivateStore.directory(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 32 else { throw IntegrationError.invalidBundle }
        for name in names { _ = try PrivateStore.read(directory.appendingPathComponent(name)) }
        let result = try SealedBundleReader.read(directory)
        guard result.manifest.bundleID == identifier else { throw IntegrationError.identityMismatch }
        _ = try CaptureBundle.summary(result)
        try checkTime(start)
        return result
    }

    public func export(_ identifier: String, to destination: URL) throws {
        let start = ProcessInfo.processInfo.systemUptime
        let bundle = try inspect(identifier)
        try PrivateStore.newDestination(destination)
        guard !destination.path.hasPrefix(root.path + "/") else { throw IntegrationError.unsafeDestination }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".diag-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        for name in bundle.manifest.files.map(\.path) + ["manifest.json"] {
            try PrivateStore.writeNew(PrivateStore.read(path(identifier).appendingPathComponent(name)),
                                      to: staging.appendingPathComponent(name))
        }
        guard try SealedBundleReader.read(staging).manifest == bundle.manifest else {
            throw IntegrationError.invalidBundle
        }
        try checkTime(start)
        try PrivateStore.newDestination(destination)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    public func delete(_ identifier: String) throws {
        _ = try inspect(identifier)
        try FileManager.default.removeItem(at: path(identifier))
    }

    private func path(_ identifier: String) throws -> URL {
        guard UUID(uuidString: identifier)?.uuidString.lowercased() == identifier else {
            throw IntegrationError.unsafeDestination
        }
        return root.appendingPathComponent(identifier)
    }

    private func checkTime(_ start: Double) throws {
        guard ProcessInfo.processInfo.systemUptime - start < seconds else { throw IntegrationError.budgetExceeded }
    }
}
