import LDCore
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let job: Job
    @State private var logLines: [String]?
    @State private var follow = true
    @State private var logModified: Date?

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
        let op = model.operations[job.id]
        VStack(alignment: .leading, spacing: 12) {
            if job.scope.isReadOnly {
                Label("Apple job on the read-only system volume. You can start or stop it, but not change it.", systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .center) {
                    // The switch is the "for good" control: a temporary Stop never flips it.
                    Toggle(isOn: Binding(get: { switchIsOn(op) }, set: { model.setActive($0, job) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep this job active").fontWeight(.semibold)
                            Text(activeExplanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(op != nil || job.status == .invalid || job.status == .placeholder)
                    if op?.kind == .turnOn || op?.kind == .turnOff {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            buttons(op)
            statusSlot(op)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    func switchIsOn(_ op: JobOperation?) -> Bool {
        switch op?.kind {
        case .turnOn: true
        case .turnOff, .keepOff: false
        default: !job.isDisabled
        }
    }

    @ViewBuilder func buttons(_ op: JobOperation?) -> some View {
        let layout = model.layout(for: job)
        let stopping = op?.kind == .stop || (op == nil && job.status == .stopping)
        if layout.primary != nil || layout.showsStop || op?.canForceQuit == true {
            HStack(spacing: 8) {
                if let primary = layout.primary {
                    let running = op.map { $0.kind == primary.kind || (primary == .enableAndStart && $0.kind == .start) } ?? false
                    Button { model.perform(primary.kind, on: job) } label: {
                        busyLabel(running ? (op?.kind.progressWord ?? primary.title) : primary.title, busy: running)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(op != nil || stopping)
                    .accessibilityLabel("\(primary.title) \(job.title)")
                }
                if layout.showsStop {
                    Button { model.perform(.stop, on: job) } label: {
                        busyLabel(stopping ? "Stopping…" : "Stop", busy: stopping)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(op != nil || stopping)
                    .help(stopHelp)
                    .accessibilityLabel("Stop \(job.title)")
                    .accessibilityHint(stopHelp)
                }
                if op?.canForceQuit == true {
                    Button { model.forceQuit(job) } label: { busyLabel("Force Quit", busy: op?.forceQuitSent == true) }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.large)
                        .disabled(op?.forceQuitSent == true)
                        .help("Send SIGKILL: it quits at once, without cleaning up (⌥⌘.)")
                }
            }
        }
    }

    func busyLabel(_ title: String, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.mini) }
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }

    var stopHelp: String {
        job.restartsOnItsOwn
            ? "Stops it and unloads it until you click Start or log in again, so launchd doesn’t restart it. To keep it off for good, turn off Keep this job active. (⌘.)"
            : "Sends SIGTERM and waits for it to quit (⌘.)"
    }

    /// What is happening now, or how the last action ended.
    @ViewBuilder func statusSlot(_ op: JobOperation?) -> some View {
        if let op {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).accessibilityLabel(op.phase)
                Text(op.phase).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else if let outcome = model.outcomes[job.id] {
            OutcomeLine(job: job, outcome: outcome)
        }
    }

    var activeExplanation: String {
        let login = job.scope.isDaemon ? "boot" : "login"
        if model.isStoppedByRequest(job) {
            return "On, but stopped until you click Start or " + (job.scope.isDaemon ? "restart the Mac." : "log in again.")
        }
        if job.isDisabled && job.isLoaded {
            return "Off — still loaded until you log out; launchd won’t start it again."
        }
        switch job.status {
        case .disabled: return "Off — launchd won’t start it, not even at \(login)."
        case .notLoaded: return "On, but not loaded right now — it loads at your next \(login). Click Start to load it now."
        case .running:
            let pid = job.pid ?? 0
            if job.launchdState == .spawning { return "On — starting as PID \(pid)." }
            return "On — running now as PID \(pid)." + (job.restartsOnItsOwn ? " launchd restarts it if it quits." : "")
        case .stopping: return "On — waiting for PID \(job.pid ?? 0) to quit."
        case .restarting:
            let t = job.definition.throttleInterval
            return "On — launchd starts it again within \(t) s (it allows one start every \(t) s)."
        case .invalid: return "launchd can’t load this plist."
        case .placeholder: return "This file defines no job, so there’s nothing to run."
        default:
            if job.definition.contentsUnknown { return "On — LD Manager can’t read its plist, so when it runs is unknown." }
            return "On — launchd starts it: \(job.definition.schedule.summaryInSentence)."
                + (isShortLived ? " Each run is brief, so it’s normally not running in between." : "")
        }
    }

    /// Scheduled or one-shot jobs that aren't meant to stay up.
    var isShortLived: Bool {
        (job.definition.keepAlive == nil || job.definition.keepAlive == .never) && job.pid == nil
            && (job.definition.startInterval != nil || !job.definition.calendarIntervals.isEmpty || !job.definition.watchPaths.isEmpty)
    }

    var layers: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Status at every layer")
            layerRow("Plist file", passed: plistState.passed, value: plistState.text)
            layerRow("launchd override", passed: job.override.map { !$0 }, value: job.override.map { $0 ? "Disabled" : "Enabled" } ?? "None (uses plist)")
            layerRow("Loaded", passed: job.isLoaded ? true : nil, value: job.isLoaded ? "Yes · \(job.target)" : "No")
            layerRow("launchd state", passed: nil, value: job.detail?.state ?? (job.isLoaded ? "—" : "not loaded"))
            backgroundRow
            let program = Doctor.diagnose(job).checks.first { $0.id == "program" }
            layerRow("Program", passed: program?.passed, value: program?.passed == false ? (program?.note ?? "Problem") : (program?.passed == true ? "Exists, executable" : "—"))
            if let e = job.lastExit {
                layerRow("Last exit", passed: !ExitCode.isFailure(e), value: ExitCode.short(e))
                    .help(ExitCode.explain(e))
            }
            if let r = job.runs { layerRow("Launches", passed: nil, value: r.formatted()) }
        }
    }

    @ViewBuilder var backgroundRow: some View {
        if let snap = model.background {
            let bg = job.background
            layerRow("App Background Activity", passed: bg.map(\.isOn), value: bg?.summary ?? "Not listed")
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
                Text("App Background Activity")
                Spacer(minLength: 12)
                Button(model.isCheckingBackground ? "Checking…" : "Check…") { model.checkLoginItems() }
                    .controlSize(.small)
                    .disabled(model.isCheckingBackground)
                    .help(model.helperState == .enabled ? "Reads Login Items & Extensions." : "Reads Login Items & Extensions. macOS asks for your password.")
            }
            .font(.callout)
        }
    }

    var plistState: (passed: Bool?, text: String) {
        let def = job.definition
        if def.unreadable { return (nil, "Root-only · launchd reads it, LD Manager can’t") }
        if def.lenientOnly { return (nil, "launchd reads it · LD Manager can’t check it") }
        if def.isEmptyPlaceholder { return (nil, "Empty placeholder · defines no job") }
        if def.parseError != nil { return (false, "Invalid") }
        if def.declaredLabel == nil { return (false, "No usable Label") }
        return (true, "Valid · \(Doctor.abbreviate(def.url.deletingLastPathComponent().path))")
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
                if let modified = logModified {
                    Text("· last written \(modified.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(modified.formatted(date: .abbreviated, time: .standard))
                }
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
            logModified = RunObserver.logStamp(job)
            if !follow { break }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// "14:02:11: Stopped · PID 1234 quit after 1.2 s", with the useful next step.
struct OutcomeLine: View {
    @Environment(AppModel.self) private var model
    let job: Job
    let outcome: ActionOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("\(outcome.finished.formatted(date: .omitted, time: .standard)): \(outcome.report.summary)")
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
            .help(help)
            .accessibilityElement(children: .combine)
            if let failure = outcome.failure {
                DisclosureGroup("Details") {
                    Text(failure.details)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            switch outcome.followUp {
            case .forceQuit? where job.pid != nil && !model.isBusy(job):
                Button("Force Quit") { model.forceQuit(job) }
                    .controlSize(.small)
                    .tint(.red)
                    .help("Send SIGKILL: it quits at once, without cleaning up (⌥⌘.)")
            case .keepItOff? where !job.isDisabled && !job.scope.isReadOnly && !model.isBusy(job):
                Button("Keep It Off") { model.perform(.keepOff, on: job) }
                    .controlSize(.small)
                    .help("Disable it so launchd doesn’t start it again, not even at \(job.scope.isDaemon ? "boot" : "login").")
            default:
                EmptyView()
            }
        }
    }

    var icon: String {
        switch outcome.report.tone {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning, .failure: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch outcome.report.tone {
        case .success: .green
        case .info: .secondary
        case .warning, .failure: .orange
        }
    }

    var help: String {
        switch outcome.report.result {
        case "restartedByLaunchd":
            "Its KeepAlive setting, its app, or another tool started it again. Turn off Keep this job active to keep it off."
        case "didNotStart":
            "launchd recorded no new launch. It may be throttling restarts (at most every \(job.definition.throttleInterval) s), or the job is disabled."
        default:
            outcome.failure?.details ?? (outcome.commands.isEmpty ? "" : "Ran:\n" + outcome.commands.map(Shell.commandLine).joined(separator: "\n"))
        }
    }
}
