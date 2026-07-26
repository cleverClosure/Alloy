// Author: Timur Isaev

import Darwin
import Foundation

public enum InvalidationStoreError: Error, Equatable, Sendable {
  case noMatchingSelectors
  case unrepresentableDetection
  case collision(String)
  case unsafeStoragePath(String)
  case fileSystem(operation: String, path: String, code: Int32)
}

extension InvalidationStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noMatchingSelectors:
      "selector registry has no exact match for the anchor"
    case .unrepresentableDetection:
      "update detection cannot be represented by invalidation v1"
    case .collision(let invalidationID):
      "existing invalidation does not match \(invalidationID)"
    case .unsafeStoragePath(let path):
      "invalidation storage path is not a real directory or regular file: \(path)"
    case .fileSystem(let operation, let path, let code):
      "\(operation) failed for \(path) with errno \(code)"
    }
  }
}

public struct InvalidationEmission: Equatable, Sendable {
  public let record: InvalidationRecord
  public let created: Bool
  public let url: URL

  public init(
    record: InvalidationRecord,
    created: Bool,
    url: URL
  ) {
    self.record = record
    self.created = created
    self.url = url
  }
}

struct InvalidationStoreFaultHooks: Sendable {
  var afterTemporaryFileSync: @Sendable () -> Void = {}
  var afterFinalLink: @Sendable () -> Void = {}
  var afterDirectorySync: @Sendable () -> Void = {}
}

public struct InvalidationStore: Sendable {
  public let root: URL
  private let hooks: InvalidationStoreFaultHooks

  public init(root: URL) {
    self.root = root.standardizedFileURL
    hooks = InvalidationStoreFaultHooks()
  }

  init(
    root: URL,
    hooks: InvalidationStoreFaultHooks
  ) {
    self.root = root.standardizedFileURL
    self.hooks = hooks
  }

  // swiftlint:disable:next function_body_length
  public func emit(
    anchor: FingerprintRecord,
    observation: UpdateObservation,
    registry: SelectorRegistry
  ) throws -> InvalidationEmission? {
    guard
      let detection = try UpdateWatcher.detect(
        anchor: anchor,
        observation: observation
      )
    else {
      return nil
    }

    let selectors = registry.matchingSelectors(for: anchor)
    guard !selectors.isEmpty else {
      throw InvalidationStoreError.noMatchingSelectors
    }
    let superseded = try buildIdentity(anchor)
    let observed = try buildIdentity(observation.fingerprint)
    let record: InvalidationRecord
    do {
      record = try InvalidationRecord.make(
        gameID: anchor.appID,
        storefront: "steam",
        superseded: superseded,
        observed: observed,
        metadataChanged: detection.metadataChanged,
        gameContentChanged: detection.gameContentChanged,
        changedDepotIDs: detection.changedDepotIDs,
        addedFilePaths: detection.addedFilePaths,
        removedFilePaths: detection.removedFilePaths,
        changedFilePaths: detection.changedFilePaths,
        selectorIDs: selectors.map(\.selectorID)
      )
    } catch is InvalidationRecordError {
      throw InvalidationStoreError.unrepresentableDetection
    }

    let directory = root.appendingPathComponent(
      "invalidations",
      isDirectory: true
    )
    try ensureDirectory(root)
    try ensureDirectory(directory)
    let finalURL = directory.appendingPathComponent(
      "\(record.digestHex).json",
      isDirectory: false
    )
    if let existing = try readExisting(
      at: finalURL,
      expected: record
    ) {
      try syncDirectory(directory)
      return InvalidationEmission(
        record: existing,
        created: false,
        url: finalURL
      )
    }

    return try publish(
      record: record,
      finalURL: finalURL,
      directory: directory
    )
  }
}

extension InvalidationStore {
  fileprivate static let maximumPersistedRecordBytes = 8 * 1_024 * 1_024

  fileprivate func buildIdentity(
    _ fingerprint: FingerprintRecord
  ) throws -> InvalidationBuildIdentity {
    try InvalidationBuildIdentity(
      buildID: fingerprint.buildID,
      manifestIDs: fingerprint.depots.mapValues(\.manifest),
      aggregateSHA256: fingerprint.aggregateSHA256
    )
  }

  fileprivate func ensureDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
      )
    } catch {
      var metadata = stat()
      let result = url.path.withCString {
        Darwin.lstat($0, &metadata)
      }
      guard result == 0 else {
        throw fileSystemError(
          operation: "mkdir",
          path: url.path,
          fallback: error
        )
      }
    }
    var metadata = stat()
    guard url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
      (UInt32(metadata.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    else {
      throw InvalidationStoreError.unsafeStoragePath(url.path)
    }
  }

  // swiftlint:disable:next function_body_length
  fileprivate func publish(
    record: InvalidationRecord,
    finalURL: URL,
    directory: URL
  ) throws -> InvalidationEmission {
    let data = try record.canonicalJSON()
    let temporaryURL = directory.appendingPathComponent(
      ".\(record.digestHex).tmp-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    let descriptor = temporaryURL.path.withCString {
      Darwin.open(
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      throw InvalidationStoreError.fileSystem(
        operation: "open temporary",
        path: temporaryURL.path,
        code: errno
      )
    }
    var descriptorOpen = true
    var temporaryExists = true
    defer {
      if descriptorOpen {
        Darwin.close(descriptor)
      }
      if temporaryExists {
        temporaryURL.path.withCString {
          _ = Darwin.unlink($0)
        }
      }
    }

    try write(data, descriptor: descriptor, path: temporaryURL.path)
    guard Darwin.fsync(descriptor) == 0 else {
      throw InvalidationStoreError.fileSystem(
        operation: "fsync temporary",
        path: temporaryURL.path,
        code: errno
      )
    }
    hooks.afterTemporaryFileSync()
    let closeResult = Darwin.close(descriptor)
    descriptorOpen = false
    guard closeResult == 0 else {
      throw InvalidationStoreError.fileSystem(
        operation: "close temporary",
        path: temporaryURL.path,
        code: errno
      )
    }

    let linkResult = temporaryURL.path.withCString { temporaryPath in
      finalURL.path.withCString { finalPath in
        Darwin.link(temporaryPath, finalPath)
      }
    }
    if linkResult != 0 {
      let linkError = errno
      temporaryURL.path.withCString {
        _ = Darwin.unlink($0)
      }
      temporaryExists = false
      let existing =
        linkError == EEXIST
        ? try readExisting(at: finalURL, expected: record) : nil
      if let existing {
        try syncDirectory(directory)
        return InvalidationEmission(
          record: existing,
          created: false,
          url: finalURL
        )
      }
      throw InvalidationStoreError.fileSystem(
        operation: "link final",
        path: finalURL.path,
        code: linkError
      )
    }

    hooks.afterFinalLink()
    try syncDirectory(directory)
    hooks.afterDirectorySync()
    temporaryURL.path.withCString {
      _ = Darwin.unlink($0)
    }
    temporaryExists = false
    try syncDirectory(directory)
    return InvalidationEmission(
      record: record,
      created: true,
      url: finalURL
    )
  }

  fileprivate func readExisting(
    at url: URL,
    expected: InvalidationRecord
  ) throws -> InvalidationRecord? {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      if errno == ENOENT {
        return nil
      }
      throw InvalidationStoreError.collision(expected.invalidationID)
    }
    defer {
      Darwin.close(descriptor)
    }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      (UInt32(metadata.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFREG),
      metadata.st_size >= 0,
      UInt64(metadata.st_size) <= UInt64(Self.maximumPersistedRecordBytes)
    else {
      throw InvalidationStoreError.collision(expected.invalidationID)
    }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data: Data
    do {
      data = try handle.readToEnd() ?? Data()
    } catch {
      throw InvalidationStoreError.collision(expected.invalidationID)
    }
    guard let record = try? InvalidationRecord.decode(data),
      record == expected,
      let canonical = try? record.canonicalJSON(),
      canonical == data
    else {
      throw InvalidationStoreError.collision(expected.invalidationID)
    }
    return record
  }

  fileprivate func write(
    _ data: Data,
    descriptor: Int32,
    path: String
  ) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return
      }
      var written = 0
      while written < rawBuffer.count {
        let result = Darwin.write(
          descriptor,
          baseAddress.advanced(by: written),
          rawBuffer.count - written
        )
        if result < 0 {
          if errno == EINTR {
            continue
          }
          throw InvalidationStoreError.fileSystem(
            operation: "write temporary",
            path: path,
            code: errno
          )
        }
        guard result > 0 else {
          throw InvalidationStoreError.fileSystem(
            operation: "write temporary",
            path: path,
            code: EIO
          )
        }
        written += result
      }
    }
  }

  fileprivate func syncDirectory(_ directory: URL) throws {
    let descriptor = directory.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw InvalidationStoreError.fileSystem(
        operation: "open directory",
        path: directory.path,
        code: errno
      )
    }
    defer {
      Darwin.close(descriptor)
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw InvalidationStoreError.fileSystem(
        operation: "fsync directory",
        path: directory.path,
        code: errno
      )
    }
  }

  fileprivate func fileSystemError(
    operation: String,
    path: String,
    fallback: any Error
  ) -> InvalidationStoreError {
    let code = Int32((fallback as NSError).code)
    return .fileSystem(operation: operation, path: path, code: code)
  }
}
