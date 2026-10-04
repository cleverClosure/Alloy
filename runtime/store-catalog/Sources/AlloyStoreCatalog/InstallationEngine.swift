// Author: Timur Isaev
import AlloyContentStore
import Darwin
import Foundation

/// Cooperative local worker. Control calls use only the short journal lock;
/// side effects are serialized separately, including across processes.
public final class InstallationEngine: @unchecked Sendable {
    public let root: URL
    public let contentRoot: URL
    public let journal: OperationJournal
    let faultInjector: JournalFaultInjector?
    private var plans: PlanRepository { PlanRepository(root: root.appendingPathComponent("plans")) }

    public init(root: URL, contentRoot: URL, faultInjector: JournalFaultInjector? = nil) throws {
        self.root = root.standardizedFileURL
        self.contentRoot = contentRoot.standardizedFileURL
        self.faultInjector = faultInjector
        journal = try OperationJournal(
            root: self.root.appendingPathComponent("operations"), faultInjector: faultInjector)
    }

    public func planInstall(
        gameID: String, installationID: String, generationID: String,
        layers: [LayerDescriptor], baseURLs: [URL]
    ) throws -> InstallPlan {
        try Self.validateIdentifier(gameID)
        try Self.validateIdentifier(installationID)
        try Self.validateIdentifier(generationID)
        let request = InstallRequest(gameID: gameID, installationID: installationID,
                                     generationID: generationID, layers: layers, baseURLs: baseURLs)
        let identifier = "plan-" + StoreCatalog.digest(try StoreCatalog.encode(request))
        if let existing = try? plans.read(InstallPlan.self, identifier: identifier) { return existing }
        let estimate = try ContentStore(root: contentRoot).preflightDiskSpace(for: layers)
        let plan = InstallPlan(planID: identifier, gameID: gameID, installationID: installationID,
                               generationID: generationID, layers: layers, baseURLs: baseURLs,
                               requiredObjectBytes: estimate.additionalBytesRequired)
        try plans.save(plan, identifier: identifier)
        return plan
    }

    public func startInstall(planID: String, idempotencyKey: String) throws -> CatalogOperation {
        let plan = try plans.read(InstallPlan.self, identifier: planID)
        try validate(plan)
        guard plan.planID == planID else { throw InstallationError.corruptPlan(planID) }
        return try journal.create(kind: .install, idempotencyKey: idempotencyKey, payload: plan)
    }

    public func planUninstall(gameID: String, installationID: String) throws -> UninstallPlan {
        try Self.validateIdentifier(gameID)
        try Self.validateIdentifier(installationID)
        let references = try ContentStore(root: contentRoot).referenceSnapshot(gameID: gameID)
        let request = UninstallRequest(gameID: gameID, installationID: installationID, expectedReferences: references)
        let identifier = "plan-" + StoreCatalog.digest(try StoreCatalog.encode(request))
        let plan = UninstallPlan(planID: identifier, gameID: gameID,
                                 installationID: installationID, expectedReferences: references)
        try plans.save(plan, identifier: identifier)
        return plan
    }

    public func startUninstall(planID: String, idempotencyKey: String) throws -> CatalogOperation {
        let plan = try plans.read(UninstallPlan.self, identifier: planID)
        let request = UninstallRequest(gameID: plan.gameID, installationID: plan.installationID,
                                       expectedReferences: plan.expectedReferences)
        guard plan.planID == planID,
              planID == "plan-" + StoreCatalog.digest(try StoreCatalog.encode(request)) else {
            throw InstallationError.corruptPlan(planID)
        }
        return try journal.create(kind: .uninstall, idempotencyKey: idempotencyKey, payload: plan)
    }

    public func repairInstallation(_ installationID: String, idempotencyKey: String) throws -> CatalogOperation {
        if let replay = try journal.find(kind: .repair, idempotencyKey: idempotencyKey) {
            let plan = try JSONDecoder().decode(InstallPlan.self, from: replay.payload)
            guard plan.installationID == installationID else { throw OperationError.idempotencyConflict }
            return replay
        }
        let candidates = try journal.list().filter { $0.kind == .install && $0.state == .succeeded }
            .compactMap { try? JSONDecoder().decode(InstallPlan.self, from: $0.payload) }
            .filter { $0.installationID == installationID }
        let store = try ContentStore(root: contentRoot, allowDamagedCatalog: true)
        for plan in candidates {
            let references = try store.referenceSnapshot(gameID: plan.gameID, validateContents: false)
            if references.active?.generationID == plan.generationID {
                return try journal.create(kind: .repair, idempotencyKey: idempotencyKey, payload: plan)
            }
        }
        throw InstallationError.noInstalledPlan(installationID)
    }

    public func pauseOperation(_ identifier: String) throws -> CatalogOperation {
        let operation = try journal.get(identifier)
        guard operation.canPause else { throw OperationError.cannotControl(identifier) }
        return try journal.transition(identifier, to: .paused, stage: "PAUSED")
    }

    public func resumeOperation(_ identifier: String) throws -> CatalogOperation {
        _ = try journal.transition(identifier, to: .running, stage: "RESUMING")
        return try run(identifier)
    }

    public func cancelOperation(_ identifier: String) throws -> CatalogOperation {
        var operation = try journal.get(identifier)
        guard operation.canCancel else { throw OperationError.cannotControl(identifier) }
        if operation.state == .queued {
            operation = try journal.transition(identifier, to: .running, stage: "CANCEL_REQUESTED")
        }
        _ = try journal.transition(identifier, to: .cancelling, stage: "CANCELLING")
        return try journal.transition(identifier, to: .cancelled, stage: "CANCELLED")
    }

    public func run(_ identifier: String) throws -> CatalogOperation {
        try withWorkerLock {
            var operation = try journal.get(identifier)
            if operation.state.isTerminal || operation.state == .paused { return operation }
            if operation.state == .cancelling {
                return try journal.transition(identifier, to: .cancelled, stage: "CANCELLED")
            }
            if operation.state == .queued {
                operation = try journal.transition(identifier, to: .running, stage: "STARTING")
            }
            do {
                return try execute(operation)
            } catch {
                let current = try journal.get(identifier)
                if current.state == .paused || current.state.isTerminal { return current }
                if current.state == .cancelling {
                    return try journal.transition(identifier, to: .cancelled, stage: "CANCELLED")
                }
                // An error after publication begins can be ambiguous. Keep a recoverable
                // running operation until the content store reconciles its stable ID.
                let publicationKinds: Set<OperationKind> = [.install, .uninstall, .repair, .garbageCollection]
                if !current.canCancel && publicationKinds.contains(current.kind)
                    && !Self.isPermanentRefusal(error) { throw error }
                return try journal.transition(
                    identifier, to: .failed, stage: "FAILED", error: String(describing: error))
            }
        }
    }

    func execute(_ operation: CatalogOperation) throws -> CatalogOperation {
        switch operation.kind {
        case .install: return try executeInstall(operation)
        case .uninstall: return try executeUninstall(operation)
        case .repair: return try executeRepair(operation)
        case .inventory: return try executeInventory(operation)
        case .garbageCollection: return try executeGarbageCollection(operation)
        case .discover: return try executeDiscovery(operation)
        case .fingerprint: return try executeFingerprint(operation)
        }
    }

    private func validate(_ plan: InstallPlan) throws {
        let request = InstallRequest(gameID: plan.gameID, installationID: plan.installationID,
                                     generationID: plan.generationID, layers: plan.layers, baseURLs: plan.baseURLs)
        guard plan.planID == "plan-" + StoreCatalog.digest(try StoreCatalog.encode(request)) else {
            throw InstallationError.corruptPlan(plan.planID)
        }
    }

    private static func isPermanentRefusal(_ error: any Error) -> Bool {
        guard let lifecycle = error as? ContentLifecycleError else { return false }
        switch lifecycle {
        case .staleReferences, .conflictingOperation, .abortedOperation, .pendingActivation: return true
        default: return false
        }
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw InstallationError.invalidIdentifier(value)
        }
    }

    func withWorkerLock<T>(_ action: () throws -> T) throws -> T {
        let descriptor = open(root.appendingPathComponent("worker.lock").path,
                              O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw OperationError.fileSystem("open worker lock", errno) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw OperationError.fileSystem("worker lock", errno) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
}
