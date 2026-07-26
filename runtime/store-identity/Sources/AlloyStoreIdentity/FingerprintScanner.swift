// Author: Timur Isaev

import CryptoKit
import Darwin
import Foundation

public enum FingerprintScanner {
  public static func scan(
    installRoot: URL,
    identity: FingerprintIdentity
  ) throws -> FingerprintRecord {
    try scan(
      installRoot: installRoot,
      identity: identity,
      beforeFinalObservation: {}
    )
  }

  static func scan(
    installRoot: URL,
    identity: FingerprintIdentity,
    beforeFinalObservation: () throws -> Void
  ) throws -> FingerprintRecord {
    let root = installRoot.standardizedFileURL
    let rootMetadata: FileMetadata
    do {
      rootMetadata = try metadata(at: root)
    } catch {
      throw FingerprintError.installRootNotDirectory(root.path)
    }
    guard rootMetadata.isDirectory, !rootMetadata.isSymbolicLink else {
      throw FingerprintError.installRootNotDirectory(root.path)
    }

    let firstObservation = try observeRegularFiles(root: root)
    var records = [FingerprintFileRecord]()
    records.reserveCapacity(firstObservation.count)
    var hashedObservation = [String: FileMetadata]()
    hashedObservation.reserveCapacity(firstObservation.count)

    for candidate in firstObservation {
      let hashed = try hash(candidate: candidate)
      records.append(
        try FingerprintFileRecord(
          path: candidate.path,
          size: hashed.size,
          sha256: hashed.sha256
        )
      )
      hashedObservation[candidate.path] = hashed.metadata
    }

    try beforeFinalObservation()
    let secondObservation = try observeRegularFiles(root: root)
    guard firstObservation.map(\.path) == secondObservation.map(\.path) else {
      throw FingerprintError.scanChanged(root.path)
    }
    for candidate in secondObservation {
      guard hashedObservation[candidate.path] == candidate.metadata else {
        throw FingerprintError.scanChanged(candidate.path)
      }
    }
    let finalRootMetadata: FileMetadata
    do {
      finalRootMetadata = try metadata(at: root)
    } catch {
      throw FingerprintError.scanChanged(root.path)
    }
    guard finalRootMetadata == rootMetadata else {
      throw FingerprintError.scanChanged(root.path)
    }

    return try FingerprintRecord(identity: identity, files: records)
  }
}

extension FingerprintScanner {
  fileprivate struct Candidate {
    let path: String
    let url: URL
    let metadata: FileMetadata
  }

  fileprivate struct HashedFile {
    let size: UInt64
    let sha256: String
    let metadata: FileMetadata
  }

  fileprivate struct FileMetadata: Equatable {
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

    var isDirectory: Bool {
      (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
    }

    var isRegularFile: Bool {
      (mode & UInt32(S_IFMT)) == UInt32(S_IFREG)
    }

    var isSymbolicLink: Bool {
      (mode & UInt32(S_IFMT)) == UInt32(S_IFLNK)
    }
  }

  fileprivate static func observeRegularFiles(root: URL) throws -> [Candidate] {
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: nil,
      options: [],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    ) else {
      throw FingerprintError.inputOutput(
        path: root.path,
        operation: "enumerate"
      )
    }

    let rootComponents = root.pathComponents
    var candidates = [Candidate]()
    while let url = enumerator.nextObject() as? URL {
      if enumerationError != nil {
        break
      }
      if let candidate = try observedCandidate(
        at: url.standardizedFileURL,
        rootComponents: rootComponents
      ) {
        candidates.append(candidate)
      }
    }
    if enumerationError != nil {
      throw FingerprintError.inputOutput(
        path: root.path,
        operation: "enumerate"
      )
    }
    candidates.sort {
      FingerprintValidation.utf8Less($0.path, $1.path)
    }
    return candidates
  }

  fileprivate static func observedCandidate(
    at url: URL,
    rootComponents: [String]
  ) throws -> Candidate? {
    let path = relativePath(for: url, rootComponents: rootComponents)
    let observed: FileMetadata
    do {
      observed = try metadata(at: url)
    } catch {
      throw FingerprintError.scanChanged(path)
    }
    guard !observed.isSymbolicLink,
      !observed.isDirectory,
      observed.isRegularFile
    else {
      return nil
    }
    try FingerprintValidation.validateRelativePath(path)
    return Candidate(path: path, url: url, metadata: observed)
  }

  fileprivate static func relativePath(
    for url: URL,
    rootComponents: [String]
  ) -> String {
    let components = url.pathComponents
    guard components.count > rootComponents.count,
      components.starts(with: rootComponents)
    else {
      return url.path
    }
    return components.dropFirst(rootComponents.count).joined(separator: "/")
  }

  fileprivate static func hash(candidate: Candidate) throws -> HashedFile {
    let beforeOpen = try stableMetadata(
      at: candidate.url,
      relativePath: candidate.path
    )
    guard beforeOpen == candidate.metadata, beforeOpen.isRegularFile else {
      throw FingerprintError.scanChanged(candidate.path)
    }

    let descriptor = try open(candidate: candidate)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
      try? handle.close()
    }

    let opened = try metadata(
      descriptor: descriptor,
      path: candidate.path,
      operation: "fstat before read"
    )
    guard opened == beforeOpen, opened.isRegularFile, opened.size >= 0 else {
      throw FingerprintError.scanChanged(candidate.path)
    }

    let payload = try hashBytes(handle: handle, path: candidate.path)
    let afterRead = try metadata(
      descriptor: descriptor,
      path: candidate.path,
      operation: "fstat after read"
    )
    let afterPath = try stableMetadata(
      at: candidate.url,
      relativePath: candidate.path
    )
    guard afterRead == opened,
      afterPath == afterRead,
      payload.size == UInt64(afterRead.size)
    else {
      throw FingerprintError.scanChanged(candidate.path)
    }

    return HashedFile(
      size: payload.size,
      sha256: payload.sha256,
      metadata: afterRead
    )
  }

  fileprivate static func open(candidate: Candidate) throws -> Int32 {
    let descriptor = candidate.url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      if errno == ENOENT || errno == ELOOP || errno == ENOTDIR {
        throw FingerprintError.scanChanged(candidate.path)
      }
      throw FingerprintError.fileSystem(
        path: candidate.path,
        operation: "open",
        code: errno
      )
    }
    return descriptor
  }

  fileprivate static func hashBytes(
    handle: FileHandle,
    path: String
  ) throws -> (size: UInt64, sha256: String) {
    var digest = SHA256()
    var bytesRead = UInt64.zero
    do {
      while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
        digest.update(data: data)
        let (updated, overflow) = bytesRead.addingReportingOverflow(
          UInt64(data.count)
        )
        guard !overflow else {
          throw FingerprintError.sizeOverflow
        }
        bytesRead = updated
      }
    } catch let error as FingerprintError {
      throw error
    } catch {
      throw FingerprintError.inputOutput(path: path, operation: "read")
    }
    return (bytesRead, FingerprintValidation.hex(digest.finalize()))
  }

  fileprivate static func stableMetadata(
    at url: URL,
    relativePath: String
  ) throws -> FileMetadata {
    do {
      return try metadata(at: url)
    } catch {
      throw FingerprintError.scanChanged(relativePath)
    }
  }

  fileprivate static func metadata(at url: URL) throws -> FileMetadata {
    var value = stat()
    let result = url.path.withCString { path in
      Darwin.lstat(path, &value)
    }
    guard result == 0 else {
      throw FingerprintError.fileSystem(
        path: url.path,
        operation: "lstat",
        code: errno
      )
    }
    return FileMetadata(value)
  }

  fileprivate static func metadata(
    descriptor: Int32,
    path: String,
    operation: String
  ) throws -> FileMetadata {
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else {
      throw FingerprintError.fileSystem(
        path: path,
        operation: operation,
        code: errno
      )
    }
    return FileMetadata(value)
  }
}
