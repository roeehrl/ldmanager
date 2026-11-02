import LDCore
import SwiftUI

struct DoctorView: View {
    @Environment(AppModel.self) private var model
    @State private var showDismissed = false
    @State private var sortOrder = [KeyPathComparator(\ProblemRow.severityRank, order: .reverse)]

    var body: some View {
        @Bindable var model = model
        if model.diagnoses.isEmpty && model.dismissedDiagnoses.isEmpty {
            ContentUnavailableView {
                Label("No Problems", systemImage: "checkmark.seal")
            } description: {
                Text("Every job passed the Doctor’s checks.")
            } actions: {
                Button("Check Again") { Task { await model.refresh() } }
            }
        } else {
            let rows = (model.diagnoses.map { ProblemRow($0, dismissed: false, result: model.resultText(for: $0.job)) }
                + (showDismissed ? model.dismissedDiagnoses.map { ProblemRow($0, dismissed: true, result: model.resultText(for: $0.job)) } : []))
                .sorted(using: sortOrder)
            Table(rows, selection: $model.selectedProblemID, sortOrder: $sortOrder) {
                TableColumn("", value: \.severityRank) { row in
                    ProblemGlyph(row: row)
                }
                .width(26)
                TableColumn("Job", value: \.title) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).fontWeight(.medium).lineLimit(1)
                        Text(row.job.label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 3)
                    .opacity(row.dismissed ? 0.6 : 1)
                }
                .width(min: 140, ideal: 220)
                TableColumn("Problem", value: \.headline) { row in
                    Text(row.headline)
                        .lineLimit(1)
                        .foregroundStyle(row.dismissed ? .secondary : .primary)
                        .help(row.diagnosis.primary?.detail ?? row.headline)
                }
                .width(min: 160, ideal: 300)
                TableColumn("When it runs", value: \.schedule) { row in
                    Text(row.schedule).lineLimit(1).opacity(row.dismissed ? 0.6 : 1)
                }
                .width(min: 90, ideal: 140)
                TableColumn("Result", value: \.result) { row in
                    Text(row.result)
                        .foregroundStyle(row.dismissed ? .secondary : model.resultColor(row.job))
                        .lineLimit(1)
                        .help(row.job.lastExit.map(ExitCode.explain) ?? row.result)
                }
                .width(min: 80, ideal: 130)
            }
            .contextMenu(forSelectionType: Diagnosis.ID.self) { ids in
                if let row = rows.first(where: { $0.id == ids.first }) {
                    if row.dismissed {
                        Button("Restore", systemImage: "tray.and.arrow.up") { model.restore(row.diagnosis) }
                    } else {
                        Button("Dismiss", systemImage: "archivebox") { model.dismiss(row.diagnosis) }
                    }
                    Divider()
                    JobMenu(job: row.job)
                }
            } primaryAction: { ids in
                if let row = rows.first(where: { $0.id == ids.first }), !row.job.scope.isReadOnly { model.editorTarget = .edit(row.job) }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Needs Attention", systemImage: "checkmark.seal")
                    } description: {
                        Text("You dismissed \(model.dismissedDiagnoses.count == 1 ? "the only problem" : "every problem"). Dismissed problems don’t count in the menu bar.")
                    } actions: {
                        Button("Show Dismissed") { showDismissed = true }
                    }
                }
            }
            .inspector(isPresented: Binding(get: { model.showInspector }, set: { model.showInspector = $0 })) {
                Group {
                    let all = model.diagnoses + model.dismissedDiagnoses
                    if let d = all.first(where: { $0.id == model.selectedProblemID }) {
                        ProblemDetail(diagnosis: d)
                    } else {
                        ContentUnavailableView("No Problem Selected", systemImage: "stethoscope",
                                               description: Text("Select a problem to see the Doctor’s checks and how to fix it."))
                    }
                }
                .inspectorColumnWidth(min: 340, ideal: 420, max: 560)
            }
            .toolbar {
                if !model.dismissedDiagnoses.isEmpty {
                    ToolbarItem {
                        Toggle(isOn: $showDismissed) {
                            Label("Show Dismissed (\(model.dismissedDiagnoses.count))", systemImage: "archivebox")
                        }
                        .help(showDismissed ? "Hide the problems you dismissed" : "Also list the \(model.dismissedDiagnoses.count) problem\(model.dismissedDiagnoses.count == 1 ? "" : "s") you dismissed")
                    }
                }
                ToolbarItem {
                    Button { model.checkLoginItems() } label: {
                        Label(model.isCheckingBackground ? "Checking Login Items…" : "Check Login Items…", systemImage: "person.badge.key")
                    }
                    .disabled(model.isCheckingBackground)
                    .help(model.background.map { "Login Items last read \($0.date.formatted(.relative(presentation: .named))). Checking again asks for your password." }
                          ?? "Also check App Background Activity. macOS asks for your password.")
                }
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                        .help("Run the Doctor’s checks again")
                }
            }
        }
    }
}

/// Sortable projection of a diagnosis for the Problems table.
struct ProblemRow: Identifiable {
    let diagnosis: Diagnosis
    let dismissed: Bool
    let title: String
    let headline: String
    let schedule: String
    let result: String

    init(_ diagnosis: Diagnosis, dismissed: Bool, result: String) {
        self.diagnosis = diagnosis
        self.dismissed = dismissed
        title = diagnosis.job.title
        headline = diagnosis.primary?.headline ?? ""
        schedule = diagnosis.job.definition.schedule.summary
        self.result = result
    }

    var id: Diagnosis.ID { diagnosis.id }
    var job: Job { diagnosis.job }
    /// Errors first, then warnings; dismissed problems last.
    var severityRank: Int { dismissed ? -1 : (diagnosis.worst?.rawValue ?? 0) }
}

/// Shape plus color, like the jobs table's status glyph.
struct ProblemGlyph: View {
    let row: ProblemRow

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 19)
            .help(title)
            .accessibilityLabel(title)
    }

    var symbol: String {
        if row.dismissed { return "archivebox" }
        if row.job.status == .invalid { return "questionmark.diamond.fill" }
        return row.diagnosis.worst == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle"
    }

    var color: Color {
        if row.dismissed { return .secondary }
        return row.job.status == .invalid ? .purple : .orange
    }

    var title: String {
        if row.dismissed { return "Dismissed" }
        return row.diagnosis.worst == .error ? "Error" : "Warning"
    }
}

struct ProblemDetail: View {
    @Environment(AppModel.self) private var model
    let diagnosis: Diagnosis

    var job: Job { diagnosis.job }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(job.title)
                        Text("·")
                        Text(job.target).font(.caption.monospaced())
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let p = diagnosis.primary {
                        Text(p.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if let at = diagnosis.dismissedAt(model.dismissals) {
                            Button("Restore", systemImage: "tray.and.arrow.up") { model.restore(diagnosis) }
                                .help("Count this problem again and show it in the menu bar")
                            Text("Dismissed \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Dismiss", systemImage: "archivebox") { model.dismiss(diagnosis) }
                                .help("Stop counting this problem. It comes back if the job develops a different problem.")
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    StatCard(title: "Last result", value: job.lastExit.map { $0 == 0 ? "OK" : ($0 < 0 ? ExitCode.short($0) : "Exit \($0)") } ?? "—",
                             note: job.lastExit.map { ExitCode.short($0) } ?? job.status.title, alert: (job.lastExit ?? 0) != 0)
                    StatCard(title: "Launches since load", value: job.runs.map { $0.formatted() } ?? "—", note: job.definition.schedule.summary, alert: false)
                    StatCard(title: "launchd state", value: job.detail?.state?.capitalized ?? (job.isLoaded ? "Loaded" : "Not loaded"), note: job.status.title, alert: false)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Checks")
                    VStack(spacing: 0) {
                        ForEach(diagnosis.checks) { c in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                CheckMark(passed: c.passed)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name)
                                    if let n = c.note {
                                        Text(n).font(.caption).foregroundStyle(c.passed == false ? .orange : .secondary)
                                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(c.passed == false ? Color.orange.opacity(0.07) : .clear)
                            if c.id != diagnosis.checks.last?.id { Divider() }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                let fixes = uniqueFixes
                if !fixes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Fix it")
                        VStack(spacing: 8) {
                            ForEach(Array(fixes.enumerated()), id: \.offset) { i, fix in
                                Button { model.apply(fix, to: job) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(fix.title).fontWeight(.semibold).foregroundStyle(i == 0 ? Color.accentColor : .primary)
                                        Text(fix.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(10)
                                    .background(i == 0 ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(i == 0 ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: i == 0 ? 1.5 : 1))
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isBusy(job))
                            }
                        }
                        // What the fix is doing, or how it ended.
                        if let op = model.operations[job.id] {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(op.phase).font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let outcome = model.outcomes[job.id] {
                            OutcomeLine(job: job, outcome: outcome)
                        }
                    }
                }

                if let raw = job.detail?.raw, !raw.isEmpty {
                    DisclosureGroup("Evidence — launchctl print") {
                        Text(evidence(raw))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                }
            }
            .padding(18)
        }
    }

    var headline: String {
        guard let h = diagnosis.primary?.headline else { return job.title }
        let lowered = h.prefix(1).lowercased() + h.dropFirst()
        return h.hasPrefix("Its ") || h.hasPrefix("It ") ? "\(job.title): \(lowered)" : h
    }

    var uniqueFixes: [Fix] {
        var seen: [Fix] = []
        for f in diagnosis.findings.filter({ $0.severity >= .warning }).flatMap(\.fixes) where !seen.contains(f) {
            if job.scope.isReadOnly, f != .revealPlist { continue }
            seen.append(f)
        }
        return seen
    }

    func evidence(_ raw: String) -> String {
        raw.split(separator: "\n")
            .filter { $0.hasPrefix("\t") && !$0.hasPrefix("\t\t") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in ["state", "runs", "pid", "last exit", "program", "path", "type", "last terminating"].contains { line.hasPrefix($0) } }
            .joined(separator: "\n")
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let note: String
    let alert: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(alert ? .orange : .primary)
            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

struct RecentChangesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: PlistEditor.Backup.ID?
    @State private var confirmRestore: PlistEditor.Backup?

    var body: some View {
        if model.backups.isEmpty {
            ContentUnavailableView("No Changes Yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Every time LD Manager or ldm saves a job, the previous version is kept here."))
        } else {
            Table(model.backups, selection: $selection) {
                TableColumn("Job") { b in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Job.title(for: b.label)).fontWeight(.medium)
                        Text(b.label).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Saved") { b in Text(b.date.formatted(date: .abbreviated, time: .shortened)) }
                    .width(min: 140, ideal: 180)
                TableColumn("") { b in
                    HStack {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }
                        Button("Restore…") { confirmRestore = b }.disabled(b.originalPath == nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .width(150)
            }
            .confirmationDialog(confirmRestore.map { "Restore \(Job.title(for: $0.label)) to this version?" } ?? "",
                                isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                                titleVisibility: .visible, presenting: confirmRestore) { b in
                Button("Restore") { model.restore(b) }
            } message: { b in
                Text("The job goes back to how it was before \(b.date.formatted(date: .abbreviated, time: .shortened)) and is reloaded if loaded. The current version is backed up first, so you can undo this.")
            }
        }
    }
}
