import LDCore
import SwiftUI

@main
struct LDManagerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("LD Manager", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 860)
        .commands { JobCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.diagnoses.isEmpty ? "square.stack.3d.up" : "square.stack.3d.up.trianglebadge.exclamationmark")
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
            Button("Start") { if let job { model.perform(.start, on: job) } }
                .keyboardShortcut("r")
                .disabled(job == nil)
            Button("Stop") { if let job { model.perform(.stop, on: job) } }
                .keyboardShortcut(".")
                .disabled(job?.pid == nil)
            Button("Restart") { if let job { model.perform(.restart, on: job) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(job == nil)
            Divider()
            Button(job?.isDisabled == true ? "Enable" : "Disable") {
                if let job { model.setActive(job.isDisabled, job) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(job == nil || job?.scope.isReadOnly == true)
            Button("Edit…") { if let job { model.editorTarget = .edit(job) } }
                .keyboardShortcut("e")
                .disabled(job == nil || job?.scope.isReadOnly == true)
            Button("Reveal in Finder") { if let job { model.reveal(job) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(job == nil)
            Divider()
            Button("Refresh") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .control])
        }
    }
}
