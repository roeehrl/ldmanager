import LDCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LD Manager").fontWeight(.semibold)
                Spacer()
                Text("\(model.jobs.filter { $0.pid != nil }.count) running · \(model.jobs.count) jobs")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if let first = model.diagnoses.first {
                Button { open(.problems) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(model.diagnoses.count) problem\(model.diagnoses.count == 1 ? "" : "s")").fontWeight(.semibold)
                            Text("\(first.job.title): \(first.primary?.headline.lowercasedFirst ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            SectionLabel("Pinned").padding(.horizontal, 4)
            if model.pinnedJobs.isEmpty {
                Text("Right-click a job and choose Pin to Menu Bar.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.pinnedJobs) { job in
                        HStack(spacing: 10) {
                            StatusGlyph(status: job.status, size: 11)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(job.title)
                                Text(job.pid.map { "Running · PID \($0)" } ?? job.resultSummary + " · " + job.definition.schedule.summary.lowercased())
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Toggle(job.title, isOn: Binding(get: { !job.isDisabled && job.isLoaded }, set: { on in
                                // A system job may need to offer the helper first, which shows in the main window.
                                if job.scope.launchctlNeedsAdmin && model.helperState != .enabled { open(nil) }
                                model.setActive(on, job)
                            }))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                                .disabled(job.scope.isReadOnly)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 0) {
                menuButton("Open LD Manager", shortcut: "⌘O") { open(nil) }
                menuButton("New Job…", shortcut: "⌘N") {
                    open(nil)
                    model.editorTarget = .new
                }
                menuButton("Quit", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    func menuButton(_ title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func open(_ item: SidebarItem?) {
        if let item { model.sidebar = item }
        openWindow(id: "main")
        NSApp.activate()
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
