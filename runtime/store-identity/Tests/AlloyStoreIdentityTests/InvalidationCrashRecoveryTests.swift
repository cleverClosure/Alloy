// Author: Timur Isaev

import Darwin
import Dispatch
import Foundation
import Testing
@_spi(FaultTesting) import AlloyStoreIdentity

@Suite("Invalidation crash recovery")
struct InvalidationCrashRecoveryTests {
    @Test("exact stale temporary before final converges and is removed")
    func staleExactTemporaryConverges() throws {
        let fixture = try makeRecoveryFixture()
        try withRecoveryRoot("stale-before-final") { root in
            let store = InvalidationStore(root: root)
            try requireRecoveryUnchanged(store, fixture: fixture, root: root)
            let paths = try prepareRecoveryPaths(root, record: fixture.record)
            let canonical = try fixture.record.canonicalJSON()
            try canonical.write(to: paths.temporary)
            try canonical.write(to: paths.nearMissTemporary)
            let emission = try #require(try store.emit(
                anchor: fixture.anchor,
                observation: fixture.changed,
                registry: fixture.registry
            ))
            #expect(emission.created)
            #expect(!FileManager.default.fileExists(
                atPath: paths.temporary.path
            ))
            #expect(try Data(contentsOf: paths.nearMissTemporary) == canonical)
            try FileManager.default.removeItem(at: paths.nearMissTemporary)
            try requireConvergedRecovery(
                root,
                fixture: fixture,
                emission: emission
            )
        }
    }

    @Test("hard-linked temporary and final converge to the existing record")
    func hardLinkedTemporaryConverges() throws {
        let fixture = try makeRecoveryFixture()
        try withRecoveryRoot("linked-final") { root in
            let store = InvalidationStore(root: root)
            try requireRecoveryUnchanged(store, fixture: fixture, root: root)
            let paths = try prepareRecoveryPaths(root, record: fixture.record)
            try fixture.record.canonicalJSON().write(to: paths.temporary)
            try FileManager.default.linkItem(
                at: paths.temporary,
                to: paths.final
            )
            let emission = try #require(try store.emit(
                anchor: fixture.anchor,
                observation: fixture.changed,
                registry: fixture.registry
            ))
            #expect(!emission.created)
            try requireConvergedRecovery(
                root,
                fixture: fixture,
                emission: emission
            )
            #expect(!FileManager.default.fileExists(
                atPath: paths.temporary.path
            ))
        }
    }

    @Test(
        "symlink and non-regular final targets are refused without replacement",
        arguments: UnsafeRecoveryTarget.allCases
    )
    func unsafeFinalTargetIsRefused(kind: UnsafeRecoveryTarget) throws {
        let fixture = try makeRecoveryFixture()
        try withRecoveryRoot("unsafe-\(kind.rawValue)") { root in
            let store = InvalidationStore(root: root)
            try requireRecoveryUnchanged(store, fixture: fixture, root: root)
            let paths = try prepareRecoveryPaths(root, record: fixture.record)
            try kind.stage(
                at: paths.final,
                root: root,
                bytes: fixture.record.canonicalJSON()
            )
            let error = captureRecoveryError {
                _ = try store.emit(
                    anchor: fixture.anchor,
                    observation: fixture.changed,
                    registry: fixture.registry
                )
            }
            #expect(error != nil)
            #expect(try kind.isStillPresent(at: paths.final))
            #expect(try recoveryTemporaryURLs(paths.directory).isEmpty)
        }
    }

    @Test("publication fault points occur once in persistence order")
    func publicationFaultPointOrder() throws {
        let fixture = try makeRecoveryFixture()
        try withRecoveryRoot("fault-order") { root in
            let recorder = RecoveryFaultRecorder()
            let store = InvalidationStore(
                root: root,
                faultInjector: { point, context in
                    recorder.append(point: point, context: context)
                }
            )
            try requireRecoveryUnchanged(store, fixture: fixture, root: root)
            #expect(recorder.snapshot().isEmpty)
            let emission = try #require(try store.emit(
                anchor: fixture.anchor,
                observation: fixture.changed,
                registry: fixture.registry
            ))
            #expect(emission.created)
            #expect(recorder.snapshot().map(\.point) == [
                "afterTemporaryFileSync",
                "afterFinalLink",
                "afterDirectorySync"
            ])
            #expect(recorder.snapshot().allSatisfy { $0.context != nil })
            try requireConvergedRecovery(
                root,
                fixture: fixture,
                emission: emission
            )
        }
    }

    @Test("concurrent identical emitters converge without timing assumptions")
    func concurrentEmittersConverge() throws {
        let fixture = try makeRecoveryFixture()
        try withRecoveryRoot("concurrent") { root in
            let store = InvalidationStore(root: root)
            try requireRecoveryUnchanged(store, fixture: fixture, root: root)
            let results = ConcurrentRecoveryResults()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                do {
                    let emission = try store.emit(
                        anchor: fixture.anchor,
                        observation: fixture.changed,
                        registry: fixture.registry
                    )
                    results.append(emission)
                } catch {
                    results.append(error)
                }
            }
            let snapshot = results.snapshot()
            #expect(snapshot.errors.isEmpty)
            #expect(snapshot.emissions.count == 8)
            #expect(snapshot.emissions.filter(\.created).count == 1)
            #expect(Set(snapshot.emissions.map(\.record.invalidationID))
                == [fixture.record.invalidationID])
            #expect(Set(snapshot.emissions.map(\.url.standardizedFileURL)).count == 1)
            let representative = try #require(snapshot.emissions.first)
            try requireConvergedRecovery(
                root,
                fixture: fixture,
                emission: representative
            )
        }
    }
}

enum UnsafeRecoveryTarget: String, CaseIterable, Sendable {
    case symlink
    case directory
    case fifo

    func stage(at final: URL, root: URL, bytes: Data) throws {
        switch self {
        case .symlink:
            let backing = root.appendingPathComponent("matching-record.json")
            try bytes.write(to: backing)
            try FileManager.default.createSymbolicLink(
                at: final,
                withDestinationURL: backing
            )
        case .directory:
            try FileManager.default.createDirectory(
                at: final,
                withIntermediateDirectories: false
            )
        case .fifo:
            let result = final.path.withCString {
                Darwin.mkfifo($0, S_IRUSR | S_IWUSR)
            }
            guard result == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
        }
    }

    func isStillPresent(at final: URL) throws -> Bool {
        switch self {
        case .symlink:
            _ = try FileManager.default.destinationOfSymbolicLink(
                atPath: final.path
            )
            return true
        case .directory:
            return try final.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory == true
        case .fifo:
            var metadata = stat()
            guard final.path.withCString({
                Darwin.lstat($0, &metadata)
            }) == 0 else {
                return false
            }
            return (UInt32(metadata.st_mode) & UInt32(S_IFMT))
                == UInt32(S_IFIFO)
        }
    }
}

private struct RecoveryFixture: Sendable {
    let anchor: FingerprintRecord
    let unchanged: UpdateObservation
    let changed: UpdateObservation
    let registry: SelectorRegistry
    let record: InvalidationRecord
}

private struct RecoveryPaths {
    let directory: URL
    let temporary: URL
    let nearMissTemporary: URL
    let final: URL
}

private struct RecoveryFaultEvent {
    let point: String
    let context: String?
}

private final class RecoveryFaultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [RecoveryFaultEvent]()

    func append(point: FaultPoint, context: String?) {
        lock.lock()
        events.append(RecoveryFaultEvent(
            point: point.rawValue,
            context: context
        ))
        lock.unlock()
    }

    func snapshot() -> [RecoveryFaultEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private struct ConcurrentRecoverySnapshot {
    let emissions: [InvalidationEmission]
    let errors: [String]
}

private final class ConcurrentRecoveryResults: @unchecked Sendable {
    private let lock = NSLock()
    private var emissions = [InvalidationEmission]()
    private var errors = [String]()

    func append(_ emission: InvalidationEmission?) {
        lock.lock()
        if let emission {
            emissions.append(emission)
        } else {
            errors.append("unexpected nil emission")
        }
        lock.unlock()
    }

    func append(_ error: any Error) {
        lock.lock()
        errors.append(String(describing: error))
        lock.unlock()
    }

    func snapshot() -> ConcurrentRecoverySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ConcurrentRecoverySnapshot(
            emissions: emissions,
            errors: errors
        )
    }
}

private let recoveryRepositoryRoot = URL(
    fileURLWithPath: #filePath,
    isDirectory: false
)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func makeRecoveryFixture() throws -> RecoveryFixture {
    let anchor = try JSONDecoder().decode(
        FingerprintRecord.self,
        from: Data(contentsOf: recoveryRepositoryRoot.appendingPathComponent(
            "spikes/STORE-001/results/fingerprint-1272160-first.json"
        ))
    )
    let registry = try SelectorRegistry.decode(
        Data(contentsOf: recoveryRepositoryRoot.appendingPathComponent(
            "runtime/store-identity/Registry/selectors.v1.json"
        ))
    )
    let unchanged = try recoveryObservation(for: anchor)
    let changedFingerprint = try recoveryChangedFingerprint(anchor)
    let changed = try recoveryObservation(for: changedFingerprint)
    let detection = try #require(try UpdateWatcher.detect(
        anchor: anchor,
        observation: changed
    ))
    let record = try InvalidationRecord.make(
        gameID: anchor.appID,
        storefront: "steam",
        superseded: recoveryIdentity(anchor),
        observed: recoveryIdentity(changedFingerprint),
        metadataChanged: detection.metadataChanged,
        gameContentChanged: detection.gameContentChanged,
        changedDepotIDs: detection.changedDepotIDs,
        addedFilePaths: detection.addedFilePaths,
        removedFilePaths: detection.removedFilePaths,
        changedFilePaths: detection.changedFilePaths,
        selectorIDs: registry.matchingSelectors(for: anchor).map(\.selectorID)
    )
    return RecoveryFixture(
        anchor: anchor,
        unchanged: unchanged,
        changed: changed,
        registry: registry,
        record: record
    )
}

private func recoveryChangedFingerprint(
    _ anchor: FingerprintRecord
) throws -> FingerprintRecord {
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
    return try FingerprintRecord(identity: identity, files: anchor.files)
}

private func recoveryObservation(
    for fingerprint: FingerprintRecord
) throws -> UpdateObservation {
    let metadata = try SteamMetadataParser.parse(
        data: recoveryManifestData(fingerprint),
        sourceName: "recovery-appmanifest.acf"
    )
    return UpdateObservation(metadata: metadata, fingerprint: fingerprint)
}

private func recoveryManifestData(_ fingerprint: FingerprintRecord) -> Data {
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
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

private func recoveryIdentity(
    _ fingerprint: FingerprintRecord
) throws -> InvalidationBuildIdentity {
    try InvalidationBuildIdentity(
        buildID: fingerprint.buildID,
        manifestIDs: fingerprint.depots.mapValues(\.manifest),
        aggregateSHA256: fingerprint.aggregateSHA256
    )
}

private func requireRecoveryUnchanged(
    _ store: InvalidationStore,
    fixture: RecoveryFixture,
    root: URL
) throws {
    let emission = try store.emit(
        anchor: fixture.anchor,
        observation: fixture.unchanged,
        registry: fixture.registry
    )
    #expect(emission == nil)
    #expect(try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    ).isEmpty)
}

private func prepareRecoveryPaths(
    _ root: URL,
    record: InvalidationRecord
) throws -> RecoveryPaths {
    let directory = root.appendingPathComponent(
        "invalidations",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return RecoveryPaths(
        directory: directory,
        temporary: directory.appendingPathComponent(
            ".\(record.digestHex).tmp-00000000-0000-4000-8000-000000000001"
        ),
        nearMissTemporary: directory.appendingPathComponent(
            ".\(record.digestHex).tmp-stale"
        ),
        final: directory.appendingPathComponent("\(record.digestHex).json")
    )
}

private func requireConvergedRecovery(
    _ root: URL,
    fixture: RecoveryFixture,
    emission: InvalidationEmission
) throws {
    #expect(emission.record == fixture.record)
    #expect(try Data(contentsOf: emission.url) == fixture.record.canonicalJSON())
    let directory = root.appendingPathComponent("invalidations")
    let json = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]
    ).filter { $0.pathExtension == "json" }
    #expect(json.map(\.standardizedFileURL) == [emission.url.standardizedFileURL])
    #expect(try recoveryTemporaryURLs(directory).isEmpty)
}

private func recoveryTemporaryURLs(_ directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains(".tmp-") }
}

private func withRecoveryRoot(
    _ label: String,
    operation: (URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "alloy-recovery-\(label)-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try operation(root)
}

private func captureRecoveryError(
    _ operation: () throws -> Void
) -> (any Error)? {
    do {
        try operation()
        return nil
    } catch {
        return error
    }
}
