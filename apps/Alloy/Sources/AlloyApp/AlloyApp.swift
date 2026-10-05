// Author: Timur Isaev
import AlloyClientCore
import AlloyClientUI
import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct AlloyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: ClientStore

    init() {
        let arguments = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let directory = option("--state-dir").map { URL(fileURLWithPath: $0) } ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AlloyInternal/Client", isDirectory: true)
        let fixture = option("--fixture").flatMap(LibraryPhase.init(rawValue:))
        let value = ClientStore(snapshot: fixture.map(ClientSnapshot.fixture) ?? ClientSnapshot(),
                                storage: PreferencesStore(directory: directory))
        if let appearance = option("--appearance").flatMap(ClientAppearance.init(rawValue:)) {
            value.preferences.appearance = appearance
        }
        _store = State(initialValue: value)
    }

    var body: some Scene {
        Window("Alloy", id: "main") { ClientWindow(store: store) }
            .defaultSize(width: 1120, height: 760)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandMenu("Navigate") {
                    ForEach(Array(ClientSection.allCases.enumerated()), id: \.element) { index, section in
                        Button(section.title) { store.preferences.section = section; store.savePreferences() }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    }
                }
            }
    }
}
