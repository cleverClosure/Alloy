// Author: Timur Isaev
// swiftlint:disable file_length

import AlloyStoreIdentity
import Darwin
import Foundation

private enum StoreIdentityCLIError: Error, LocalizedError {
  case usage
  case invalidArgument(String)
  case duplicateArgument(String)
  case missingArgument(String)
  case invalidAppID(String)
  case unsafePath(String)
  case invalidInput(String)
  case fileSystem(operation: String, code: Int32)
  case missingObservation
  case missingInvalidation

  var errorDescription: String? {
    switch self {
    case .usage:
      """
      usage: AlloyStoreIdentityCLI observe \
      --library-root PATH --app-id APP_ID --anchor PATH \
      --registry PATH --state-root PATH
      """
    case .invalidArgument(let value):
      "unknown or trailing argument: \(value)"
    case .duplicateArgument(let value):
      "duplicate argument: \(value)"
    case .missingArgument(let value):
      "missing argument or value: \(value)"
    case .invalidAppID(let value):
      "app id must be a nonempty ASCII decimal string: \(value)"
    case .unsafePath(let value):
      "unsafe path boundary: \(value)"
    case .invalidInput(let value):
      "invalid input: \(value)"
    case .fileSystem(let operation, let code):
      "\(operation) failed with errno \(code)"
    case .missingObservation:
      "watcher returned without its real observation"
    case .missingInvalidation:
      "changed observation produced no invalidation"
    }
  }
}

private struct StoreIdentityCLIConfiguration {
  static let requiredFlags = [
    "--library-root",
    "--app-id",
    "--anchor",
    "--registry",
    "--state-root"
  ]

  let libraryRoot: URL
  let appID: String
  let anchorURL: URL
  let registryURL: URL
  let stateRoot: URL

  init(arguments: [String]) throws {
    guard arguments.count >= 2, arguments[1] == "observe" else {
      throw StoreIdentityCLIError.usage
    }
    let values = try Self.parseFlags(Array(arguments.dropFirst(2)))
    guard values.count == Self.requiredFlags.count else {
      let missing = Self.requiredFlags.first { values[$0] == nil } ?? "argument"
      throw StoreIdentityCLIError.missingArgument(missing)
    }

    let appID = try Self.requireValue("--app-id", from: values)
    guard !appID.isEmpty,
      appID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
    else {
      throw StoreIdentityCLIError.invalidAppID(appID)
    }

    libraryRoot = Self.directoryURL(
      try Self.requireValue("--library-root", from: values)
    )
    self.appID = appID
    anchorURL = Self.fileURL(
      try Self.requireValue("--anchor", from: values)
    )
    registryURL = Self.fileURL(
      try Self.requireValue("--registry", from: values)
    )
    stateRoot = Self.directoryURL(
      try Self.requireValue("--state-root", from: values)
    )
  }

  private static func parseFlags(
    _ arguments: [String]
  ) throws -> [String: String] {
    let allowed = Set(requiredFlags)
    var values = [String: String]()
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let flag = arguments[index]
      guard allowed.contains(flag) else {
        throw StoreIdentityCLIError.invalidArgument(flag)
      }
      guard values[flag] == nil else {
        throw StoreIdentityCLIError.duplicateArgument(flag)
      }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex,
        !allowed.contains(arguments[valueIndex])
      else {
        throw StoreIdentityCLIError.missingArgument(flag)
      }
      values[flag] = arguments[valueIndex]
      index = arguments.index(after: valueIndex)
    }
    return values
  }

  private static func requireValue(
    _ flag: String,
    from values: [String: String]
  ) throws -> String {
    guard let value = values[flag], !value.isEmpty else {
      throw StoreIdentityCLIError.missingArgument(flag)
    }
    return value
  }

  private static func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
  }

  private static func directoryURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  }
}

private struct StoreIdentityCLIInputs {
  let libraryRoot: URL
  let stateRoot: URL
  let anchor: FingerprintRecord
  let registry: SelectorRegistry
}

private struct StableManifest: Equatable {
  let data: Data
  let metadata: ManifestFileMetadata
}

private struct ManifestFileMetadata: Equatable {
  let device: UInt64
  let inode: UInt64
  let mode: UInt32
  let linkCount: UInt64
  let size: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64

  init(_ value: stat) {
    device = UInt64(bitPattern: Int64(value.st_dev))
    inode = UInt64(value.st_ino)
    mode = UInt32(value.st_mode)
    linkCount = UInt64(value.st_nlink)
    size = Int64(value.st_size)
    modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
    modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
    changedSeconds = Int64(value.st_ctimespec.tv_sec)
    changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
  }

  var isRegularFile: Bool {
    (mode & UInt32(S_IFMT)) == UInt32(S_IFREG)
  }
}

@main
private enum AlloyStoreIdentityCLI {
  static func main() {
    do {
      let configuration = try StoreIdentityCLIConfiguration(
        arguments: CommandLine.arguments
      )
      let status = try observe(configuration)
      print(status)
    } catch {
      writeError("ERROR \(error.localizedDescription)\n")
      Darwin.exit(1)
    }
  }

  private static func observe(
    _ configuration: StoreIdentityCLIConfiguration
  ) throws -> String {
    let inputs = try resolveInputs(configuration)
    let observed = try executeWatcher(
      inputs: inputs,
      appID: configuration.appID
    )
    return try statusLine(
      inputs: inputs,
      appID: configuration.appID,
      run: observed.run,
      observation: observed.observation
    )
  }
}

private extension AlloyStoreIdentityCLI {
  static func resolveInputs(
    _ configuration: StoreIdentityCLIConfiguration
  ) throws -> StoreIdentityCLIInputs {
    let libraryRoot = try requireExistingDirectory(
      configuration.libraryRoot,
      label: "library root"
    )
    let stateRoot = resolvedPath(configuration.stateRoot)
    let pathsOverlap =
      isSameOrDescendant(stateRoot, of: libraryRoot)
      || isSameOrDescendant(libraryRoot, of: stateRoot)
    guard !pathsOverlap else {
      throw StoreIdentityCLIError.unsafePath(
        "state root and selected library must be disjoint"
      )
    }

    let anchor = try loadAnchor(
      at: configuration.anchorURL,
      appID: configuration.appID
    )
    let registry = try loadRegistry(at: configuration.registryURL)
    return StoreIdentityCLIInputs(
      libraryRoot: libraryRoot,
      stateRoot: stateRoot,
      anchor: anchor,
      registry: registry
    )
  }

  static func executeWatcher(
    inputs: StoreIdentityCLIInputs,
    appID: String
  ) throws -> (run: WatcherRunResult, observation: UpdateObservation) {
    let scratchRoot = inputs.stateRoot.appendingPathComponent(
      "watcher-scratch",
      isDirectory: true
    )
    var realObservation: UpdateObservation?
    let run = try UpdateWatcherRun.execute(
      anchor: inputs.anchor,
      scratchRoot: scratchRoot
    ) {
      let observation = try observeInstallation(
        libraryRoot: inputs.libraryRoot,
        appID: appID
      )
      realObservation = observation
      return observation
    }
    guard let realObservation else {
      throw StoreIdentityCLIError.missingObservation
    }
    return (run, realObservation)
  }

  static func statusLine(
    inputs: StoreIdentityCLIInputs,
    appID: String,
    run: WatcherRunResult,
    observation: UpdateObservation
  ) throws -> String {
    guard let detection = run.detection else {
      return [
        "STATUS",
        "appid=\(appID)",
        "update=unchanged",
        "self_test=PASS",
        "invalidation=none"
      ].joined(separator: " ")
    }
    guard let emission = try InvalidationStore(root: inputs.stateRoot).emit(
      anchor: inputs.anchor,
      observation: observation,
      registry: inputs.registry
    ) else {
      throw StoreIdentityCLIError.missingInvalidation
    }
    return [
      "STATUS",
      "appid=\(appID)",
      "update=changed",
      "self_test=PASS",
      "created=\(emission.created)",
      "id=\(emission.record.invalidationID)",
      "superseded=\(detection.supersededBuildID)",
      "observed=\(detection.observedBuildID)"
    ].joined(separator: " ")
  }
}

private extension AlloyStoreIdentityCLI {
  // swiftlint:disable:next function_body_length
  static func observeInstallation(
    libraryRoot: URL,
    appID: String
  ) throws -> UpdateObservation {
    let steamappsRoot = try requireRealDirectory(
      libraryRoot.appendingPathComponent("steamapps", isDirectory: true),
      label: "steamapps root"
    )
    let manifestURL = steamappsRoot
      .appendingPathComponent("appmanifest_\(appID).acf", isDirectory: false)
    let initialManifest = try readStableManifest(at: manifestURL)
    let metadata = try SteamMetadataParser.parse(
      data: initialManifest.data,
      sourceName: manifestURL.lastPathComponent
    )
    guard metadata.appID == appID else {
      throw StoreIdentityCLIError.invalidInput(
        "appmanifest appid does not match --app-id"
      )
    }
    guard isSafeInstallDirectory(metadata.installDirectory) else {
      throw StoreIdentityCLIError.unsafePath(
        "appmanifest installdir is not one safe path component"
      )
    }

    let commonRoot = try requireRealDirectory(
      steamappsRoot.appendingPathComponent("common", isDirectory: true),
      label: "steamapps common root"
    )
    let installRoot = try requireRealDirectory(
      commonRoot.appendingPathComponent(
        metadata.installDirectory,
        isDirectory: true
      ),
      label: "installation root"
    )
    guard isSameOrDescendant(installRoot, of: commonRoot) else {
      throw StoreIdentityCLIError.unsafePath(
        "installation escapes steamapps/common"
      )
    }
    let fingerprint = try FingerprintScanner.scan(
      installRoot: installRoot,
      identity: metadata.fingerprintIdentity()
    )
    let finalManifest = try readStableManifest(at: manifestURL)
    guard finalManifest == initialManifest else {
      throw StoreIdentityCLIError.invalidInput(
        "appmanifest changed during observation"
      )
    }
    return UpdateObservation(
      metadata: metadata,
      fingerprint: fingerprint
    )
  }

  static func loadAnchor(
    at url: URL,
    appID: String
  ) throws -> FingerprintRecord {
    let anchor = try JSONDecoder().decode(
      FingerprintRecord.self,
      from: Data(contentsOf: url)
    )
    guard anchor.appID == appID else {
      throw StoreIdentityCLIError.invalidInput(
        "anchor appid does not match --app-id"
      )
    }
    return anchor
  }

  static func loadRegistry(at url: URL) throws -> SelectorRegistry {
    let data = try Data(contentsOf: url)
    let registry = try SelectorRegistry.decode(data)
    guard try registry.canonicalJSON() == data else {
      throw StoreIdentityCLIError.invalidInput(
        "selector registry is not canonical"
      )
    }
    return registry
  }

  static func requireExistingDirectory(
    _ url: URL,
    label: String
  ) throws -> URL {
    let resolved = resolvedPath(url)
    var metadata = stat()
    guard resolved.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
      (UInt32(metadata.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    else {
      throw StoreIdentityCLIError.unsafePath(
        "\(label) is not a real directory"
      )
    }
    return resolved
  }

  static func requireRealDirectory(
    _ url: URL,
    label: String
  ) throws -> URL {
    let standardized = url.standardizedFileURL
    var metadata = stat()
    guard standardized.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
      (UInt32(metadata.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    else {
      throw StoreIdentityCLIError.unsafePath(
        "\(label) is not a real directory"
      )
    }
    return standardized
  }

  // swiftlint:disable:next function_body_length
  static func readStableManifest(at url: URL) throws -> StableManifest {
    let beforePath = try manifestMetadata(at: url)
    guard beforePath.isRegularFile, beforePath.size >= 0 else {
      throw StoreIdentityCLIError.unsafePath(
        "appmanifest is not a real regular file"
      )
    }
    guard
      UInt64(beforePath.size)
        <= UInt64(SteamMetadataParser.maximumInputBytes)
    else {
      throw StoreIdentityCLIError.invalidInput(
        "appmanifest exceeds the maximum input size"
      )
    }

    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      if errno == ELOOP || errno == ENOTDIR {
        throw StoreIdentityCLIError.unsafePath(
          "appmanifest is not a real regular file"
        )
      }
      throw StoreIdentityCLIError.fileSystem(
        operation: "open appmanifest",
        code: errno
      )
    }
    defer {
      Darwin.close(descriptor)
    }

    let beforeDescriptor = try manifestMetadata(
      descriptor: descriptor,
      operation: "fstat appmanifest before read"
    )
    guard beforeDescriptor == beforePath, beforeDescriptor.isRegularFile else {
      throw StoreIdentityCLIError.invalidInput(
        "appmanifest changed before it could be read"
      )
    }
    let data = try readBoundedManifest(descriptor: descriptor)
    let afterDescriptor = try manifestMetadata(
      descriptor: descriptor,
      operation: "fstat appmanifest after read"
    )
    let afterPath = try manifestMetadata(at: url)
    guard beforeDescriptor == afterDescriptor,
      beforeDescriptor == afterPath,
      data.count == Int(beforeDescriptor.size)
    else {
      throw StoreIdentityCLIError.invalidInput(
        "appmanifest changed while it was read"
      )
    }
    return StableManifest(data: data, metadata: afterDescriptor)
  }

  static func readBoundedManifest(descriptor: Int32) throws -> Data {
    let maximum = SteamMetadataParser.maximumInputBytes
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let requested = min(buffer.count, maximum - data.count + 1)
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, requested)
      }
      if count < 0 {
        if errno == EINTR {
          continue
        }
        throw StoreIdentityCLIError.fileSystem(
          operation: "read appmanifest",
          code: errno
        )
      }
      if count == 0 {
        return data
      }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= maximum else {
        throw StoreIdentityCLIError.invalidInput(
          "appmanifest exceeds the maximum input size"
        )
      }
    }
  }

  static func manifestMetadata(at url: URL) throws -> ManifestFileMetadata {
    var value = stat()
    guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0 else {
      throw StoreIdentityCLIError.fileSystem(
        operation: "lstat appmanifest",
        code: errno
      )
    }
    return ManifestFileMetadata(value)
  }

  static func manifestMetadata(
    descriptor: Int32,
    operation: String
  ) throws -> ManifestFileMetadata {
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else {
      throw StoreIdentityCLIError.fileSystem(
        operation: operation,
        code: errno
      )
    }
    return ManifestFileMetadata(value)
  }

  static func resolvedPath(_ url: URL) -> URL {
    var cursor = url.standardizedFileURL
    var suffix = [String]()
    var metadata = stat()
    while cursor.path != "/",
      cursor.path.withCString({ Darwin.lstat($0, &metadata) }) != 0 {
      suffix.append(cursor.lastPathComponent)
      cursor.deleteLastPathComponent()
    }
    var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
    for component in suffix.reversed() {
      resolved.appendPathComponent(component)
    }
    return resolved.standardizedFileURL
  }

  static func isSameOrDescendant(_ child: URL, of parent: URL) -> Bool {
    let childComponents = child.standardizedFileURL.pathComponents
    let parentComponents = parent.standardizedFileURL.pathComponents
    guard childComponents.count >= parentComponents.count else {
      return false
    }
    return zip(parentComponents, childComponents).allSatisfy(==)
  }

  static func isSafeInstallDirectory(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.contains("/")
      && !value.contains("\\")
      && value.unicodeScalars.allSatisfy {
        $0.value >= 0x20 && $0.value != 0x7F
      }
  }

  static func writeError(_ value: String) {
    try? FileHandle.standardError.write(contentsOf: Data(value.utf8))
  }
}
