import LDCore
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var logLines: [String]?
    @State private var follow = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                activeCard
                layers
                schedule
                command
                log
            }
            .padding(18)
        }
        .safeAreaInset(edge: .bottom) { footer }
        .task(id: job.id) { await tailLoop() }
    }

    var header: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: job.scope.isDaemon ? "server.rack" : "gearshape.2").font(.title3).foregroundStyle(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.title3.weight(.semibold))
                Text(job.label).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 6) {
                    Chip(text: job.scope.kind)
                    Chip(text: job.scope.domain, mono: true)
                    Chip(text: job.group.prefix(1).uppercased() + job.group.dropFirst(), tint: .accentColor)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder var activeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if job.scope.isReadOnly {
                Label("Apple job on the read-only system volume. You can start or stop it, but not change it.", systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Toggle(isOn: Binding(get: { !job.isDisabled && job.isLoaded }, set: { model.setActive($0, job) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep this job active").fontWeight(.semibold)
                        Text(activeExplanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            HStack(spacing: 8) {
                primaryButton
                Button("Run Once") { model.perform(.start, on: job) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    @ViewBuilder var primaryButton: some View {
        if job.status == .disabled || job.status == .notLoaded, !job.scope.isReadOnly {
            Button("Enable & Start") {
                model.perform(.enable, on: job)
                model.perform(.start, on: job)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        } else if job.pid != nil {
            Button("Restart") { model.perform(.restart, on: job) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        } else {
            Button("Start Now") { model.perform(.start, on: job) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    var activeExplanation: String {
        switch job.status {
        case .disabled: "Off — launchd won’t start it, not even at \(job.scope.isDaemon ? "boot" : "login")."
        case .notLoaded: "Enabled but not loaded — its triggers do nothing yet."
        case .running: "On — running now as PID \(job.pid ?? 0)."
        case .invalid: "launchd can’t load this plist."
        default: "On — launchd starts it: \(job.definition.schedule.summary.lowercased())."
        }
    }

    var layers: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Status at every layer")
            layerRow("Plist file", passed: job.definition.parseError == nil && job.definition.declaredLabel != nil,
                     value: job.definition.parseError == nil ? (job.definition.declaredLabel == nil ? "No Label key" : "Valid · \(Doctor.abbreviate(job.definition.url.deletingLastPathComponent().path))") : "Invalid")
            layerRow("launchd override", passed: job.override.map { !$0 }, value: job.override.map { $0 ? "Disabled" : "Enabled" } ?? "None (uses plist)")
            layerRow("Loaded", passed: job.isLoaded ? true : nil, value: job.isLoaded ? "Yes · \(job.target)" : "No")
            backgroundRow
            let program = Doctor.diagnose(job).checks.first { $0.id == "program" }
            layerRow("Program", passed: program?.passed, value: program?.passed == false ? (program?.note ?? "Problem") : (program?.passed == true ? "Exists, executable" : "—"))
            if let e = job.lastExit {
                layerRow("Last exit", passed: e == 0, value: ExitCode.short(e))
                    .help(ExitCode.explain(e))
            }
            if let r = job.runs { layerRow("Launches", passed: nil, value: r.formatted()) }
        }
    }

    @ViewBuilder var backgroundRow: some View {
        if let snap = model.background {
            let bg = job.background
            layerRow("Allow in the Background", passed: bg.map(\.isOn), value: bg?.summary ?? "Not listed")
                .help("Login Items & Extensions, as of \(snap.date.formatted(.relative(presentation: .named))). "
                      + (bg == nil ? "macOS hasn’t recorded this job yet; it usually appears after it first loads." : ""))
            if let bg, !bg.isOn {
                Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                    .controlSize(.small)
                    .padding(.leading, 22)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CheckMark(passed: nil).font(.callout)
                Text("Allow in the Background")
                Spacer(minLength: 12)
                Button(model.isCheckingBackground ? "Checking…" : "Check…") { model.checkLoginItems() }
                    .controlSize(.small)
                    .disabled(model.isCheckingBackground)
                    .help("Reads Login Items & Extensions. macOS asks for your password.")
            }
            .font(.callout)
        }
    }

    func layerRow(_ name: String, passed: Bool?, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CheckMark(passed: passed).font(.callout)
            Text(name)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
    }

    var schedule: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("When it runs")
            Text(job.definition.schedule.summary).font(.body.weight(.medium))
            let next = job.definition.schedule.nextRuns(count: 3)
            if !next.isEmpty {
                Text("Next: " + next.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if job.definition.startInterval != nil || !job.definition.calendarIntervals.isEmpty {
                Text("Runs missed while asleep happen once on wake.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var command: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Runs")
            Text(Shell.commandLine(job.definition.commandLine)
                .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }

    @ViewBuilder var log: some View {
        let paths = LogReader.logPaths(for: job)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(paths.first.map { "Log · \(($0 as NSString).lastPathComponent)" } ?? "Log")
                Spacer()
                if !paths.isEmpty {
                    Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).controlSize(.small)
                }
            }
            if paths.isEmpty {
                Text("No log file set. Output goes to the unified log; add a log file in Edit.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let lines = logLines {
                ScrollView(.horizontal) {
                    Text(lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(white: 0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Can’t read \(Doctor.abbreviate(paths[0])).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            Button("Edit…") { model.editorTarget = .edit(job) }
                .disabled(job.scope.isReadOnly)
            Button("Reveal in Finder") { model.reveal(job) }
            Menu {
                JobMenu(job: job)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.bar)
    }

    func tailLoop() async {
        let paths = LogReader.logPaths(for: job)
        guard let path = paths.first else { logLines = nil; return }
        while !Task.isCancelled {
            logLines = await Task.detached { LogReader.tail(path, lines: 14) }.value
            if !follow { break }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
