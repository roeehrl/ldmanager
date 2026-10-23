import LDCore
import SwiftUI

struct DoctorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.diagnoses.isEmpty {
            ContentUnavailableView {
                Label("No Problems", systemImage: "checkmark.seal")
            } description: {
                Text("Every job passed the Doctor’s checks.")
            } actions: {
                Button("Check Again") { Task { await model.refresh() } }
            }
        } else {
            HSplitView {
                List(model.diagnoses, selection: $model.selectedProblemID) { d in
                    ProblemRow(diagnosis: d).tag(d.id)
                }
                .listStyle(.inset)
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 460)
                .safeAreaInset(edge: .bottom) {
                    Text("The Doctor checks plists, programs, permissions, quarantine, log folders, restart loops and launchd state"
                         + (model.background == nil ? ". Use Check Login Items to include App Background Activity." : ", plus App Background Activity."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Group {
                    if let d = model.diagnoses.first(where: { $0.id == model.selectedProblemID }) ?? model.diagnoses.first {
                        ProblemDetail(diagnosis: d)
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
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
                }
            }
        }
    }
}

struct ProblemRow: View {
    let diagnosis: Diagnosis

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: diagnosis.worst == .error ? (diagnosis.job.status == .invalid ? "questionmark.diamond.fill" : "exclamationmark.triangle.fill") : "exclamationmark.circle")
                .foregroundStyle(diagnosis.job.status == .invalid ? .purple : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnosis.job.title).font(.caption).foregroundStyle(.secondary)
                Text(diagnosis.primary?.headline ?? "").font(.body.weight(.semibold))
                Text(diagnosis.job.resultSummary + " · " + diagnosis.job.definition.schedule.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

struct ProblemDetail: View {
    @Environment(AppModel.self) private var model
    let diagnosis: Diagnosis

    var job: Job { diagnosis.job }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(job.title)
                        Text("·")
                        Text(job.target).font(.caption.monospaced())
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(headline).font(.title2.weight(.bold))
                    if let p = diagnosis.primary {
                        Text(p.detail).font(.body).foregroundStyle(.secondary).frame(maxWidth: 680, alignment: .leading)
                    }
                }

                HStack(spacing: 12) {
                    StatCard(title: "Last result", value: job.lastExit.map { $0 == 0 ? "OK" : ($0 < 0 ? ExitCode.short($0) : "Exit \($0)") } ?? "—",
                             note: job.lastExit.map { ExitCode.short($0) } ?? job.status.title, alert: (job.lastExit ?? 0) != 0)
                    StatCard(title: "Launches since load", value: job.runs.map { $0.formatted() } ?? "—", note: job.definition.schedule.summary, alert: false)
                    StatCard(title: "launchd state", value: job.detail?.state?.capitalized ?? (job.isLoaded ? "Loaded" : "Not loaded"), note: job.status.title, alert: false)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Checks")
                    VStack(spacing: 0) {
                        ForEach(diagnosis.checks) { c in
                            HStack(spacing: 10) {
                                CheckMark(passed: c.passed)
                                Text(c.name)
                                Spacer()
                                if let n = c.note {
                                    Text(n).font(.caption.monospaced()).foregroundStyle(c.passed == false ? .orange : .secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
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
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                            ForEach(Array(fixes.enumerated()), id: \.offset) { i, fix in
                                Button { model.apply(fix, to: job) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(fix.title).fontWeight(.semibold).foregroundStyle(i == 0 ? Color.accentColor : .primary)
                                        Text(fix.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                                    .padding(12)
                                    .background(i == 0 ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(i == 0 ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: i == 0 ? 1.5 : 1))
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
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
            .padding(28)
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
                        Button("Restore") { model.restore(b) }.disabled(b.originalPath == nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .width(150)
            }
        }
    }
}
