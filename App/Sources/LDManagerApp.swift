import LDCore
import SwiftUI

@main
struct LDManagerApp: App {
    @State private var model: AppModel
    @State private var updater: AppUpdater
    /// After a silent update the app comes back to the menu bar only, as it was.
    private let relaunchedForUpdate: Bool

    init() {
        let model = AppModel()
        let updater = AppUpdater()
        updater.model = model
        _model = State(initialValue: model)
        _updater = State(initialValue: updater)
        relaunchedForUpdate = AppUpdater.consumeRelaunchFlag()
    }

    var body: some Scene {
        Window("LD Manager", id: "main") {
            ContentView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 860)
        .defaultLaunchBehavior(relaunchedForUpdate ? .suppressed : .automatic)
        .commands {
            JobCommands(model: model)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .environment(updater)
        } label: {
            Image(systemName: updater.pendingVersion != nil ? "arrow.down.circle"
                  : model.diagnoses.isEmpty ? "square.stack.3d.up" : "square.stack.3d.up.trianglebadge.exclamationmark")
        }
        .menuBarExtraStyle(.window)
    }
}

struct JobCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Job…") { model.editorTarget = .new }
                .keyboardShortcut("n")
        }
        CommandMenu("Job") {
            let job = model.selectedJob
            Button(job?.status == .restarting ? "Start Now" : "Start") { if let job { model.start(job) } }
                .keyboardShortcut("r")
                .disabled(job.map { !model.canStart($0) } ?? true)
            Button("Stop") { if let job { model.perform(.stop, on: job) } }
                .keyboardShortcut(".")
                .disabled(job.map { !model.canStop($0) } ?? true)
            Button("Force Quit") { if let job { model.forceQuit(job) } }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(job.map { !model.canForceQuit($0) } ?? true)
            Button("Restart") { if let job { model.perform(.restart, on: job) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(job.map { !model.canRestart($0) } ?? true)
            if let job { SignalMenu(job: job) }
            Divider()
            Button(job?.isDisabled == true ? "Enable" : "Disable") {
                if let job { model.setActive(job.isDisabled, job) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(job == nil || job?.scope.isReadOnly == true || job.map(model.isBusy) == true || model.isSheetOpen)
            Button("Edit…") { if let job { model.editorTarget = .edit(job) } }
                .keyboardShortcut("e")
                .disabled(job == nil || job?.scope.isReadOnly == true)
            Button("Reveal in Finder") { if let job { model.reveal(job) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(job == nil)
            Button(job.map { model.pinned.contains($0.label) } == true ? "Unpin from Menu Bar" : "Pin to Menu Bar") {
                if let job { model.togglePin(job) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(job == nil)
            Divider()
            Button("Move to Trash…") { if let job { model.confirmTrash = job } }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(job == nil || job?.scope.isReadOnly == true || job.map(model.isBusy) == true || model.isSheetOpen)
            Divider()
            Button("Refresh") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .control])
        }
    }
}
