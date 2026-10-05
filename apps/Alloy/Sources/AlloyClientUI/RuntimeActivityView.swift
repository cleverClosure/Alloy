// Author: Timur Isaev
import AlloyClientCore
import SwiftUI

struct RuntimeActivityView: View {
    let controller: RuntimeController
    var body: some View {
        VStack(spacing: 0) {
            if controller.operations.isEmpty && controller.sessions.isEmpty {
                EmptyPanel(title: "No runtime activity",
                           detail: "Runtime operations and development sessions appear here.",
                           symbol: "arrow.down.circle")
            } else {
                List {
                    if !controller.sessions.isEmpty {
                        Section("Development sessions") {
                            ForEach(controller.sessions) { session in sessionRow(session) }
                        }
                    }
                    Section("Runtime operations") {
                        ForEach(controller.operations) { operation in operationRow(operation) }
                    }
                }.listStyle(.inset)
            }
            HStack {
                Text(controller.store.snapshot.connected ? "Live service snapshots" :
                        "Last known state · Reconnect to update")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check runtime storage") { Task { await controller.checkStorage() } }
                    .disabled(!canAct)
            }.padding(16)
        }
    }

    private var canAct: Bool {
        controller.store.snapshot.connected && !controller.store.snapshot.preview &&
            !controller.busy && !controller.refreshing
    }

    private func operationRow(_ operation: OperationPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(operation.title, systemImage: "arrow.down.circle").font(.headline)
                Spacer()
                Text(operation.state).font(.callout.weight(.medium))
            }
            if let progress = operation.progress {
                ProgressView(value: progress).accessibilityLabel(operation.title + " progress")
            }
            HStack {
                if operation.canPause { operationButton("Pause", operation.id, "pause") }
                if operation.canResume { operationButton("Resume", operation.id, "resume") }
                if operation.canRun { operationButton("Continue same request", operation.id, "run") }
                if operation.canCancel { operationButton("Cancel", operation.id, "cancel") }
            }.disabled(!canAct)
            if operation.update.snapshot.state.rawValue == "FAILED" {
                Text("The runtime operation failed. Refresh its state before starting another request.")
                    .foregroundStyle(.secondary)
                Text("RT-OPERATION_FAILED").font(.caption.monospaced())
            }
            DisclosureGroup("Operation details") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(operation.id)
                    Text("Stage: " + operation.update.snapshot.stage)
                    Text("Revision: \(operation.update.revision)")
                    Text("Downloaded: \(operation.update.snapshot.progress.bytesCompleted) bytes")
                }.font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.vertical, 12)
    }

    private func operationButton(_ title: String, _ identifier: String, _ command: String) -> some View {
        Button(title) { Task { await controller.control(identifier, command: command) } }
            .accessibilityLabel(title + " runtime operation")
    }

    private func sessionRow(_ session: SessionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Native test session", systemImage: "hammer").font(.headline)
                Spacer()
                Text(session.state).font(.callout.weight(.medium))
            }
            Text("Development fixture · \(session.snapshot.liveNodes.count) live processes")
                .foregroundStyle(.secondary)
            if !session.finished {
                Button("Stop development session") { Task { await controller.stopSession(session.id) } }
                    .disabled(!canAct)
            }
            Text(session.id).font(.caption.monospaced()).textSelection(.enabled)
        }.padding(.vertical, 12)
    }
}

struct DevelopmentActions: View {
    let controller: RuntimeController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Development fixture", systemImage: "hammer").font(.headline)
            Text("Uses a supplied test runtime and a bounded native process. This does not launch the selected game.")
                .foregroundStyle(.secondary)
            Button("Plan test runtime") { Task { await controller.prepareInstall() } }
            if let plan = controller.plan {
                Text("Test runtime: \(plan.requiredObjectBytes) bytes required").font(.callout)
                Button("Install test runtime") { Task { await controller.installRuntime() } }
                    .accessibilityIdentifier("development.install")
            }
            Button("Start development session") { Task { await controller.startDevelopmentSession() } }
                .accessibilityIdentifier("development.start-session")
        }.disabled(!controller.store.snapshot.connected || controller.busy || controller.refreshing)
    }
}
