// Author: Timur Isaev

import Foundation
import Testing
@testable import AlloyStoreIdentity

@Suite("Update watcher instrument self-test")
struct UpdateWatcherSelfTestTests {
    @Test("exact self-test precedes an unchanged real observation")
    func unchangedRunIsSelfTestedFirst() throws {
        let fixture = try makeWatcherRunFixture()
        try withWatcherScratchRoot("unchanged") { scratchRoot in
            let recorder = WatcherRunRecorder()
            let result = try UpdateWatcherRun.execute(
                anchor: fixture.anchor,
                scratchRoot: scratchRoot,
                detector: recordingDetector(recorder),
                realObservation: {
                    recorder.appendObservation()
                    return fixture.unchanged
                }
            )

            let snapshot = recorder.snapshot()
            #expect(snapshot.events == [
                "detector", "detector", "observer", "detector"
            ])
            try requireExactSelfTest(
                proof: result.proof,
                calls: snapshot.calls
            )
            let realCall = try #require(snapshot.calls.last)
            #expect(snapshot.calls.count == 3)
            #expect(realCall.detection == nil)
            #expect(result.detection == nil)
            #expect(try watcherScratchIsEmpty(scratchRoot))
        }
    }

    @Test("exact self-test precedes a changed real observation")
    func changedRunIsSelfTestedFirst() throws {
        let fixture = try makeWatcherRunFixture()
        try withWatcherScratchRoot("changed") { scratchRoot in
            let recorder = WatcherRunRecorder()
            let result = try UpdateWatcherRun.execute(
                anchor: fixture.anchor,
                scratchRoot: scratchRoot,
                detector: recordingDetector(recorder),
                realObservation: {
                    recorder.appendObservation()
                    return fixture.changed
                }
            )

            let snapshot = recorder.snapshot()
            #expect(snapshot.events == [
                "detector", "detector", "observer", "detector"
            ])
            try requireExactSelfTest(
                proof: result.proof,
                calls: snapshot.calls
            )
            let detection = try #require(result.detection)
            let realCall = try #require(snapshot.calls.last)
            #expect(snapshot.calls.count == 3)
            #expect(detection == realCall.detection)
            #expect(detection.metadataChanged)
            #expect(!detection.gameContentChanged)
            #expect(detection.changedDepotIDs == ["1272161"])
            #expect(detection.addedFilePaths.isEmpty)
            #expect(detection.removedFilePaths.isEmpty)
            #expect(detection.changedFilePaths.isEmpty)
            #expect(try watcherScratchIsEmpty(scratchRoot))
        }
    }

    @Test("dead detector refuses before the real observer")
    func deadDetectorNeverObserves() throws {
        let fixture = try makeWatcherRunFixture()
        try withWatcherScratchRoot("dead-detector") { scratchRoot in
            let recorder = WatcherRunRecorder()
            let error = captureWatcherRunError {
                _ = try UpdateWatcherRun.execute(
                    anchor: fixture.anchor,
                    scratchRoot: scratchRoot,
                    detector: { anchor, observation in
                        recorder.appendDetector(
                            anchor: anchor,
                            observation: observation,
                            detection: nil
                        )
                        return nil
                    },
                    realObservation: {
                        recorder.appendObservation()
                        return fixture.changed
                    }
                )
            }

            let snapshot = recorder.snapshot()
            #expect(error as? UpdateWatcherRunError == .selfTestFailed)
            #expect(snapshot.events == ["detector", "detector"])
            #expect(snapshot.calls.count == 2)
            try requireSelfTestInputs(snapshot.calls)
            #expect(snapshot.calls.allSatisfy { $0.detection == nil })
            #expect(try watcherScratchIsEmpty(scratchRoot))
        }
    }

    @Test("observer failure propagates after self-test and cleans scratch")
    func observerFailureCleansScratch() throws {
        let fixture = try makeWatcherRunFixture()
        try withWatcherScratchRoot("observer-failure") { scratchRoot in
            let recorder = WatcherRunRecorder()
            let error = captureWatcherRunError {
                _ = try UpdateWatcherRun.execute(
                    anchor: fixture.anchor,
                    scratchRoot: scratchRoot,
                    detector: recordingDetector(recorder),
                    realObservation: {
                        recorder.appendObservation()
                        throw WatcherRunFixtureError.observerFailed
                    }
                )
            }

            let snapshot = recorder.snapshot()
            #expect(error as? WatcherRunFixtureError == .observerFailed)
            #expect(snapshot.events == [
                "detector", "detector", "observer"
            ])
            #expect(snapshot.calls.count == 2)
            try requireSelfTestDetectorCalls(snapshot.calls)
            #expect(try watcherScratchIsEmpty(scratchRoot))
        }
    }
}

private enum WatcherRunFixtureError: Error, Equatable {
    case observerFailed
}

private struct WatcherRunFixture {
    let anchor: FingerprintRecord
    let unchanged: UpdateObservation
    let changed: UpdateObservation
}

private struct WatcherDetectorCall {
    let anchor: FingerprintRecord
    let observation: UpdateObservation
    let detection: UpdateDetection?
}

private struct WatcherRunSnapshot {
    let events: [String]
    let calls: [WatcherDetectorCall]
}

private final class WatcherRunRecorder {
    private var events = [String]()
    private var calls = [WatcherDetectorCall]()

    func appendDetector(
        anchor: FingerprintRecord,
        observation: UpdateObservation,
        detection: UpdateDetection?
    ) {
        events.append("detector")
        calls.append(WatcherDetectorCall(
            anchor: anchor,
            observation: observation,
            detection: detection
        ))
    }

    func appendObservation() {
        events.append("observer")
    }

    func snapshot() -> WatcherRunSnapshot {
        WatcherRunSnapshot(events: events, calls: calls)
    }
}

private let watcherRunRepositoryRoot = URL(
    fileURLWithPath: #filePath,
    isDirectory: false
)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func makeWatcherRunFixture() throws -> WatcherRunFixture {
    let anchor = try JSONDecoder().decode(
        FingerprintRecord.self,
        from: Data(contentsOf: watcherRunRepositoryRoot.appendingPathComponent(
            "spikes/STORE-001/results/fingerprint-1272160-first.json"
        ))
    )
    let unchanged = try watcherRunObservation(for: anchor)
    var depots = anchor.depots
    let depot = try #require(depots["1272161"])
    depots["1272161"] = try FingerprintDepotRecord(
        manifest: "3716404947812214694",
        size: depot.size
    )
    let identity = try FingerprintIdentity(
        appID: anchor.appID,
        name: anchor.name,
        buildID: "24280930",
        depots: depots
    )
    let changed = try watcherRunObservation(
        for: FingerprintRecord(identity: identity, files: anchor.files)
    )
    return WatcherRunFixture(
        anchor: anchor,
        unchanged: unchanged,
        changed: changed
    )
}

private func watcherRunObservation(
    for fingerprint: FingerprintRecord
) throws -> UpdateObservation {
    let depots = fingerprint.depots.keys.sorted().flatMap { depotID -> [String] in
        guard let depot = fingerprint.depots[depotID] else { return [] }
        return [
            "        \"\(depotID)\"",
            "        {",
            "            \"manifest\" \"\(depot.manifest)\"",
            "            \"size\" \"\(depot.size)\"",
            "        }"
        ]
    }
    let lines = [
        "\"AppState\"", "{",
        "    \"appid\" \"\(fingerprint.appID)\"",
        "    \"name\" \"\(fingerprint.name)\"",
        "    \"installdir\" \"\(fingerprint.name)\"",
        "    \"SizeOnDisk\" \"\(fingerprint.totalBytes)\"",
        "    \"buildid\" \"\(fingerprint.buildID)\"",
        "    \"InstalledDepots\"", "    {"
    ] + depots + ["    }", "}"]
    let metadata = try SteamMetadataParser.parse(
        data: Data((lines.joined(separator: "\n") + "\n").utf8),
        sourceName: "watcher-run-fixture.acf"
    )
    return UpdateObservation(metadata: metadata, fingerprint: fingerprint)
}

private func recordingDetector(
    _ recorder: WatcherRunRecorder
) -> (FingerprintRecord, UpdateObservation) throws -> UpdateDetection? {
    { anchor, observation in
        let detection = try UpdateWatcher.detect(
            anchor: anchor,
            observation: observation
        )
        recorder.appendDetector(
            anchor: anchor,
            observation: observation,
            detection: detection
        )
        return detection
    }
}

private func requireExactSelfTest(
    proof: WatcherSelfTestProof,
    calls: [WatcherDetectorCall]
) throws {
    try requireSelfTestDetectorCalls(calls)
    let baseline = calls[0].anchor
    let perturbed = calls[1].observation.fingerprint
    #expect(proof.changedFilePath == "probe.bin")
    #expect(proof.byteCount == 1)
    #expect(proof.baselineAggregateSHA256 == baseline.aggregateSHA256)
    #expect(proof.perturbedAggregateSHA256 == perturbed.aggregateSHA256)
}

private func requireSelfTestDetectorCalls(
    _ calls: [WatcherDetectorCall]
) throws {
    try #require(calls.count >= 2)
    try requireSelfTestInputs(calls)
    #expect(calls[0].detection == nil)
    let detection = try #require(calls[1].detection)
    #expect(!detection.metadataChanged)
    #expect(detection.gameContentChanged)
    #expect(detection.changedDepotIDs.isEmpty)
    #expect(detection.addedFilePaths.isEmpty)
    #expect(detection.removedFilePaths.isEmpty)
    #expect(detection.changedFilePaths == ["probe.bin"])
}

private func requireSelfTestInputs(
    _ calls: [WatcherDetectorCall]
) throws {
    let baselineCall = calls[0]
    let changedCall = calls[1]
    #expect(baselineCall.anchor == baselineCall.observation.fingerprint)
    #expect(changedCall.anchor == baselineCall.anchor)
    #expect(changedCall.anchor.files.count == 1)
    let baselineFile = try #require(changedCall.anchor.files.first)
    let changedFile = try #require(
        changedCall.observation.fingerprint.files.first
    )
    #expect(baselineFile.path == "probe.bin")
    #expect(changedFile.path == "probe.bin")
    #expect(baselineFile.size == 4)
    #expect(changedFile.size == baselineFile.size)
    #expect(changedFile.sha256 != baselineFile.sha256)
    #expect(changedCall.observation.fingerprint.aggregateSHA256
        != changedCall.anchor.aggregateSHA256)
}

private func withWatcherScratchRoot(
    _ label: String,
    operation: (URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-watcher-\(label)-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try operation(root)
}

private func watcherScratchIsEmpty(_ root: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    ).isEmpty
}

private func captureWatcherRunError(
    _ operation: () throws -> Void
) -> (any Error)? {
    do {
        try operation()
        return nil
    } catch {
        return error
    }
}
