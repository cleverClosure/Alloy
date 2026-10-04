// Author: Timur Isaev
// swiftlint:disable file_length

import Darwin
import Foundation
@_spi(FaultTesting) import AlloyStoreIdentity

private enum ProbeError: Error, LocalizedError {
  case usage
  case invalidFaultPoint(String)
  case missingFaultMarker
  case assertion(String)

  var errorDescription: String? {
    switch self {
    case .usage:
      """
      usage:
        AlloyStoreIdentityFaultProbe scan MANIFEST INSTALL_ROOT OUTPUT
        AlloyStoreIdentityFaultProbe watch-unchanged MANIFEST INSTALL_ROOT ANCHOR SCRATCH_ROOT
        AlloyStoreIdentityFaultProbe emit ANCHOR REGISTRY OUTPUT_ROOT SCRATCH_ROOT
      """
    case .invalidFaultPoint(let value):
      "unknown fault point: \(value)"
    case .missingFaultMarker:
      "ALLOY_STORE_IDENTITY_FAULT_MARKER is required with a fault point"
    case .assertion(let message):
      "probe assertion failed: \(message)"
    }
  }
}

private struct FaultConfiguration {
  let selectedPoint: FaultPoint?
  let markerURL: URL?

  init(environment: [String: String] = ProcessInfo.processInfo.environment)
    throws {
    guard let rawPoint = environment["ALLOY_STORE_IDENTITY_FAULT_POINT"] else {
      selectedPoint = nil
      markerURL = nil
      return
    }
    guard let point = FaultPoint(rawValue: rawPoint) else {
      throw ProbeError.invalidFaultPoint(rawPoint)
    }
    guard let markerPath = environment["ALLOY_STORE_IDENTITY_FAULT_MARKER"],
      !markerPath.isEmpty
    else {
      throw ProbeError.missingFaultMarker
    }
    selectedPoint = point
    markerURL = URL(fileURLWithPath: markerPath, isDirectory: false)
  }

  func injector() -> FaultInjector {
    guard let selectedPoint, let markerURL else {
      return { _, _ in }
    }
    return { point, context in
      guard point.rawValue == selectedPoint.rawValue else {
        return
      }
      let marker = "\(point.rawValue)\t\(context ?? "")\n"
      do {
        try Data(marker.utf8).write(to: markerURL, options: .atomic)
      } catch {
        Darwin._exit(98)
      }
      Darwin._exit(97)
    }
  }
}

@main
private enum AlloyStoreIdentityFaultProbe {
  static func main() {
    do {
      try execute(arguments: CommandLine.arguments)
    } catch {
      let message = "ERROR \(error.localizedDescription)\n"
      try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
      Darwin.exit(1)
    }
  }

  private static func execute(arguments: [String]) throws {
    guard arguments.count >= 2 else {
      throw ProbeError.usage
    }
    if try runDiskPressureProbe(arguments) { return }
    let fault = try FaultConfiguration()
    switch arguments[1] {
    case "scan":
      guard arguments.count == 5 else {
        throw ProbeError.usage
      }
      try scan(
        manifestURL: fileURL(arguments[2]),
        installRoot: directoryURL(arguments[3]),
        outputURL: fileURL(arguments[4]),
        faultInjector: fault.injector()
      )
    case "watch-unchanged":
      guard arguments.count == 6 else {
        throw ProbeError.usage
      }
      try watchUnchanged(
        manifestURL: fileURL(arguments[2]),
        installRoot: directoryURL(arguments[3]),
        anchorURL: fileURL(arguments[4]),
        scratchRoot: directoryURL(arguments[5]),
        faultInjector: fault.injector()
      )
    case "emit":
      guard arguments.count == 6 else {
        throw ProbeError.usage
      }
      try emit(
        anchorURL: fileURL(arguments[2]),
        registryURL: fileURL(arguments[3]),
        outputRoot: directoryURL(arguments[4]),
        scratchRoot: directoryURL(arguments[5]),
        faultInjector: fault.injector()
      )
    default:
      throw ProbeError.usage
    }
  }
}

extension AlloyStoreIdentityFaultProbe {
  private static func scan(
    manifestURL: URL,
    installRoot: URL,
    outputURL: URL,
    faultInjector: @escaping FaultInjector
  ) throws {
    let manifest = try loadManifest(at: manifestURL)
    let record = try FingerprintScanner.scan(
      installRoot: installRoot,
      identity: manifest.fingerprintIdentity(),
      faultInjector: faultInjector
    )
    let canonical = try record.canonicalJSON()
    try canonical.write(to: outputURL, options: .atomic)
    let persisted = try Data(contentsOf: outputURL)
    let decoded = try JSONDecoder().decode(
      FingerprintRecord.self,
      from: persisted
    )
    try require(decoded == record, "persisted fingerprint changed")
    try require(persisted == canonical, "fingerprint is not canonical")
    print("SCAN aggregate=\(record.aggregateSHA256) files=\(record.fileCount)")
  }

  private static func watchUnchanged(
    manifestURL: URL,
    installRoot: URL,
    anchorURL: URL,
    scratchRoot: URL,
    faultInjector: @escaping FaultInjector
  ) throws {
    let manifest = try loadManifest(at: manifestURL)
    let anchor = try loadFingerprint(at: anchorURL)
    let result = try UpdateWatcherRun.execute(
      anchor: anchor,
      scratchRoot: scratchRoot
    ) {
      let observed = try FingerprintScanner.scan(
        installRoot: installRoot,
        identity: manifest.fingerprintIdentity(),
        faultInjector: faultInjector
      )
      return UpdateObservation(metadata: manifest, fingerprint: observed)
    }
    try validate(proof: result.proof)
    try require(result.detection == nil, "unchanged run reported a change")
    try requireEmpty(scratchRoot, label: "watcher scratch root")
    print("WATCH self_test=passed detection=unchanged")
  }

  private static func emit(
    anchorURL: URL,
    registryURL: URL,
    outputRoot: URL,
    scratchRoot: URL,
    faultInjector: @escaping FaultInjector
  ) throws {
    let anchor = try loadFingerprint(at: anchorURL)
    let registry = try loadRegistry(at: registryURL)
    let observation = try changedObservation(from: anchor)
    let watcher = try UpdateWatcherRun.execute(
      anchor: anchor,
      scratchRoot: scratchRoot
    ) {
      observation
    }
    try validate(proof: watcher.proof)
    let detection = try requireValue(
      watcher.detection,
      "changed observation returned no detection"
    )
    try validate(detection: detection)
    try requireEmpty(scratchRoot, label: "emitter scratch root")

    let store = InvalidationStore(
      root: outputRoot,
      faultInjector: faultInjector
    )
    let emission = try requireValue(
      try store.emit(
        anchor: anchor,
        observation: observation,
        registry: registry
      ),
      "changed observation emitted no invalidation"
    )
    try validate(
      emission: emission,
      anchor: anchor,
      registry: registry,
      detection: detection
    )
    print(
      "EMIT created=\(emission.created) "
        + "id=\(emission.record.invalidationID) "
        + "file=\(emission.url.lastPathComponent) "
        + "proof=passed"
    )
  }
}

extension AlloyStoreIdentityFaultProbe {
  private static let changedExecutable =
    "The Life and Suffering of Sir Brante.exe"
  private static let removedFile =
    "MonoBleedingEdge/EmbedRuntime/MonoPosixHelper.dll"
  private static let addedFile = "zz-alloy-selector-added.bin"
  private static let changedDepot = "1272161"
  private static let observedBuild = "24280931"
  private static let observedManifest = "3716404947812214695"
  private static let expectedSelectorIDs = [
    "gfx-001.result-06.1272160.24280929",
    "store-001.fingerprint.1272160.24280929",
    "store-001.launch-policy.sir-brante-24280929"
  ]

  private static func changedObservation(
    from anchor: FingerprintRecord
  ) throws -> UpdateObservation {
    var removed = false
    var changed = false
    var files = try anchor.files.compactMap { file -> FingerprintFileRecord? in
      if file.path == removedFile {
        removed = true
        return nil
      }
      if file.path == changedExecutable {
        changed = true
        return try FingerprintFileRecord(
          path: file.path,
          size: file.size,
          sha256: String(repeating: "b", count: 64)
        )
      }
      return file
    }
    try require(removed, "anchor lacks expected removed file")
    try require(changed, "anchor lacks expected changed executable")
    files.append(
      try FingerprintFileRecord(
        path: addedFile,
        size: 17,
        sha256: String(repeating: "c", count: 64)
      )
    )
    files.sort {
      $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
    }

    var depots = anchor.depots
    let depot = try requireValue(
      depots[changedDepot],
      "anchor lacks expected depot"
    )
    depots[changedDepot] = try FingerprintDepotRecord(
      manifest: observedManifest,
      size: depot.size
    )
    let identity = try FingerprintIdentity(
      appID: anchor.appID,
      name: anchor.name,
      buildID: observedBuild,
      depots: depots
    )
    let fingerprint = try FingerprintRecord(identity: identity, files: files)
    let metadata = try SteamMetadataParser.parse(
      data: manifestData(for: fingerprint),
      sourceName: "fault-probe-observation.acf"
    )
    return UpdateObservation(metadata: metadata, fingerprint: fingerprint)
  }

  private static func manifestData(
    for fingerprint: FingerprintRecord
  ) -> Data {
    let depotLines = fingerprint.depots.keys.sorted().flatMap { depotID -> [String] in
      guard let depot = fingerprint.depots[depotID] else {
        return []
      }
      return [
        "        \"\(depotID)\"",
        "        {",
        "            \"manifest\" \"\(depot.manifest)\"",
        "            \"size\"     \"\(depot.size)\"",
        "        }"
      ]
    }
    let lines = [
      "\"AppState\"",
      "{",
      "    \"appid\"       \"\(fingerprint.appID)\"",
      "    \"name\"        \"\(fingerprint.name)\"",
      "    \"installdir\"  \"\(fingerprint.name)\"",
      "    \"SizeOnDisk\"  \"\(fingerprint.totalBytes)\"",
      "    \"buildid\"     \"\(fingerprint.buildID)\"",
      "    \"InstalledDepots\"",
      "    {"
    ] + depotLines + ["    }", "}"]
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }
}

extension AlloyStoreIdentityFaultProbe {
  private static func validate(proof: WatcherSelfTestProof) throws {
    try require(
      proof.changedFilePath == "probe.bin",
      "self-test changed an unexpected path"
    )
    try require(proof.byteCount == 1, "self-test changed an unexpected byte count")
    try require(
      isLowercaseSHA256(proof.baselineAggregateSHA256),
      "self-test baseline aggregate is invalid"
    )
    try require(
      isLowercaseSHA256(proof.perturbedAggregateSHA256),
      "self-test perturbed aggregate is invalid"
    )
    try require(
      proof.baselineAggregateSHA256
        == "9acbfa5e7d216511b6b4254add59f5820ec28eb32e2ca43589517a65dcabf7f7",
      "self-test baseline aggregate changed"
    )
    try require(
      proof.perturbedAggregateSHA256
        == "e6d61fb0293e02a17d6fd6cf8bc75709ae00aabb8f88a2373257d0701009e306",
      "self-test perturbed aggregate changed"
    )
  }

  private static func validate(detection: UpdateDetection) throws {
    try require(
      detection.supersededBuildID == "24280929",
      "unexpected superseded build"
    )
    try require(
      detection.observedBuildID == observedBuild,
      "unexpected observed build"
    )
    try require(detection.metadataChanged, "metadata change was not detected")
    try require(
      detection.gameContentChanged,
      "content change was not detected"
    )
    try require(
      detection.changedDepotIDs == [changedDepot],
      "unexpected depot delta"
    )
    try require(
      detection.addedFilePaths == [addedFile],
      "unexpected added-file delta"
    )
    try require(
      detection.removedFilePaths == [removedFile],
      "unexpected removed-file delta"
    )
    try require(
      detection.changedFilePaths == [changedExecutable],
      "unexpected changed-file delta"
    )
  }

  private static func validate(
    emission: InvalidationEmission,
    anchor: FingerprintRecord,
    registry: SelectorRegistry,
    detection: UpdateDetection
  ) throws {
    let record = emission.record
    try require(
      record.superseded.buildID == anchor.buildID,
      "invalidation superseded build changed"
    )
    try require(
      record.selectorIDs == expectedSelectorIDs,
      "invalidation selector IDs changed"
    )
    try require(
      record.selectorIDs
        == registry.matchingSelectors(for: anchor).map(\.selectorID),
      "invalidation selectors do not match the registry"
    )
    try require(
      record.changedDepotIDs == detection.changedDepotIDs
        && record.addedFilePaths == detection.addedFilePaths
        && record.removedFilePaths == detection.removedFilePaths
        && record.changedFilePaths == detection.changedFilePaths,
      "invalidation delta differs from watcher detection"
    )
    try require(
      emission.url.lastPathComponent == "\(record.digestHex).json",
      "invalidation filename differs from its ID"
    )
    let persisted = try Data(contentsOf: emission.url)
    let decoded = try InvalidationRecord.decode(persisted)
    let canonical = try record.canonicalJSON()
    try require(decoded == record, "persisted invalidation changed")
    try require(
      persisted == canonical,
      "persisted invalidation is not canonical"
    )
    try require(
      hasExactlyOneTrailingLineFeed(persisted),
      "persisted invalidation trailing newline changed"
    )
  }

  private static func loadManifest(at url: URL) throws -> SteamAppManifest {
    try SteamMetadataParser.parse(
      data: Data(contentsOf: url),
      sourceName: url.lastPathComponent
    )
  }

  private static func loadFingerprint(
    at url: URL
  ) throws -> FingerprintRecord {
    try JSONDecoder().decode(
      FingerprintRecord.self,
      from: Data(contentsOf: url)
    )
  }

  private static func loadRegistry(at url: URL) throws -> SelectorRegistry {
    let data = try Data(contentsOf: url)
    let registry = try SelectorRegistry.decode(data)
    let canonical = try registry.canonicalJSON()
    try require(
      canonical == data,
      "selector registry is not canonical"
    )
    return registry
  }

  private static func requireEmpty(_ url: URL, label: String) throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: nil
    )
    try require(entries.isEmpty, "\(label) contains residual files")
  }

  private static func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) throws {
    guard condition() else {
      throw ProbeError.assertion(message)
    }
  }

  private static func requireValue<Value>(
    _ value: Value?,
    _ message: String
  ) throws -> Value {
    guard let value else {
      throw ProbeError.assertion(message)
    }
    return value
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private static func hasExactlyOneTrailingLineFeed(_ data: Data) -> Bool {
    guard data.last == 0x0A else {
      return false
    }
    return data.count == 1 || data[data.count - 2] != 0x0A
  }

  private static func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
  }

  private static func directoryURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  }
}
