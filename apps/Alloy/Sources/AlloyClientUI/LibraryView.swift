// Author: Timur Isaev
import AlloyClientCore
import SwiftUI

struct LibraryView: View {
    @Bindable var store: ClientStore
    let controller: RuntimeController
    @FocusState private var searchFocused: Bool
    var body: some View {
        Group {
            switch store.snapshot.phase {
            case .loading:
                VStack(spacing: 16) { ProgressView(); Text("Reading your local library…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                EmptyPanel(title: "Your library is empty",
                           detail: "No installed titles were found in the configured libraries.",
                           symbol: "square.stack")
            case .disconnected:
                EmptyPanel(title: "Connect to your local service",
                           detail: "Alloy needs its local runtime service to read your library and manage activity.",
                           symbol: "bolt.horizontal.circle")
            case .failed:
                if let problem = store.snapshot.problem { ProblemBanner(problem: problem) }
                Spacer()
            case .available, .unsupported:
                HSplitView {
                    gameList.frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
                    if let game = store.selectedGame { GameDetailView(game: game, controller: controller) } else {
                        EmptyPanel(title: "Choose a title",
                                   detail: "Select a title to see its installed build and runtime status.",
                                   symbol: "square.stack")
                    }
                }
            }
        }
        .toolbar {
            if !store.snapshot.games.isEmpty {
                Button("Search library", systemImage: "magnifyingglass") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }

    private var gameList: some View {
        VStack(spacing: 0) {
            TextField("Search library", text: $store.search)
                .textFieldStyle(.roundedBorder).padding(12)
                .accessibilityIdentifier("library.search").focused($searchFocused)
            if store.visibleGames.isEmpty {
                EmptyPanel(title: "No matches", detail: "Try a different title, status, or build.",
                           symbol: "magnifyingglass")
            } else {
                List(selection: Binding(get: { store.preferences.selectedGameID }, set: { store.select($0) })) {
                    ForEach(store.visibleGames) { game in
                        HStack(spacing: 12) {
                            Image(systemName: "gamecontroller").font(.title3).foregroundStyle(.secondary)
                                .frame(width: 34, height: 40).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name).fontWeight(.medium)
                                Text(game.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6).tag(game.id)
                    }
                }.listStyle(.inset).accessibilityIdentifier("library.titles")
            }
            Divider()
            Text("\(store.snapshot.games.count) local titles").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}

struct GameDetailView: View {
    let game: LibraryGame
    let controller: RuntimeController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tint).frame(width: 72, height: 72)
                        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(game.name).font(.title.weight(.semibold)).textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                        Text("Local installation").foregroundStyle(.secondary)
                        Label(game.status,
                              systemImage: game.unsupportedReason == nil ? "questionmark.circle" : "nosign")
                            .font(.callout.weight(.medium))
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Compatibility").font(.headline)
                    Text(game.unsupportedReason ?? "This installed build has no applicable compatibility evidence.")
                        .foregroundStyle(.secondary)
                    Text("No game launch is available in this internal build.").foregroundStyle(.secondary)
                    Button("Game launch unavailable", systemImage: "play.fill") {}.disabled(true)
                        .help("The local service has no game execution driver.")
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 16) {
                    GridRow {
                        Text("Installed build").foregroundStyle(.secondary)
                        Text(game.builds.joined(separator: ", "))
                    }
                    GridRow { Text("Installations").foregroundStyle(.secondary); Text("\(game.installationIDs.count)") }
                    GridRow {
                        Text("Runtime activity").foregroundStyle(.secondary)
                        Text(controller.runtimeActivity(for: game.id))
                    }
                }
                if controller.developmentEnabled { DevelopmentActions(controller: controller) }
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title ID: \(game.id)")
                        ForEach(game.installationIDs, id: \.self) { Text("Installation: \($0)") }
                        if let detail = controller.details, detail.summary.gameID == game.id {
                            ForEach(detail.installations, id: \.installationID) { installation in
                                Text("Build fingerprint: \(installation.fingerprint.aggregateSHA256)")
                            }
                        }
                    }.font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                Text("Manage title updates and repairs in your storefront.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("library.details")
    }
}
