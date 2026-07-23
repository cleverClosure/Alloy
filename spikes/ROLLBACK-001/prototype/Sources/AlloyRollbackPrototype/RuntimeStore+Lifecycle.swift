// Author: Timur Isaev

import Foundation

extension RuntimeStore {
    func resume(
        _ operation: inout ActivationOperation,
        faultInjector: FaultInjector?
    ) throws {
        try recoverStarted(&operation)
        try advanceVerification(&operation, faultInjector: faultInjector)
        try advancePublication(&operation, faultInjector: faultInjector)
        try advanceMaterialization(&operation, faultInjector: faultInjector)
        try advanceCandidatePreparation(&operation, faultInjector: faultInjector)
        try advanceRollbackRecording(&operation, faultInjector: faultInjector)
        try advanceActiveSwitch(&operation, faultInjector: faultInjector)
        try advanceHealthWindow(&operation, faultInjector: faultInjector)
        try advanceRetention(&operation, faultInjector: faultInjector)
        try complete(&operation)
    }

    func recoverStarted(_ operation: inout ActivationOperation) throws {
        guard operation.state == .started else {
            return
        }
        guard fileManager.fileExists(atPath: downloadURL(operation).path) else {
            operation.state = .aborted
            try writeJournal(operation)
            return
        }
        do {
            try verifyDownload(operation)
            operation.state = .downloaded
        } catch {
            try? fileManager.removeItem(at: downloadURL(operation))
            operation.state = .aborted
        }
        try writeJournal(operation)
    }

    func advanceVerification(
        _ operation: inout ActivationOperation,
        faultInjector: FaultInjector?
    ) throws {
        guard operation.state == .downloaded else {
            return
        }
        try verifyDownload(operation)
        try faultInjector?("after-verify-action")
        operation.state = .verified
        try writeJournal(operation)
        try faultInjector?("after-verify")
    }

    func advancePublication(
        _ operation: inout ActivationOperation,
        faultInjector: FaultInjector?
    ) throws {
        guard operation.state == .verified else {
            return
        }
        try publishObject(operation)
        try faultInjector?("after-publish-cas-action")
        operation.state = .published
        try writeJournal(operation)
        try faultInjector?("after-publish-cas")
    }

    func advanceMaterialization(
        _ operation: inout ActivationOperation,
        faultInjector: FaultInjector?
    ) throws {
        guard operation.state == .published else {
            return
        }
        operation.candidate = try materialize(operation)
        try faultInjector?("after-materialize-action")
        operation.state = .materialized
        try writeJournal(operation)
        try faultInjector?("after-materialize")
    }

    func advanceCandidatePreparation(
        _ operation: inout ActivationOperation,
        faultInjector: FaultInjector?
    ) throws {
        guard operation.state == .materialized else {
            return
        }
        let candidate = try requireCandidate(operation)
        try writeReference(candidate, kind: .candidate, gameID: operation.gameID)
        try faultInjector?("after-prepare-candidate-action")
        operation.state = .candidatePrepared
        try writeJournal(operation)
        try faultInjector?("after-prepare-candidate")
    }

    func advanceRollbackRecording(
        _ operation: inout ActivationOperation,
        faultInjector: FaultInjector?
    ) throws {
        guard operation.state == .candidatePrepared else {
            return
        }
        if let previous = operation.previousActive {
            try writeReference(previous, kind: .rollback, gameID: operation.gameID)
        } else {
            try removeReference(.rollback, gameID: operation.gameID)
        }
        try faultInjector?("after-record-rollback-action")
        operation.state = .rollbackRecorded
        try writeJournal(operation)
        try faultInjector?("after-record-rollback")
    }

    func advanceActiveSwitch(
        _ operation: inout ActivationOperation,
        faultInjector: FaultInjector?
    ) throws {
        guard operation.state == .rollbackRecorded else {
            return
        }
        let candidate = try requireCandidate(operation)
        try validateReference(candidate, gameID: operation.gameID)
        try writeReference(candidate, kind: .active, gameID: operation.gameID)
        try faultInjector?("after-switch-active-action")
        operation.state = .activeSwitched
        try writeJournal(operation)
        try faultInjector?("after-switch-active")
    }

    func advanceHealthWindow(
        _ operation: inout ActivationOperation,
        faultInjector: FaultInjector?
    ) throws {
        guard operation.state == .activeSwitched else {
            return
        }
        if operation.healthOutcome == .fail {
            try restorePreviousActive(operation)
        } else {
            try validateReference(requireCandidate(operation), gameID: operation.gameID)
        }
        try faultInjector?("after-health-window-action")
        operation.state = .healthChecked
        try writeJournal(operation)
        try faultInjector?("after-health-window")
    }

    func restorePreviousActive(_ operation: ActivationOperation) throws {
        if let previous = operation.previousActive {
            try validateReference(previous, gameID: operation.gameID)
            try writeReference(previous, kind: .active, gameID: operation.gameID)
        } else {
            try removeReference(.active, gameID: operation.gameID)
        }
    }

    func advanceRetention(
        _ operation: inout ActivationOperation,
        faultInjector: FaultInjector?
    ) throws {
        guard operation.state == .healthChecked else {
            return
        }
        try removeReference(.candidate, gameID: operation.gameID)
        try faultInjector?("after-retain-collect-action")
        operation.state = .retained
        try writeJournal(operation)
        try faultInjector?("after-retain-collect")
    }

    func complete(_ operation: inout ActivationOperation) throws {
        guard operation.state == .retained else {
            return
        }
        operation.state = .complete
        try writeJournal(operation)
    }

    func requireCandidate(_ operation: ActivationOperation) throws -> GenerationReference {
        if let candidate = operation.candidate {
            return candidate
        }

        let manifestURL = generationURL(
            gameID: operation.gameID,
            generationID: operation.generationID
        ).appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw RuntimeStoreError.incompleteGeneration(operation.generationID)
        }
        return GenerationReference(
            generationID: operation.generationID,
            manifestSHA256: Self.sha256(try Data(contentsOf: manifestURL))
        )
    }
}
