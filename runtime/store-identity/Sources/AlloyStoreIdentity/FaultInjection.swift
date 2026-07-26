// Author: Timur Isaev

import Foundation

@_spi(FaultTesting)
public enum FaultPoint: String, Sendable {
  case afterFingerprintCandidate
  case afterTemporaryFileSync
  case afterFinalLink
  case afterDirectorySync
}

@_spi(FaultTesting)
public typealias FaultInjector = @Sendable (FaultPoint, String?) -> Void

enum FaultInjection {
  static let none: FaultInjector = { _, _ in }
}
