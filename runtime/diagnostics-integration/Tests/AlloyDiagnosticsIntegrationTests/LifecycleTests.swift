// Author: Timur Isaev
import AlloyDiagnostics
import AlloyRuntimeAPI
import Foundation
import Testing
@testable import AlloyDiagnosticsIntegration

struct LifecycleTests {
    func capture() throws -> FailureCapture {
        var adapter = OperationAdapter()
        let update = try AdapterTests().update(state: "SUCCEEDED", stages: ["QUEUED", "RUNNING", "SUCCEEDED"])
        let value = try adapter.observe(update, requested: OperationCursor(operationID: "op-observed"),
                                        requestID: "read", instanceID: "service-instance")
        return try FailureCapture(outcome: "clean", complete: true, observations: [#require(value)],
                                  artifacts: [], elapsedSeconds: 0.1)
    }

    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func createInspectExportDeletePreservesUnrelatedFiles() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store")
        try BundleLifecycle.initialize(storeURL)
        let store = try BundleLifecycle(root: storeURL)
        let summary = try store.create(capture())
        let export = root.appendingPathComponent("export")
        try store.export(summary.bundleID, to: export)
        #expect(try SealedBundleReader.read(export).manifest == store.inspect(summary.bundleID).manifest)
        let unrelated = root.appendingPathComponent("unrelated")
        try PrivateStore.writeNew(Data("keep".utf8), to: unrelated)
        #expect(throws: IntegrationError.unsafeDestination) { try store.export(summary.bundleID, to: unrelated) }
        #expect(throws: IntegrationError.unsafeDestination) { try store.delete("../unrelated") }
        try store.delete(summary.bundleID)
        #expect(try PrivateStore.read(unrelated) == Data("keep".utf8))
        #expect(try SealedBundleReader.read(export).manifest.bundleID == summary.bundleID)
        #expect(!FileManager.default.fileExists(atPath: storeURL.appendingPathComponent(summary.bundleID).path))
    }

    @Test func symlinksPermissionsAndTimeBudgetFailClosed() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store")
        try BundleLifecycle.initialize(storeURL)
        let store = try BundleLifecycle(root: storeURL)
        let summary = try store.create(capture())
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: storeURL)
        #expect(throws: IntegrationError.unsafeDestination) { try BundleLifecycle(root: link) }
        #expect(throws: IntegrationError.unsafeDestination) { try store.export(summary.bundleID, to: link) }
        let tiny = try BundleLifecycle(root: storeURL, seconds: 0.000_001)
        #expect(throws: IntegrationError.budgetExceeded) { try tiny.create(capture()) }
        let file = storeURL.appendingPathComponent(summary.bundleID).appendingPathComponent("events.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: IntegrationError.invalidBundle) { try store.inspect(summary.bundleID) }
    }

    @Test func missingEventAndOversizedCaptureAreRejected() throws {
        let prepared = try CaptureBundle.prepare(capture())
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let exported = root.appendingPathComponent("bundle")
        try prepared.export(to: exported)
        let bundle = try SealedBundleReader.read(exported)
        #expect(throws: IntegrationError.invalidBundle) {
            try CaptureBundle.validate(Array(bundle.events.dropLast()), bundleID: bundle.manifest.bundleID)
        }
        let value = try capture()
        let oversized = FailureCapture(outcome: value.outcome, complete: value.complete,
            observations: Array(repeating: value.observations[0], count: 33), artifacts: [], elapsedSeconds: 0.1)
        #expect(throws: IntegrationError.invalidInput) { try CaptureBundle.prepare(oversized) }
    }
}
