// Author: Timur Isaev

import Darwin
import Foundation

public enum UpdateWatcherRunError: Error, Equatable, Sendable {
  case selfTestFailed
  case unsafeScratchPath(String)
  case fileSystem(operation: String, path: String, code: Int32)
}

extension UpdateWatcherRunError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .selfTestFailed:
      "update watcher self-test did not produce the exact expected delta"
    case .unsafeScratchPath(let path):
      "watcher self-test scratch path is not a real directory: \(path)"
    case .fileSystem(let operation, let path, let code):
      "\(operation) failed for \(path) with errno \(code)"
    }
  }
}

public struct WatcherSelfTestProof: Equatable, Sendable {
  public let changedFilePath: String
  public let baselineAggregateSHA256: String
  public let perturbedAggregateSHA256: String
  /// Number of file bytes deliberately changed by the self-test.
  public let byteCount: UInt64

  public init(
    changedFilePath: String,
    baselineAggregateSHA256: String,
    perturbedAggregateSHA256: String,
    byteCount: UInt64
  ) {
    self.changedFilePath = changedFilePath
    self.baselineAggregateSHA256 = baselineAggregateSHA256
    self.perturbedAggregateSHA256 = perturbedAggregateSHA256
    self.byteCount = byteCount
  }
}

public struct WatcherRunResult: Equatable, Sendable {
  public let proof: WatcherSelfTestProof
  public let detection: UpdateDetection?

  public init(
    proof: WatcherSelfTestProof,
    detection: UpdateDetection?
  ) {
    self.proof = proof
    self.detection = detection
  }
}

public enum UpdateWatcherRun {
  public static func execute(
    anchor: FingerprintRecord,
    scratchRoot: URL,
    realObservation: () throws -> UpdateObservation
  ) throws -> WatcherRunResult {
    try execute(
      anchor: anchor,
      scratchRoot: scratchRoot,
      detector: UpdateWatcher.detect,
      realObservation: realObservation
    )
  }

  static func execute(
    anchor: FingerprintRecord,
    scratchRoot: URL,
    detector: (
      FingerprintRecord,
      UpdateObservation
    ) throws -> UpdateDetection?,
    realObservation: () throws -> UpdateObservation
  ) throws -> WatcherRunResult {
    let proof = try selfTest(
      scratchRoot: scratchRoot,
      detector: detector
    )
    let observation = try realObservation()
    return try WatcherRunResult(
      proof: proof,
      detection: detector(anchor, observation)
    )
  }
}

extension UpdateWatcherRun {
  fileprivate static let probeFilePath = "probe.bin"
  fileprivate static let probeBytes = Data([0x41, 0x6c, 0x6c, 0x79])

  // swiftlint:disable:next function_body_length
  fileprivate static func selfTest(
    scratchRoot: URL,
    detector: (
      FingerprintRecord,
      UpdateObservation
    ) throws -> UpdateDetection?
  ) throws -> WatcherSelfTestProof {
    let root = try makeScratchChild(in: scratchRoot)
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    let baselineRoot = root.appendingPathComponent(
      "baseline",
      isDirectory: true
    )
    let observedRoot = root.appendingPathComponent(
      "observed",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: baselineRoot,
      withIntermediateDirectories: false
    )
    let baselineFile = baselineRoot.appendingPathComponent(
      probeFilePath,
      isDirectory: false
    )
    try probeBytes.write(to: baselineFile)
    try FileManager.default.copyItem(at: baselineRoot, to: observedRoot)

    let identity = try selfTestIdentity()
    let baseline = try FingerprintScanner.scan(
      installRoot: baselineRoot,
      identity: identity
    )
    let unchanged = try observation(for: baseline)
    guard try detector(baseline, unchanged) == nil else {
      throw UpdateWatcherRunError.selfTestFailed
    }

    let observedFile = observedRoot.appendingPathComponent(
      probeFilePath,
      isDirectory: false
    )
    try perturbFirstByte(at: observedFile)
    let perturbed = try FingerprintScanner.scan(
      installRoot: observedRoot,
      identity: identity
    )
    let changed = try observation(for: perturbed)
    guard let detection = try detector(baseline, changed),
      exactSelfTestDelta(detection),
      baseline.totalBytes == perturbed.totalBytes,
      baseline.aggregateSHA256 != perturbed.aggregateSHA256
    else {
      throw UpdateWatcherRunError.selfTestFailed
    }

    let proof = WatcherSelfTestProof(
      changedFilePath: probeFilePath,
      baselineAggregateSHA256: baseline.aggregateSHA256,
      perturbedAggregateSHA256: perturbed.aggregateSHA256,
      byteCount: 1
    )
    try FileManager.default.removeItem(at: root)
    return proof
  }

  fileprivate static func makeScratchChild(
    in scratchRoot: URL
  ) throws -> URL {
    let parent = scratchRoot.standardizedFileURL
    do {
      try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: true
      )
    } catch {
      throw UpdateWatcherRunError.unsafeScratchPath(parent.path)
    }
    var metadata = stat()
    guard parent.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
      (UInt32(metadata.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    else {
      throw UpdateWatcherRunError.unsafeScratchPath(parent.path)
    }

    let child = parent.appendingPathComponent(
      "alloy-watcher-self-test-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: child,
        withIntermediateDirectories: false
      )
    } catch {
      throw UpdateWatcherRunError.fileSystem(
        operation: "create scratch child",
        path: child.path,
        code: Int32((error as NSError).code)
      )
    }
    return child
  }

  fileprivate static func selfTestIdentity() throws -> FingerprintIdentity {
    try FingerprintIdentity(
      appID: "1",
      name: "Alloy watcher self-test",
      buildID: "1",
      depots: [
        "1": try FingerprintDepotRecord(
          manifest: "1",
          size: String(probeBytes.count)
        )
      ]
    )
  }

  fileprivate static func observation(
    for fingerprint: FingerprintRecord
  ) throws -> UpdateObservation {
    guard let depot = fingerprint.depots["1"] else {
      throw UpdateWatcherRunError.selfTestFailed
    }
    let manifest = """
      "AppState"
      {
        "appid" "\(fingerprint.appID)"
        "name" "\(fingerprint.name)"
        "installdir" "alloy-watcher-self-test"
        "SizeOnDisk" "\(fingerprint.totalBytes)"
        "buildid" "\(fingerprint.buildID)"
        "InstalledDepots"
        {
          "1"
          {
            "manifest" "\(depot.manifest)"
            "size" "\(depot.size)"
          }
        }
      }
      """
    let metadata = try SteamMetadataParser.parse(
      data: Data(manifest.utf8),
      sourceName: "watcher-self-test.acf"
    )
    return UpdateObservation(
      metadata: metadata,
      fingerprint: fingerprint
    )
  }

  fileprivate static func exactSelfTestDelta(
    _ detection: UpdateDetection
  ) -> Bool {
    detection.appID == "1"
      && detection.supersededBuildID == "1"
      && detection.observedBuildID == "1"
      && !detection.metadataChanged
      && detection.gameContentChanged
      && detection.changedDepotIDs.isEmpty
      && detection.addedFilePaths.isEmpty
      && detection.removedFilePaths.isEmpty
      && detection.changedFilePaths == [probeFilePath]
  }

  fileprivate static func perturbFirstByte(at url: URL) throws {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw UpdateWatcherRunError.fileSystem(
        operation: "open perturbation target",
        path: url.path,
        code: errno
      )
    }
    defer {
      Darwin.close(descriptor)
    }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      (UInt32(metadata.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFREG),
      metadata.st_size == probeBytes.count
    else {
      throw UpdateWatcherRunError.unsafeScratchPath(url.path)
    }
    var byte = probeBytes[probeBytes.startIndex] ^ 0x01
    let count = withUnsafePointer(to: &byte) { pointer in
      Darwin.pwrite(descriptor, pointer, 1, 0)
    }
    guard count == 1 else {
      throw UpdateWatcherRunError.fileSystem(
        operation: "write perturbation",
        path: url.path,
        code: count < 0 ? errno : EIO
      )
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw UpdateWatcherRunError.fileSystem(
        operation: "fsync perturbation",
        path: url.path,
        code: errno
      )
    }
  }
}
