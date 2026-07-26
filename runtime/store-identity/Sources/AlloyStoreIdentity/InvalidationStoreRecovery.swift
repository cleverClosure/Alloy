// Author: Timur Isaev

import Darwin
import Foundation

extension InvalidationStore {
  func withExclusiveLock<Result>(
    in directory: URL,
    operation: () throws -> Result
  ) throws -> Result {
    let lockURL = directory.appendingPathComponent(
      ".alloy-invalidation.lock",
      isDirectory: false
    )
    let descriptor = lockURL.path.withCString {
      Darwin.open(
        $0,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      if errno == ELOOP || errno == EISDIR || errno == ENOTDIR {
        throw InvalidationStoreError.unsafeStoragePath(lockURL.path)
      }
      throw InvalidationStoreError.fileSystem(
        operation: "open lock",
        path: lockURL.path,
        code: errno
      )
    }
    defer {
      _ = flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      (UInt32(metadata.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFREG),
      metadata.st_nlink == 1
    else {
      throw InvalidationStoreError.unsafeStoragePath(lockURL.path)
    }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else {
        throw InvalidationStoreError.fileSystem(
          operation: "lock invalidation store",
          path: lockURL.path,
          code: errno
        )
      }
    }
    return try operation()
  }

  func recoverTemporaryFiles(
    for record: InvalidationRecord,
    in directory: URL
  ) throws {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(
        atPath: directory.path
      )
    } catch {
      throw fileSystemError(
        operation: "list invalidation directory",
        path: directory.path,
        fallback: error
      )
    }
    let matching = names.filter {
      isGeneratedTemporaryName($0, digest: record.digestHex)
    }
    var temporaryURLs = [URL]()
    temporaryURLs.reserveCapacity(matching.count)
    for name in matching {
      let url = directory.appendingPathComponent(name, isDirectory: false)
      var metadata = stat()
      guard url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
        throw InvalidationStoreError.fileSystem(
          operation: "lstat temporary",
          path: url.path,
          code: errno
        )
      }
      guard
        (UInt32(metadata.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFREG)
      else {
        throw InvalidationStoreError.unsafeStoragePath(url.path)
      }
      temporaryURLs.append(url)
    }

    for url in temporaryURLs {
      guard url.path.withCString({ Darwin.unlink($0) }) == 0 else {
        throw InvalidationStoreError.fileSystem(
          operation: "unlink stale temporary",
          path: url.path,
          code: errno
        )
      }
    }
    if !temporaryURLs.isEmpty {
      try syncDirectory(directory)
    }
  }

  private func isGeneratedTemporaryName(
    _ name: String,
    digest: String
  ) -> Bool {
    let prefix = ".\(digest).tmp-"
    guard name.hasPrefix(prefix) else {
      return false
    }
    let bytes = Array(name.dropFirst(prefix.count).utf8)
    guard bytes.count == 36 else {
      return false
    }
    let hyphenOffsets = Set([8, 13, 18, 23])
    return bytes.enumerated().allSatisfy { offset, byte in
      if hyphenOffsets.contains(offset) {
        return byte == 45
      }
      return (byte >= 97 && byte <= 102)
        || (byte >= 48 && byte <= 57)
    }
  }
}
