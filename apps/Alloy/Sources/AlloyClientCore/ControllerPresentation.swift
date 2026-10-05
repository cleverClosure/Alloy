// Author: Timur Isaev
import Foundation

extension RuntimeController {
    public var canUseSelectedFixture: Bool {
        guard let recipe, let selected = store.selectedGame else { return false }
        return selected.id == recipe.install.gameID && selected.builds.contains(recipe.expectedBuildID)
    }

    public var activeSessions: [SessionPresentation] { sessions.filter { !$0.finished } }

    public func dismissProblem() { problem = nil }

    public var supportSummary: String {
        let code = (problem ?? connectionProblem)?.supportCode ?? "OK"
        return "Alloy internal client\nConnection: \(store.snapshot.connected ? "connected" : "disconnected")\n" +
            "Local titles: \(store.snapshot.games.count)\nRuntime operations: \(operations.count)\n" +
            "Development sessions: \(sessions.count)\nSupport code: \(code)\nGame launch: unavailable"
    }

    func cachedActivities() -> [ClientActivity] {
        operations.map {
            ClientActivity(id: $0.id, title: $0.title, state: $0.state,
                           detail: "Last observed runtime operation", progress: $0.progress)
        } + sessions.map {
            ClientActivity(id: $0.id, title: "Native test session", state: $0.state,
                           detail: "Last observed live processes: \($0.snapshot.liveNodes.count)")
        }
    }
}
