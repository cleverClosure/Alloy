// Author: Timur Isaev

import CryptoKit
import Darwin
import Foundation
@_spi(FaultTesting) import AlloyStoreIdentity

private enum PressureProbeError: Error { case usage, timeout, assertion(String) }

func runDiskPressureProbe(_ arguments: [String]) throws -> Bool {
    guard arguments.count >= 2, arguments[1] == "disk-pressure" else { return false }
    guard arguments.count == 6, ["scan", "cache"].contains(arguments[2]) else {
        throw PressureProbeError.usage
    }
    let root = URL(fileURLWithPath: arguments[3])
    let markers = URL(fileURLWithPath: arguments[4])
    let resume = URL(fileURLWithPath: arguments[5])
    do {
        let fixture = try PressureIdentityFixture(root: root)
        if arguments[2] == "scan" {
            try fixture.scan(reached: markers, resume: resume)
        } else {
            try fixture.cache(reached: markers, resume: resume)
        }
    } catch {
        if isOutOfSpace(error) {
            FileHandle.standardError.write(Data("DISK_PRESSURE ENOSPC \(error)\n".utf8))
            exit(28)
        }
        throw error
    }
    return true
}

private func isOutOfSpace(_ error: Error) -> Bool {
    if case InvalidationStoreError.fileSystem(_, _, let code) = error, code == ENOSPC { return true }
    let value = error as NSError
    if value.domain == NSPOSIXErrorDomain, value.code == Int(ENOSPC) { return true }
    if value.domain == NSCocoaErrorDomain, value.code == NSFileWriteOutOfSpaceError { return true }
    if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
    return false
}

private func pressureHandshake(reached: URL, resume: URL) throws {
    try Data("ready\n".utf8).write(to: reached)
    let deadline = Date().addingTimeInterval(30)
    while !FileManager.default.fileExists(atPath: resume.path) {
        guard Date() < deadline else { throw PressureProbeError.timeout }
        usleep(1_000)
    }
}

private struct PressureIdentityFixture {
    let root: URL
    let install: URL
    let identity: FingerprintIdentity
    let anchor: FingerprintRecord
    let payload = Data("synthetic bytes".utf8)

    init(root: URL) throws {
        self.root = root
        install = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let file = install.appendingPathComponent(BuildSelector.anchoredImagePath)
        if !FileManager.default.fileExists(atPath: file.path) { try payload.write(to: file) }
        guard try Data(contentsOf: file) == payload else { throw PressureProbeError.assertion("input changed") }
        identity = try FingerprintIdentity(appID: "980001", name: "Synthetic pressure title", buildID: "1",
            depots: ["980002": FingerprintDepotRecord(manifest: "10", size: String(payload.count))])
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        anchor = try FingerprintRecord(identity: identity,
            files: [FingerprintFileRecord(path: BuildSelector.anchoredImagePath,
                                          size: UInt64(payload.count), sha256: digest)])
    }

    func scan(reached: URL, resume: URL) throws {
        let output = root.appendingPathComponent("fingerprint.json")
        let expected = try anchor.canonicalJSON()
        if !FileManager.default.fileExists(atPath: output.path) { try expected.write(to: output) }
        let scanned = try FingerprintScanner.scan(installRoot: install, identity: identity) { _, _ in
            do { try pressureHandshake(reached: reached, resume: resume) } catch { exit(98) }
        }
        guard scanned == anchor else { throw PressureProbeError.assertion("read-only scan changed") }
        print("PRESSURE_SCAN read_only=PASS files=1")
        try scanned.canonicalJSON().write(to: output, options: .atomic)
        guard try Data(contentsOf: output) == expected else { throw PressureProbeError.assertion("output changed") }
        print("PRESSURE_SCAN persistence=PASS")
    }

    func cache(reached: URL, resume: URL) throws {
        let metadata = try SteamMetadataParser.parse(data: Data("""
        "AppState" { "appid" "980001" "name" "Synthetic pressure title" "installdir" "title"
        "buildid" "2" "SizeOnDisk" "15" "InstalledDepots" { "980002" { "manifest" "11" "size" "15" } } }
        """.utf8), sourceName: "synthetic-pressure.acf")
        let observed = try FingerprintRecord(identity: metadata.fingerprintIdentity(), files: anchor.files)
        let artifact = try EvidenceArtifact(kind: "fingerprint", path: "synthetic/pressure.json",
                                            sha256: String(repeating: "0", count: 64))
        let selector = try BuildSelector(selectorID: "store-106.pressure.980001.1", artifact: artifact,
            storefront: "steam", gameID: anchor.appID, storeBuildID: anchor.buildID,
            manifestIDs: anchor.depots.mapValues(\.manifest), aggregateSHA256: anchor.aggregateSHA256,
            imageHashes: [BuildSelector.anchoredImagePath: anchor.files[0].sha256])
        let registry = try SelectorRegistry(selectors: [selector])
        let cacheRoot = root.appendingPathComponent("cache")
        let directory = cacheRoot.appendingPathComponent("invalidations")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appendingPathComponent(".alloy-invalidation.lock")
        if !FileManager.default.fileExists(atPath: lock.path) { try Data().write(to: lock) }
        try pressureHandshake(reached: reached, resume: resume)
        let store = InvalidationStore(root: cacheRoot)
        guard let result = try store.emit(anchor: anchor,
            observation: UpdateObservation(metadata: metadata, fingerprint: observed), registry: registry) else {
            throw PressureProbeError.assertion("no invalidation")
        }
        guard try InvalidationRecord.decode(Data(contentsOf: result.url)) == result.record else {
            throw PressureProbeError.assertion("invalid cache")
        }
        print("PRESSURE_CACHE persistence=PASS created=\(result.created)")
    }
}
