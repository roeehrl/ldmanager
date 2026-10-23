import LDCore
import Observation
import SwiftUI

enum TriggerKind: String, CaseIterable, Identifiable {
    case atLoad, every, schedule, keepAlive, files, onDemand
    var id: String { rawValue }

    var title: String {
        switch self {
        case .atLoad: "At login"
        case .every: "Every…"
        case .schedule: "On a schedule"
        case .keepAlive: "Keep running"
        case .files: "Files change"
        case .onDemand: "On demand"
        }
    }

    var key: String {
        switch self {
        case .atLoad: "RunAtLoad"
        case .every: "StartInterval"
        case .schedule: "StartCalendarInterval"
        case .keepAlive: "KeepAlive"
        case .files: "WatchPaths"
        case .onDemand: "—"
        }
    }

    var symbol: String {
        switch self {
        case .atLoad: "person.crop.circle.badge.checkmark"
        case .every: "timer"
        case .schedule: "calendar"
        case .keepAlive: "arrow.triangle.2.circlepath"
        case .files: "doc.badge.ellipsis"
        case .onDemand: "hand.tap"
        }
    }
}

enum IntervalUnit: Int, CaseIterable, Identifiable {
    case seconds = 1, minutes = 60, hours = 3600, days = 86400
    var id: Int { rawValue }
    var title: String { ["seconds", "minutes", "hours", "days"][IntervalUnit.allCases.firstIndex(of: self)!] }
}

struct CalendarEntry: Identifiable, Equatable {
    var id = UUID()
    var weekday: Int = -1  // -1 = every day, 0 = Sunday
    var time: Date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!

    var dict: [String: Int] {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        var d = ["Hour": c.hour ?? 0, "Minute": c.minute ?? 0]
        if weekday >= 0 { d["Weekday"] = weekday }
        return d
    }

    static func == (a: CalendarEntry, b: CalendarEntry) -> Bool { a.dict == b.dict }
}

enum EditorMode: String, CaseIterable, Identifiable {
    case form = "Form", keys = "Keys", xml = "XML"
    var id: String { rawValue }
}

@MainActor
@Observable
final class EditorDraft {
    let job: Job?
    /// The file as it is on disk; diffs are against this.
    let original: [String: Any]
    /// What the form's fields apply onto: the file, or the XML after XML edits.
    private var formBase: [String: Any]

    var label = ""
    var scope: JobScope = .user
    var program = ""
    var arguments: [String] = []
    var trigger: TriggerKind = .every
    var intervalValue = 30
    var intervalUnit: IntervalUnit = .minutes
    var calendar: [CalendarEntry] = [CalendarEntry()]
    var restartOnlyOnFailure = false
    var watchPaths: [String] = [""]
    var alsoAtLoad = false
    var logPath = ""
    var workingDirectory = ""
    var loadAfterSave = true

    var mode: EditorMode = .form {
        didSet { modeChanged(from: oldValue) }
    }
    var xmlText = ""
    var xmlError: String?
    var xmlEdited = false

    private var initialTriggerSignature = ""

    init(job: Job?) {
        self.job = job
        original = job?.definition.raw ?? [:]
        formBase = original
        if let job {
            scope = job.scope
            load(from: original)
            initialTriggerSignature = triggerSignature
        } else {
            label = "local.\(NSUserName()).my-job"
            initialTriggerSignature = ""
        }
    }

    var isNew: Bool { job == nil }

    func load(from raw: [String: Any]) {
        let def = JobDefinition(url: job?.definition.url ?? URL(fileURLWithPath: "/tmp/x.plist"), scope: scope, raw: raw)
        label = def.label
        program = def.program ?? ""
        arguments = Array(def.commandLine.dropFirst())
        logPath = def.standardOutPath ?? def.standardErrorPath ?? ""
        workingDirectory = def.workingDirectory ?? ""
        alsoAtLoad = def.runAtLoad
        switch Trigger(definition: def) {
        case .keepAlive(let f): trigger = .keepAlive; restartOnlyOnFailure = f
        case .every(let s):
            trigger = .every
            let unit = IntervalUnit.allCases.reversed().first { s % $0.rawValue == 0 } ?? .seconds
            intervalUnit = unit
            intervalValue = s / unit.rawValue
        case .calendar(let c):
            trigger = .schedule
            calendar = c.map { d in
                var e = CalendarEntry()
                e.weekday = d["Weekday"].map { $0 % 7 } ?? -1
                e.time = Calendar.current.date(bySettingHour: d["Hour"] ?? 0, minute: d["Minute"] ?? 0, second: 0, of: Date()) ?? Date()
                return e
            }
        case .watch(let p): trigger = .files; watchPaths = p
        case .atLoad: trigger = .atLoad
        case .onDemand: trigger = .onDemand
        }
    }

    var currentTrigger: Trigger {
        switch trigger {
        case .atLoad: .atLoad
        case .every: .every(seconds: max(1, intervalValue) * intervalUnit.rawValue)
        case .schedule: .calendar(calendar.map(\.dict))
        case .keepAlive: .keepAlive(onlyOnFailure: restartOnlyOnFailure)
        case .files: .watch(watchPaths.map(JobBuilder.expandTilde).filter { !$0.isEmpty })
        case .onDemand: .onDemand
        }
    }

    private var triggerSignature: String { "\(currentTrigger)|\(alsoAtLoad && trigger != .keepAlive && trigger != .atLoad)" }

    /// Changes the form makes to the original plist.
    func formUpdates() -> [String: Any?] {
        var u: [String: Any?] = [:]
        if isNew || label != (formBase["Label"] as? String) { u["Label"] = label }

        let prog = JobBuilder.expandTilde(program.trimmingCharacters(in: .whitespaces))
        let args = arguments.map(JobBuilder.expandTilde)
        let def = JobDefinition(url: URL(fileURLWithPath: "/tmp/x.plist"), scope: scope, raw: formBase)
        if def.programKey != nil {
            if prog != def.programKey { u["Program"] = prog }
            let argv0 = def.programArguments.first ?? prog
            let newArgs = [argv0] + args
            if newArgs != def.programArguments { u["ProgramArguments"] = newArgs }
        } else {
            let newArgs = [prog] + args
            if newArgs != def.programArguments { u["ProgramArguments"] = newArgs }
        }

        if isNew || triggerSignature != initialTriggerSignature {
            for (k, v) in currentTrigger.updates(runAtLoad: alsoAtLoad && trigger != .keepAlive) { u[k] = v }
        }

        let log = logPath.trimmingCharacters(in: .whitespaces)
        let oldLog = def.standardOutPath ?? def.standardErrorPath ?? ""
        if log != oldLog {
            u["StandardOutPath"] = log.isEmpty ? nil : JobBuilder.expandTilde(log)
            u["StandardErrorPath"] = log.isEmpty ? nil : JobBuilder.expandTilde(log)
        }
        let wd = workingDirectory.trimmingCharacters(in: .whitespaces)
        if wd != (def.workingDirectory ?? "") { u["WorkingDirectory"] = wd.isEmpty ? nil : JobBuilder.expandTilde(wd) }
        return u
    }

    var result: [String: Any] {
        if xmlEdited, let parsed = parseXML() { return parsed }
        return PlistEditor.apply(formUpdates(), to: formBase)
    }

    var changes: [PlistChange] { PlistEditor.diff(original, result) }

    func parseXML() -> [String: Any]? {
        guard let data = xmlText.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    private func modeChanged(from old: EditorMode) {
        if mode == .xml && !xmlEdited {
            xmlText = (try? PlistEditor.xml(result)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        if old == .xml && mode != .xml && xmlEdited, let parsed = parseXML() {
            // XML edits become the form's new base, so keys the form doesn't show survive.
            formBase = parsed
            load(from: parsed)
            initialTriggerSignature = triggerSignature
            xmlEdited = false
        }
    }

    var validationError: String? {
        if mode == .xml && xmlEdited {
            if parseXML() == nil { return "The XML isn’t a valid property list dictionary." }
            return nil
        }
        if !JobBuilder.isValidLabel(label) { return "The label can contain letters, digits, - _ . and @." }
        if program.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a program to run." }
        if trigger == .files && watchPaths.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return "Add a path to watch." }
        if isNew, FileManager.default.fileExists(atPath: targetURL.path) { return "\(targetURL.lastPathComponent) already exists." }
        return nil
    }

    var targetURL: URL {
        job?.definition.url ?? scope.directory.appendingPathComponent("\(label).plist")
    }

    var programStatus: (ok: Bool, text: String)? {
        let p = JobBuilder.expandTilde(program.trimmingCharacters(in: .whitespaces))
        guard !p.isEmpty else { return nil }
        if !p.hasPrefix("/") { return (false, "Use a full path — launchd doesn’t search your shell’s PATH.") }
        if FileManager.default.isExecutableFile(atPath: p) { return (true, "Program exists and is executable") }
        if FileManager.default.fileExists(atPath: p) { return (false, "Exists but isn’t executable") }
        return (false, "Not found")
    }
}

struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EditorDraft
    @State private var saving = false
    @State private var saveError: String?
    @State private var showFullDiff = false

    init(target: EditorTarget) {
        switch target {
        case .edit(let job): _draft = State(initialValue: EditorDraft(job: job))
        case .new: _draft = State(initialValue: EditorDraft(job: nil))
        }
    }

    var body: some View {
        @Bindable var draft = draft
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch draft.mode {
                case .form: form
                case .keys: keysView
                case .xml: xmlView
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 780, height: 720)
    }

    var header: some View {
        @Bindable var draft = draft
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.isNew ? "New Job" : "Edit \(draft.job!.title)").font(.headline)
                Text(Doctor.abbreviate(draft.targetURL.path)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("Mode", selection: $draft.mode) {
                ForEach(EditorMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Form

    var form: some View {
        @Bindable var draft = draft
        return Form {
            if draft.isNew {
                Section("Job") {
                    TextField("Label", text: $draft.label, prompt: Text("com.example.my-job"))
                        .font(.body.monospaced())
                    Picker("Install for", selection: $draft.scope) {
                        Text("Me (user agent)").tag(JobScope.user)
                        Text("All users (agent)").tag(JobScope.allUsers)
                        Text("System (daemon, runs as root)").tag(JobScope.system)
                    }
                }
            }

            Section("What it runs") {
                HStack {
                    TextField("Program", text: $draft.program, prompt: Text("/path/to/program"))
                        .font(.body.monospaced())
                    Button("Choose…") { chooseProgram() }
                }
                if let s = draft.programStatus {
                    Label(s.text, systemImage: s.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(s.ok ? .green : .orange)
                }
                LabeledContent("Arguments") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(draft.arguments.indices, id: \.self) { i in
                            HStack {
                                TextField("Argument \(i + 1)", text: Binding(get: { i < draft.arguments.count ? draft.arguments[i] : "" },
                                                                            set: { if i < draft.arguments.count { draft.arguments[i] = $0 } }))
                                    .font(.body.monospaced())
                                    .labelsHidden()
                                Button { draft.arguments.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove argument \(i + 1)")
                            }
                        }
                        Button("Add Argument", systemImage: "plus") { draft.arguments.append("") }
                            .buttonStyle(.borderless)
                    }
                }
                TextField("Working directory", text: $draft.workingDirectory, prompt: Text("Optional"))
                    .font(.body.monospaced())
            }

            Section("When it runs") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(TriggerKind.allCases) { kind in
                        Button { draft.trigger = kind } label: {
                            VStack(spacing: 3) {
                                Image(systemName: kind.symbol)
                                Text(kind.title).font(.caption.weight(draft.trigger == kind ? .semibold : .regular))
                                Text(kind.key).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 62)
                            .background(draft.trigger == kind ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(draft.trigger == kind ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: draft.trigger == kind ? 1.5 : 1))
                            .foregroundStyle(draft.trigger == kind ? Color.accentColor : .primary)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.trigger == kind ? .isSelected : [])
                    }
                }
                triggerDetail
            }

            Section("Output") {
                TextField("Log file", text: $draft.logPath, prompt: Text("~/Library/Logs/my-job.log"))
                    .font(.body.monospaced())
                if draft.logPath.isEmpty {
                    Text("Without a log file, output goes to the unified log, which is hard to find.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder var triggerDetail: some View {
        @Bindable var draft = draft
        switch draft.trigger {
        case .every:
            HStack {
                Text("Every")
                TextField("Interval", value: $draft.intervalValue, format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                Picker("Unit", selection: $draft.intervalUnit) {
                    ForEach(IntervalUnit.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Toggle("Also run at login", isOn: $draft.alsoAtLoad)
                    .padding(.leading, 12)
            }
            Text("Counts from when the job is loaded. Runs missed while the Mac sleeps happen once on wake.")
                .font(.caption).foregroundStyle(.secondary)
        case .schedule:
            ForEach($draft.calendar) { $entry in
                HStack {
                    Picker("Day", selection: $entry.weekday) {
                        Text("Every day").tag(-1)
                        ForEach(0..<7) { d in Text(Calendar.current.weekdaySymbols[d]).tag(d) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Text("at")
                    DatePicker("Time", selection: $entry.time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                    if draft.calendar.count > 1 {
                        Button { draft.calendar.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove time")
                    }
                }
            }
            HStack {
                Button("Add Another Time", systemImage: "plus") { draft.calendar.append(CalendarEntry()) }
                    .buttonStyle(.borderless)
                Spacer()
                CronField { entries in draft.calendar = entries }
            }
            let next = JobDefinition(url: URL(fileURLWithPath: "/tmp/x.plist"), scope: draft.scope,
                                     raw: ["StartCalendarInterval": draft.calendar.map(\.dict)]).schedule.nextRuns(count: 3)
            Text("Next: " + next.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) }.joined(separator: " · ") + ". If the Mac is off then, the run is skipped.")
                .font(.caption).foregroundStyle(.secondary)
        case .keepAlive:
            Picker("Restart", selection: $draft.restartOnlyOnFailure) {
                Text("Always — whenever it exits").tag(false)
                Text("Only after a failure (non-zero exit)").tag(true)
            }
            .pickerStyle(.radioGroup)
            Text("launchd waits at least 10 seconds between restarts. The Doctor warns you if it starts looping.")
                .font(.caption).foregroundStyle(.secondary)
        case .files:
            ForEach(draft.watchPaths.indices, id: \.self) { i in
                HStack {
                    TextField("Path", text: Binding(get: { i < draft.watchPaths.count ? draft.watchPaths[i] : "" },
                                                    set: { if i < draft.watchPaths.count { draft.watchPaths[i] = $0 } }))
                        .font(.body.monospaced())
                    if draft.watchPaths.count > 1 {
                        Button { draft.watchPaths.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            Button("Add Path", systemImage: "plus") { draft.watchPaths.append("") }.buttonStyle(.borderless)
            Text("Runs when a listed file or folder changes. Changes inside subfolders aren’t noticed.")
                .font(.caption).foregroundStyle(.secondary)
        case .atLoad:
            Text("Runs once each time you log in" + (draft.scope.isDaemon ? " (for daemons: at boot)." : "."))
                .foregroundStyle(.secondary)
        case .onDemand:
            Text("Never starts by itself. Start it from LD Manager, the menu bar, or `ldm start`.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Keys / XML

    var keysView: some View {
        let dict = draft.result
        let keys = dict.keys.sorted()
        return Table(keys.map { KeyRow(key: $0, value: dict[$0]!) }) {
            TableColumn("Key") { r in Text(r.key).font(.body.monospaced()) }
                .width(min: 160, ideal: 200)
            TableColumn("Type") { r in Text(r.type).foregroundStyle(.secondary) }
                .width(70)
            TableColumn("Value") { r in Text(PlistEditor.render(r.value)).font(.callout.monospaced()).lineLimit(2).textSelection(.enabled) }
        }
    }

    var xmlView: some View {
        @Bindable var draft = draft
        return VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(get: { draft.xmlText }, set: { draft.xmlText = $0; draft.xmlEdited = true }))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            if draft.xmlEdited && draft.parseXML() == nil {
                Label("Not a valid property list yet.", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
    }

    // MARK: Footer

    var footer: some View {
        @Bindable var draft = draft
        let changes = draft.changes
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.isNew ? "New file" : changes.isEmpty ? "No changes" : "\(changes.count) change\(changes.count == 1 ? "" : "s") · every other key is kept exactly as it is")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if changes.count > 3 || draft.isNew {
                    Button(showFullDiff ? "Show Less" : "Show All") { showFullDiff.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if !changes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(showFullDiff ? changes : Array(changes.prefix(3))) { c in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.key).foregroundStyle(.secondary)
                                if let o = c.old {
                                    Text("− " + o).foregroundStyle(Color(red: 0.6, green: 0.1, blue: 0.1))
                                        .padding(.horizontal, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
                                }
                                if let n = c.new {
                                    Text("+ " + n).foregroundStyle(Color(red: 0.08, green: 0.4, blue: 0.22))
                                        .padding(.horizontal, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: showFullDiff ? 220 : 110)
                .fixedSize(horizontal: false, vertical: true)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }
            if let err = saveError ?? draft.validationError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Toggle(draft.isNew ? "Load after creating" : "Reload in launchd after saving", isOn: $draft.loadAfterSave)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if !draft.isNew { Text("· a backup is kept in Recent Changes").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Create" : (draft.loadAfterSave ? "Save & Reload" : "Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || draft.validationError != nil || (!draft.isNew && changes.isEmpty))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    func chooseProgram() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the program this job runs"
        if panel.runModal() == .OK, let url = panel.url { draft.program = url.path }
    }

    func save() {
        saving = true
        saveError = nil
        let dict = draft.result
        let url = draft.targetURL
        let scope = draft.scope
        let job = draft.job
        let reload = draft.loadAfterSave
        Task {
            do {
                try await Task.detached {
                    try PlistEditor.write(dict, to: url, scope: scope)
                    let def = JobDefinition.load(url: url, scope: scope)
                    if let job {
                        if reload && job.isLoaded {
                            try Launchctl.perform(.unload, on: job)
                            try Launchctl.perform(.load, on: Inventory.reload(Job(definition: def, listing: nil, detail: nil, override: job.override)))
                        }
                    } else if reload {
                        try Launchctl.perform(.enable, on: Job(definition: def, listing: nil, detail: nil, override: nil))
                    }
                }.value
                await model.refresh()
                model.selectedJobID = url.path
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
            saving = false
        }
    }
}

struct KeyRow: Identifiable {
    let key: String
    let value: Any
    var id: String { key }
    var type: String {
        switch value {
        case is String: "String"
        case let n as NSNumber: CFGetTypeID(n) == CFBooleanGetTypeID() ? "Boolean" : "Number"
        case is [Any]: "Array"
        case is [String: Any]: "Dictionary"
        case is Date: "Date"
        case is Data: "Data"
        default: "?"
        }
    }
}

struct CronField: View {
    let apply: ([CalendarEntry]) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        HStack(spacing: 6) {
            Text("or cron:").font(.caption).foregroundStyle(.secondary)
            TextField("30 9 * * 1", text: $text)
                .font(.caption.monospaced())
                .frame(width: 110)
                .onSubmit(parse)
                .help(error ?? "Minute Hour Day Month Weekday — press Return to apply")
            if error != nil { Image(systemName: "xmark.circle.fill").foregroundStyle(.orange).help(error!) }
        }
    }

    func parse() {
        do {
            let dicts = try Trigger.parseCron(text)
            let entries = dicts.compactMap { d -> CalendarEntry? in
                guard d["Day"] == nil, d["Month"] == nil else { return nil }
                var e = CalendarEntry()
                e.weekday = d["Weekday"].map { $0 % 7 } ?? -1
                e.time = Calendar.current.date(bySettingHour: d["Hour"] ?? 0, minute: d["Minute"] ?? 0, second: 0, of: Date()) ?? Date()
                return e
            }
            guard !entries.isEmpty, entries.count == dicts.count else { throw LDError.invalid("Day and month fields aren’t supported here yet — edit the XML.") }
            apply(entries)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
