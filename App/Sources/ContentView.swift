import LDCore
import ServiceManagement
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
        } detail: {
            detail
                .navigationTitle(model.title)
                .navigationSubtitle(model.subtitle)
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search label, program, status:failed, key:WatchPaths")
        .toolbar { toolbar }
        .sheet(item: $model.privilegeRequest) { request in
            HelperPromptSheet(request: request)
                .environment(model)
        }
        .sheet(item: $model.editorTarget) { target in
            EditorView(target: target)
                .environment(model)
        }
        .confirmationDialog(model.confirmTrash.map { "Move \($0.title) to the Trash?" } ?? "",
                            isPresented: Binding(get: { model.confirmTrash != nil }, set: { if !$0 { model.confirmTrash = nil } }),
                            titleVisibility: .visible, presenting: model.confirmTrash) { job in
            Button("Unload and Move to Trash", role: .destructive) { model.trash(job) }
        } message: { job in
            Text("\(job.label) is unloaded and its plist moved to the Trash. A backup is kept in Recent Changes.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.updateHelperState()
        }
        .alert("Couldn’t complete that", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder var detail: some View {
        detailContent
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.helperBannerVisible && model.helperState != .enabled && model.helperState != .unsigned {
                    HelperBanner()
                }
            }
    }

    @ViewBuilder var detailContent: some View {
        switch model.sidebar {
        case .problems: DoctorView()
        case .recent: RecentChangesView()
        default:
            JobTableView()
                .inspector(isPresented: Binding(get: { model.showInspector }, set: { model.showInspector = $0 })) {
                    Group {
                        if let job = model.selectedJob {
                            InspectorView(job: job)
                        } else {
                            ContentUnavailableView("No Job Selected", systemImage: "square.stack.3d.up", description: Text("Select a job to see every layer of its state."))
                        }
                    }
                    .inspectorColumnWidth(min: 320, ideal: 372, max: 480)
                }
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        let job = model.selectedJob
        let tableMode = model.sidebar != .problems && model.sidebar != .recent
        if tableMode {
        ToolbarItemGroup {
            Button { if let job { model.perform(.start, on: job) } } label: { Label("Start", systemImage: "play.fill") }
                .help("Start (⌘R)")
                .disabled(job == nil)
            Button { if let job { model.perform(.stop, on: job) } } label: { Label("Stop", systemImage: "stop.fill") }
                .help("Stop (⌘.)")
                .disabled(job?.pid == nil)
            Button { if let job { model.perform(.restart, on: job) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .help("Restart (⇧⌘R)")
                .disabled(job == nil)
        }
        ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            Button { model.editorTarget = .new } label: { Label("New Job", systemImage: "plus") }
                .help("New job (⌘N)")
        }
        if tableMode {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide the inspector")
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.sidebar }, set: { if let v = $0 { model.sidebar = v } })) {
            Section {
                Label {
                    Text("Problems")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .badge(model.diagnoses.count)
                .tag(SidebarItem.problems)
                Label("Recent Changes", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.recent)
            }
            Section("Jobs") {
                Label("My Agents", systemImage: "person").badge(model.count(.user)).tag(SidebarItem.scope(.user))
                Label("All Users’ Agents", systemImage: "person.2").badge(model.count(.allUsers)).tag(SidebarItem.scope(.allUsers))
                Label("System Daemons", systemImage: "server.rack").badge(model.count(.system)).tag(SidebarItem.scope(.system))
                Label {
                    HStack {
                        Text("Apple")
                        Spacer()
                        Text("read-only").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock")
                }
                .tag(SidebarItem.apple)
            }
            if !model.groups.isEmpty {
                Section("Groups") {
                    ForEach(model.groups, id: \.name) { g in
                        Label {
                            Text(g.name.prefix(1).uppercased() + g.name.dropFirst())
                        } icon: {
                            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(groupColor(g.name))
                        }
                        .badge(g.count)
                        .tag(SidebarItem.group(g.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { HelperFooter().padding(.horizontal, 14).padding(.vertical, 10) }
    }

    func groupColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .green, .brown]
        return palette[abs(name.hashValue) % palette.count]
    }
}

// MARK: - Table

struct JobTableView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\JobRow.statusRank)]

    var body: some View {
        @Bindable var model = model
        let rows = model.visibleJobs.map(JobRow.init).sorted(using: sortOrder)
        Table(rows, selection: $model.selectedJobID, sortOrder: $sortOrder) {
            TableColumn("", value: \.statusRank) { row in
                StatusGlyph(status: row.job.status)
            }
            .width(26)
            TableColumn("Job", value: \.title) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).fontWeight(.medium).lineLimit(1)
                    Text(row.job.label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 3)
            }
            .width(min: 200, ideal: 300)
            TableColumn("When it runs", value: \.schedule) { row in
                Text(row.schedule).lineLimit(1)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Runs", value: \.runs) { row in
                Text(row.runs > 0 ? row.runs.formatted() : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 60)
            TableColumn("Result", value: \.result) { row in
                Text(row.result)
                    .foregroundStyle(row.job.resultColor)
                    .fontWeight(row.job.status == .failed || row.job.status == .invalid ? .medium : .regular)
                    .lineLimit(1)
                    .help(row.job.lastExit.map(ExitCode.explain) ?? row.result)
            }
            .width(min: 120, ideal: 180)
            TableColumn("PID", value: \.pidValue) { row in
                Text(row.job.pid.map(String.init) ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 60)
        }
        .contextMenu(forSelectionType: Job.ID.self) { ids in
            if let job = model.job(ids.first) { JobMenu(job: job) }
        } primaryAction: { ids in
            if let job = model.job(ids.first), !job.scope.isReadOnly { model.editorTarget = .edit(job) }
        }
        .overlay {
            if !model.hasLoaded {
                ProgressView("Reading launchd…")
            } else if rows.isEmpty {
                if model.search.isEmpty {
                    ContentUnavailableView("No Jobs", systemImage: "tray", description: Text(model.sidebar == .apple ? "Loading Apple’s jobs…" : "Nothing is installed here."))
                } else {
                    ContentUnavailableView.search(text: model.search)
                }
            }
        }
    }
}

/// Sortable projection of a job for the table.
struct JobRow: Identifiable {
    let job: Job
    let title: String
    let schedule: String
    let result: String

    init(_ job: Job) {
        self.job = job
        title = job.title
        schedule = job.definition.schedule.summary
        result = job.resultSummary
    }

    var id: Job.ID { job.id }
    var statusRank: Int { job.status.rank }
    var runs: Int { job.runs ?? 0 }
    var pidValue: Int { job.pid ?? 0 }
}

struct JobMenu: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        Button("Start", systemImage: "play") { model.perform(.start, on: job) }
        Button("Stop", systemImage: "stop") { model.perform(.stop, on: job) }.disabled(job.pid == nil)
        Button("Restart", systemImage: "arrow.clockwise") { model.perform(.restart, on: job) }
        Divider()
        if !job.scope.isReadOnly {
            Button(job.isDisabled ? "Enable" : "Disable", systemImage: job.isDisabled ? "power" : "pause.circle") { model.setActive(job.isDisabled, job) }
            Button(job.isLoaded ? "Unload" : "Load", systemImage: job.isLoaded ? "eject" : "tray.and.arrow.down") {
                model.perform(job.isLoaded ? .unload : .load, on: job)
            }
            Button("Edit…", systemImage: "pencil") { model.editorTarget = .edit(job) }
        }
        Divider()
        Button(model.pinned.contains(job.label) ? "Unpin from Menu Bar" : "Pin to Menu Bar", systemImage: "pin") { model.togglePin(job) }
        Button("Reveal in Finder", systemImage: "folder") { model.reveal(job) }
        Button("Copy Label", systemImage: "doc.on.doc") { model.copyLabel(job) }
        if !job.scope.isReadOnly {
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.confirmTrash = job }
        }
    }
}

/// Shows whether root operations go through the approved helper or prompt each time.
struct HelperFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: model.helperState == .enabled ? "checkmark.shield.fill" : "lock.shield")
                    .foregroundStyle(model.helperState == .enabled ? .green : .secondary)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            switch model.helperState {
            case .notInstalled, .notBundled:
                Button("Install Helper…") { model.setUpHelper(then: nil) }.controlSize(.small)
            case .needsApproval:
                Button("Show Me How…") { model.setUpHelper(then: nil) }.controlSize(.small)
            default:
                EmptyView()
            }
        }
        .help(help)
    }

    var text: String {
        switch model.helperState {
        case .enabled: "Helper approved · no password prompts"
        case .needsApproval: "Helper waiting for your approval"
        case .notInstalled, .notBundled: "System changes ask for your password"
        case .unsigned: "Unsigned build · system changes ask for your password"
        }
    }

    var help: String {
        switch model.helperState {
        case .enabled: "LD Manager’s helper handles system daemons and Login Items checks without asking for your password."
        case .needsApproval: "Turn on LD Manager under System Settings → General → Login Items → \(LoginItemsWording.section)."
        case .notInstalled: "Install the helper once to stop password prompts for system daemons and Login Items checks."
        case .notBundled: "This build doesn’t include the helper. Build with scripts/build-app.sh."
        case .unsigned: "The helper needs the app signed with a Developer ID or Apple Development certificate."
        }
    }
}
