// Author: Timur Isaev
import AlloyClientCore
import AppKit
import SwiftUI

public struct ClientWindow: View {
    @Bindable private var store: ClientStore
    @Bindable private var controller: RuntimeController
    public init(store: ClientStore, controller: RuntimeController) {
        self.store = store
        self.controller = controller
    }

    public var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alloy").font(.title3.weight(.semibold))
                        Text("Internal build").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
                List(selection: $store.preferences.section) {
                    ForEach(ClientSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }.listStyle(.sidebar)
                Divider()
                Label(store.snapshot.preview ? "Interface preview" :
                        (store.snapshot.connected ? "Service connected" : "Service disconnected"),
                      systemImage: store.snapshot.connected && !store.snapshot.preview ?
                        "checkmark.circle" : "circle.dashed")
                    .font(.caption).foregroundStyle(.secondary).padding(16)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if store.snapshot.preview {
                    Label("Interface preview · Synthetic data · No runtime actions", systemImage: "eye")
                        .font(.caption).frame(maxWidth: .infinity).padding(8)
                        .background(.quaternary)
                }
                if let problem = controller.problem ?? controller.connectionProblem ?? store.persistenceProblem {
                    ProblemBanner(problem: problem)
                }
                if controller.developmentEnabled {
                    Label("Development fixture · Native test process only", systemImage: "hammer")
                        .font(.caption).frame(maxWidth: .infinity).padding(8).background(.quaternary)
                }
                switch store.preferences.section {
                case .library: LibraryView(store: store, controller: controller)
                case .activity: RuntimeActivityView(controller: controller)
                case .diagnostics: DiagnosticsView(store: store, controller: controller)
                case .settings: ClientSettingsView(store: store)
                }
            }
            .navigationTitle(store.preferences.section.title)
            .toolbar {
                if !store.snapshot.preview {
                    ToolbarItemGroup {
                        if controller.busy || controller.refreshing { ProgressView().controlSize(.small) }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await controller.refresh() } }
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(!controller.hasEndpoint || controller.busy || controller.refreshing)
                        Button("Connect", systemImage: "bolt.horizontal.circle") { chooseEndpoint() }
                            .disabled(controller.busy || controller.refreshing)
                    }
                }
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .preferredColorScheme(store.preferences.appearance == .system ? nil :
                                (store.preferences.appearance == .dark ? .dark : .light))
        .onChange(of: store.preferences) { _, _ in store.savePreferences() }
    }
    private func chooseEndpoint() {
        let panel = NSOpenPanel()
        panel.title = "Connect to local service"
        panel.message = "Choose the private endpoint JSON file created by the local runtime service."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.connect(endpoint: url.path) }
    }
}

struct ProblemBanner: View {
    let problem: ClientProblem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.title).font(.headline)
                Text(problem.explanation)
                Text(problem.nextStep).foregroundStyle(.secondary)
                Text(problem.supportCode).font(.caption.monospaced()).textSelection(.enabled)
            }
            Spacer()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary)
    }
}

struct EmptyPanel: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
