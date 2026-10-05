// Author: Timur Isaev
import AlloyRuntimeAPI
import AlloyStoreCatalog
import Foundation

public struct OperationPresentation: Identifiable, Sendable {
    public let update: OperationUpdate
    public var id: String { update.snapshot.operationID }
    public var state: String { update.snapshot.state.rawValue.capitalized }
    public var title: String {
        switch update.snapshot.kind {
        case .install: "Install runtime"
        case .uninstall: "Remove runtime"
        case .repair: "Repair runtime"
        case .inventory: "Check runtime storage"
        case .garbageCollection: "Reclaim runtime storage"
        case .discover: "Discover installations"
        case .fingerprint: "Check installed build"
        }
    }
    public var progress: Double? {
        let progress = update.snapshot.progress
        if progress.bytesTotal > 0 { return min(1, Double(progress.bytesCompleted) / Double(progress.bytesTotal)) }
        if progress.totalUnits > 0 { return min(1, Double(progress.completedUnits) / Double(progress.totalUnits)) }
        return nil
    }
    public var canPause: Bool { update.snapshot.canPause && !update.snapshot.state.isTerminal }
    public var canCancel: Bool { update.snapshot.canCancel && !update.snapshot.state.isTerminal }
    public var canResume: Bool { update.snapshot.state == .paused && !update.workerActive }
    public var canRun: Bool {
        [.queued, .running].contains(update.snapshot.state) && !update.workerActive
    }
    public init(_ update: OperationUpdate) { self.update = update }
}

public struct SessionPresentation: Identifiable, Sendable {
    public let snapshot: SessionSnapshot
    public var id: String { snapshot.record.sessionID }
    public var finished: Bool {
        ["STOPPED", "SUCCEEDED", "FAILED", "INTERRUPTED"].contains(snapshot.state) && snapshot.liveNodes.isEmpty
    }
    public var state: String {
        if ["STOPPED", "SUCCEEDED", "FAILED", "INTERRUPTED"].contains(snapshot.state), !snapshot.liveNodes.isEmpty {
            return "Cleaning up"
        }
        return snapshot.state.capitalized
    }
    public init(_ snapshot: SessionSnapshot) { self.snapshot = snapshot }
}

extension ClientProblem {
    public static func service(_ error: any Error) -> Self {
        let code: String
        let explanation: String
        let next: String
        switch error {
        case ClientServiceError.changedBuild:
            code = "CLIENT-BUILD-CHANGED"
            explanation = "The installed build no longer matches the selected development fixture."
            next = "Refresh the library and supply a fixture for the exact installed build."
        case ClientServiceError.developmentOnly:
            code = "CLIENT-DEVELOPMENT-ONLY"
            explanation = "This action requires an explicit local development fixture and a fixture-enabled service."
            next = "Use the documented local fixture workflow. Game launch remains unavailable."
        case ClientServiceError.invalidResponse, is DecodingError:
            code = "CLIENT-CONTRACT"
            explanation = "The service returned an inconsistent or unsupported response."
            next = "Reconnect to a compatible local service. No new request is needed to recover existing activity."
        case RuntimeFailure.status(.unauthorized):
            code = "RT-UNAUTHORIZED"
            explanation = "The local service did not accept this endpoint's credentials."
            next = "Choose the current private endpoint file from the local service."
        case RuntimeFailure.status(.notFound):
            code = "RT-NOT_FOUND"
            explanation = "The selected runtime or installation is no longer available."
            next = "Refresh the library and review its current runtime activity before retrying."
        case RuntimeFailure.status(.notReady):
            code = "RT-LAUNCH_NOT_RUNTIME_READY"
            explanation = "This service cannot execute the selected game."
            next = "Use only the explicitly labeled development fixture workflow."
        case RuntimeFailure.status(let status):
            code = "RT-" + status.rawValue
            explanation = status == .conflict ? "The service rejected an outdated or conflicting request." :
                "The local service could not complete this request."
            next = "Refresh the current state before retrying. Keep the support code if the problem continues."
        case RuntimeFailure.invalidConfiguration:
            code = "CLIENT-ENDPOINT"
            explanation = "The selected service configuration is invalid or is not private to your account."
            next = "Choose the private endpoint file produced by the local service."
        case PreferencesError.unsafeStorage:
            code = "CLIENT-JOURNAL"
            explanation = "Alloy could not safely record the request before sending it."
            next = "Use a private, writable app state folder, then reopen Alloy."
        default:
            code = "RT-SERVICE_UNAVAILABLE"
            explanation = "The local service is unavailable. A submitted request may still be running."
            next = "Reconnect and refresh. Existing requests keep their identifiers when you retry."
        }
        return Self(title: "Action needs attention", explanation: explanation, nextStep: next, supportCode: code)
    }
}

extension RuntimeController {
    public func runtimeActivity(for gameID: String) -> String {
        for item in operations {
            let operation = item.update.snapshot
            if let plan = try? JSONDecoder().decode(InstallPlan.self, from: operation.payload), plan.gameID == gameID {
                return "Last " + item.title.lowercased() + ": " + item.state.lowercased()
            }
            if let plan = try? JSONDecoder().decode(UninstallPlan.self, from: operation.payload),
               plan.gameID == gameID {
                return "Last removal: " + item.state.lowercased()
            }
        }
        return "No runtime activity recorded"
    }
}
