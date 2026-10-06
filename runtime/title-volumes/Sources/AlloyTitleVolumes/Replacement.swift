// Author: Timur Isaev

import Darwin
import Foundation

struct ReplacementJournal: Codable {
    let id: String
    let gameID: String
    let kind: VolumeKind
    let beforeArchiveID: String
    let before: TreeInventory
    let after: TreeInventory
    var settingsVersion: SettingsVersion?
}

struct ReplacementRequest {
    let kind: VolumeKind
    let before: ArchiveRecord
    let after: TreeInventory
    let operation: String
    var settingsVersion: SettingsVersion?
}

extension TitleVolumeStore {
    func replace(_ gameID: String, source: Directory, request: ReplacementRequest,
                 fault: VolumeFaultInjector?) throws {
        let kind = request.kind
        let before = request.before
        let after = request.after
        let operation = request.operation
        guard [.saves, .settings].contains(kind), before.gameID == gameID,
              before.volumeKind == kind else { throw VolumeError.invalidPolicy }
        let volume = try resolve(gameID, kind, nil, in: loadRegistry())
        guard after.bytes <= volume.quota else { throw VolumeError.quotaExceeded }
        let transactions = try metadata.child("transactions", create: true)
        let id = UUID().uuidString.lowercased()
        let transaction = try transactions.child(id, create: true)
        let stagedTree = try transaction.child("tree", create: true)
        _ = try source.cloneTree(to: stagedTree, inventory: after)
        guard try stagedTree.inventory(limit: volume.quota) == after,
              try directory(volume).inventory(limit: volume.quota) == before.inventory else {
            throw VolumeError.conflict
        }
        try fault?("\(operation).after-stage")
        let journal = ReplacementJournal(id: id, gameID: gameID, kind: kind,
                                          beforeArchiveID: before.id, before: before.inventory, after: after,
                                          settingsVersion: request.settingsVersion)
        try transaction.write("journal.json", data: checked(journal))
        try fault?("\(operation).after-journal")
        let title = try volumes.child(gameID)
        guard renameatx_np(transaction.descriptor, "tree", title.descriptor, kind.rawValue,
                           UInt32(RENAME_SWAP)) == 0 else { throw VolumeError.systemCall("swap tree", errno) }
        try fault?("\(operation).after-swap")
        try title.sync()
        try transaction.sync()
        try fault?("\(operation).after-sync")
        if let version = request.settingsVersion {
            try publishSettings(version)
            try fault?("\(operation).after-metadata")
        }
        try transaction.write("committed.json", data: checked(journal))
        try fault?("\(operation).after-commit")
        try transactions.remove(id)
    }

    func recoverPending() throws {
        if try metadata.information("transactions") != nil {
            let transactions = try metadata.child("transactions")
            for id in try transactions.names() {
                try identifier(id)
                let transaction = try transactions.child(id)
                if try transaction.information("journal.json") != nil {
                    try recoverReplacement(id, transaction: transaction, transactions: transactions)
                } else {
                    // The swap is impossible until a complete journal has been durably published.
                    try transactions.remove(id)
                }
            }
        }
        if try metadata.information("staging") != nil {
            let stages = try metadata.child("staging")
            for id in try stages.names() {
                try identifier(id)
                try stages.remove(id)
            }
        }
        if try metadata.information("archive-trash") != nil {
            let trash = try metadata.child("archive-trash")
            for id in try trash.names() {
                try identifier(id)
                try trash.remove(id)
            }
        }
    }
    private func recoverReplacement(_ id: String, transaction: Directory, transactions: Directory) throws {
        let journal = try decodeChecked(ReplacementJournal.self, transaction.read("journal.json"))
        guard journal.id == id, [.saves, .settings].contains(journal.kind) else {
            throw VolumeError.integrityMismatch
        }
        try quiet(journal.gameID) {
            let before = try archive(journal.gameID, journal.beforeArchiveID)
            guard before.inventory == journal.before, before.volumeKind == journal.kind else {
                throw VolumeError.integrityMismatch
            }
            let volume = try resolve(journal.gameID, journal.kind, nil, in: loadRegistry())
            let current = try directory(volume).inventory(limit: volume.quota)
            guard current == journal.before || current == journal.after else {
                throw VolumeError.integrityMismatch
            }
            if current == journal.after, let version = journal.settingsVersion {
                guard journal.kind == .settings, version.gameID == journal.gameID,
                      version.inventory == journal.after else { throw VolumeError.integrityMismatch }
                try publishSettings(version)
            }
            // No automatic restore: keep the atomic result present at the public path.
            try transactions.remove(id)
        }
    }

}
