// Author: Timur Isaev

import Foundation

public enum UpdateWatcherError: Error, Equatable, Sendable {
  case inconsistentObservation(field: String)
  case appIDMismatch(anchor: String, observed: String)
}

extension UpdateWatcherError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .inconsistentObservation(let field):
      "Steam metadata and fingerprint disagree for \(field)"
    case .appIDMismatch(let anchor, let observed):
      "observation appid \(observed) does not match anchor appid \(anchor)"
    }
  }
}

public struct UpdateObservation: Equatable, Sendable {
  public let metadata: SteamAppManifest
  public let fingerprint: FingerprintRecord

  public init(
    metadata: SteamAppManifest,
    fingerprint: FingerprintRecord
  ) {
    self.metadata = metadata
    self.fingerprint = fingerprint
  }
}

public struct UpdateDetection: Equatable, Sendable {
  public let appID: String
  public let supersededBuildID: String
  public let observedBuildID: String
  public let metadataChanged: Bool
  public let gameContentChanged: Bool
  public let changedDepotIDs: [String]
  public let addedFilePaths: [String]
  public let removedFilePaths: [String]
  public let changedFilePaths: [String]

  fileprivate init(
    appID: String,
    supersededBuildID: String,
    observedBuildID: String,
    metadataChanged: Bool,
    gameContentChanged: Bool,
    changedDepotIDs: [String],
    addedFilePaths: [String],
    removedFilePaths: [String],
    changedFilePaths: [String]
  ) {
    self.appID = appID
    self.supersededBuildID = supersededBuildID
    self.observedBuildID = observedBuildID
    self.metadataChanged = metadataChanged
    self.gameContentChanged = gameContentChanged
    self.changedDepotIDs = changedDepotIDs
    self.addedFilePaths = addedFilePaths
    self.removedFilePaths = removedFilePaths
    self.changedFilePaths = changedFilePaths
  }
}

public enum UpdateWatcher {
  public static func detect(
    anchor: FingerprintRecord,
    observation: UpdateObservation
  ) throws -> UpdateDetection? {
    try validate(observation: observation)

    let observed = observation.fingerprint
    guard sameText(anchor.appID, observed.appID) else {
      throw UpdateWatcherError.appIDMismatch(
        anchor: anchor.appID,
        observed: observed.appID
      )
    }

    let changedDepotIDs = changedDepots(
      anchor: anchor.depots,
      observed: observed.depots
    )
    let metadataChanged =
      !sameText(anchor.name, observed.name)
      || !sameText(anchor.buildID, observed.buildID)
      || !changedDepotIDs.isEmpty
    let fileDelta = changedFiles(
      anchor: anchor.files,
      observed: observed.files
    )
    let gameContentChanged =
      !sameText(anchor.aggregateSHA256, observed.aggregateSHA256)
      || !sameFileTables(anchor.files, observed.files)

    guard metadataChanged || gameContentChanged else {
      return nil
    }
    return UpdateDetection(
      appID: anchor.appID,
      supersededBuildID: anchor.buildID,
      observedBuildID: observed.buildID,
      metadataChanged: metadataChanged,
      gameContentChanged: gameContentChanged,
      changedDepotIDs: changedDepotIDs,
      addedFilePaths: fileDelta.added,
      removedFilePaths: fileDelta.removed,
      changedFilePaths: fileDelta.changed
    )
  }
}

extension UpdateWatcher {
  fileprivate struct FileDelta {
    let added: [String]
    let removed: [String]
    let changed: [String]
  }

  fileprivate static func validate(observation: UpdateObservation) throws {
    let metadata = observation.metadata
    let fingerprint = observation.fingerprint

    guard sameText(metadata.appID, fingerprint.appID) else {
      throw UpdateWatcherError.inconsistentObservation(field: "appid")
    }
    guard sameText(metadata.name, fingerprint.name) else {
      throw UpdateWatcherError.inconsistentObservation(field: "name")
    }
    guard sameText(metadata.buildID, fingerprint.buildID) else {
      throw UpdateWatcherError.inconsistentObservation(field: "buildid")
    }
    guard metadata.sizeOnDisk == fingerprint.totalBytes else {
      throw UpdateWatcherError.inconsistentObservation(field: "SizeOnDisk")
    }
    guard metadata.installedDepots.count == fingerprint.depots.count else {
      throw UpdateWatcherError.inconsistentObservation(
        field: "InstalledDepots"
      )
    }
    for (depotID, metadataDepot) in metadata.installedDepots {
      guard let fingerprintDepot = fingerprint.depots[depotID],
        sameText(metadataDepot.manifestID, fingerprintDepot.manifest),
        sameText(metadataDepot.sizeText, fingerprintDepot.size)
      else {
        throw UpdateWatcherError.inconsistentObservation(
          field: "InstalledDepots[\(depotID)]"
        )
      }
    }
  }

  fileprivate static func changedDepots(
    anchor: [String: FingerprintDepotRecord],
    observed: [String: FingerprintDepotRecord]
  ) -> [String] {
    let depotIDs = Set(anchor.keys).union(observed.keys)
    return
      depotIDs
      .filter { depotID in
        guard let anchored = anchor[depotID],
          let current = observed[depotID]
        else {
          return true
        }
        return !sameText(anchored.manifest, current.manifest)
          || !sameText(anchored.size, current.size)
      }
      .sorted(by: utf8Less)
  }

  fileprivate static func changedFiles(
    anchor: [FingerprintFileRecord],
    observed: [FingerprintFileRecord]
  ) -> FileDelta {
    var added = [String]()
    var removed = [String]()
    var changed = [String]()
    var anchorIndex = anchor.startIndex
    var observedIndex = observed.startIndex

    while anchorIndex < anchor.endIndex && observedIndex < observed.endIndex {
      let anchored = anchor[anchorIndex]
      let current = observed[observedIndex]
      if sameText(anchored.path, current.path) {
        let fileChanged =
          anchored.size != current.size
          || !sameText(anchored.sha256, current.sha256)
        if fileChanged {
          changed.append(anchored.path)
        }
        anchor.formIndex(after: &anchorIndex)
        observed.formIndex(after: &observedIndex)
      } else if utf8Less(anchored.path, current.path) {
        removed.append(anchored.path)
        anchor.formIndex(after: &anchorIndex)
      } else {
        added.append(current.path)
        observed.formIndex(after: &observedIndex)
      }
    }
    while anchorIndex < anchor.endIndex {
      removed.append(anchor[anchorIndex].path)
      anchor.formIndex(after: &anchorIndex)
    }
    while observedIndex < observed.endIndex {
      added.append(observed[observedIndex].path)
      observed.formIndex(after: &observedIndex)
    }

    return FileDelta(
      added: added.sorted(by: utf8Less),
      removed: removed.sorted(by: utf8Less),
      changed: changed.sorted(by: utf8Less)
    )
  }

  fileprivate static func sameFileTables(
    _ left: [FingerprintFileRecord],
    _ right: [FingerprintFileRecord]
  ) -> Bool {
    guard left.count == right.count else {
      return false
    }
    return zip(left, right).allSatisfy { leftFile, rightFile in
      sameText(leftFile.path, rightFile.path)
        && leftFile.size == rightFile.size
        && sameText(leftFile.sha256, rightFile.sha256)
    }
  }

  fileprivate static func sameText(_ left: String, _ right: String) -> Bool {
    left.utf8.elementsEqual(right.utf8)
  }

  fileprivate static func utf8Less(_ left: String, _ right: String) -> Bool {
    left.utf8.lexicographicallyPrecedes(right.utf8)
  }
}
