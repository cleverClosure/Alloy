// Author: Timur Isaev
import AlloyClientCore
import SwiftUI

struct ActivityView: View {
    let store: ClientStore
    var body: some View {
        if store.snapshot.activities.isEmpty {
            EmptyPanel(title: "No runtime activity",
                       detail: "Downloads and development sessions appear here when available.",
                       symbol: "arrow.down.circle")
        } else {
            List(store.snapshot.activities) { activity in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(activity.title).font(.headline); Spacer(); Text(activity.state) }
                    Text(activity.detail).foregroundStyle(.secondary)
                    if let progress = activity.progress {
                        ProgressView(value: progress).accessibilityLabel("Runtime progress")
                    }
                    Text(activity.id).font(.caption.monospaced()).textSelection(.enabled)
                }.padding(12)
            }
        }
    }
}

struct DiagnosticsView: View {
    let store: ClientStore
    let controller: RuntimeController
    var body: some View {
        Form {
            Section("Local status") {
                LabeledContent("Connection", value: store.snapshot.serviceDescription)
                LabeledContent("Library", value: store.snapshot.phase.rawValue.capitalized)
                LabeledContent("Game launch", value: "Unavailable")
            }
            if let problem = controller.problem ?? controller.connectionProblem ?? store.persistenceProblem {
                Section("Attention needed") { ProblemBanner(problem: problem) }
            }
            Section("Privacy") {
                Text("Status stays on this Mac. Alloy does not upload diagnostic data.")
                Text("A diagnostics bundle is not available in this build.").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).textSelection(.enabled)
    }
}

struct ClientSettingsView: View {
    @Bindable var store: ClientStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $store.preferences.appearance) {
                    ForEach(ClientAppearance.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.accessibilityIdentifier("settings.appearance")
                Toggle("Reduce motion", isOn: $store.preferences.reduceMotion)
                Text(systemReduceMotion ? "Reduce Motion is also enabled in macOS." :
                        "Alloy respects the macOS Reduce Motion setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local service") {
                LabeledContent("Connection", value: store.snapshot.serviceDescription)
                Text("The service controls library access and runtime storage. " +
                     "Credentials are never saved in app preferences.")
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Alloy", value: "Internal development build")
                Text("Discovery is not a compatibility certification. Runtime fixtures do not launch games.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
