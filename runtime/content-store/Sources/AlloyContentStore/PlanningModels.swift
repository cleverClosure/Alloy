// Author: Timur Isaev

import Foundation

/// The additional immutable content an operation would add to the store.
///
/// Counts describe unique CAS objects. Repeated descriptors with the same
/// digest are represented once.
public struct DiskSpacePlan: Equatable, Sendable {
    public let inputObjectCount: Int
    public let uniqueObjectCount: Int
    public let presentObjectCount: Int
    public let missingObjectCount: Int
    public let additionalBytesRequired: UInt64
    /// Largest missing object, copied privately before CAS publication.
    public let publicationScratchBytes: UInt64
    /// Missing object bytes plus one private publication copy; excludes metadata.
    public let activationPeakBytesRequired: UInt64

    /// Checks activation's peak logical content footprint, including its copy.
    /// Filesystem metadata, allocation rounding and concurrent writers are not reserved.
    public func requireActivationFits(availableBytes: UInt64) throws {
        guard activationPeakBytesRequired <= availableBytes else {
            throw InsufficientDiskSpaceError(
                requiredBytes: activationPeakBytesRequired, availableBytes: availableBytes
            )
        }
    }

    /// Refuses the planned operation when its additional CAS content will not fit.
    public func requireFits(availableBytes: UInt64) throws {
        guard additionalBytesRequired <= availableBytes else {
            throw InsufficientDiskSpaceError(
                requiredBytes: additionalBytesRequired,
                availableBytes: availableBytes
            )
        }
    }
}

/// A stable, named refusal carrying both sides of the disk-space decision.
public struct InsufficientDiskSpaceError: Error, CustomStringConvertible, Equatable, Sendable {
    public let requiredBytes: UInt64
    public let availableBytes: UInt64

    public init(requiredBytes: UInt64, availableBytes: UInt64) {
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
    }

    public var description: String {
        "insufficient disk space: \(requiredBytes) bytes required, \(availableBytes) bytes available"
    }
}

public enum DiskPlanningError: Error, CustomStringConvertible, Equatable, Sendable {
    case byteCountOverflow

    public var description: String {
        switch self {
        case .byteCountOverflow:
            "disk-planning byte count exceeds UInt64.max"
        }
    }
}

/// Logical regular-file bytes a garbage-collection pass can remove.
///
/// Generation hard links are not counted as separate content. Unique
/// generation files are reported separately. Directory metadata and
/// symbolic-link storage are intentionally excluded.
public struct ReclaimEstimate: Equatable, Sendable {
    public let generationBytes: UInt64
    public let casObjectBytes: UInt64
    public let abandonedDownloadBytes: UInt64
    public let quarantineBytes: UInt64
    public let totalBytes: UInt64
    public let deferredOperationCount: Int
    public let generationCount: Int
    public let casObjectCount: Int
    public let abandonedDownloadFileCount: Int
    public let quarantineFileCount: Int

    /// Whether `totalBytes` exactly predicts a collection started from this state.
    public var isExact: Bool {
        deferredOperationCount == 0
    }
}
