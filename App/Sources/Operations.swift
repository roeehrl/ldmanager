import LDCore
import SwiftUI

/// What the user asked for. One runs per job at a time.
enum OperationKind: String, Sendable {
    case start, startNow, stop, forceQuit, restart, turnOn, turnOff, keepOff, load, unload, reload, signal

    /// "Couldn’t <verb> it"
    var verb: String {
        switch self {
        case .start, .startNow: "start"
        case .stop: "stop"
        case .forceQuit: "force quit"
        case .restart: "restart"
        case .turnOn: "turn on"
        case .turnOff, .keepOff: "turn off"
        case .load: "load"
        case .unload: "unload"
        case .reload: "reload"
        case .signal: "signal"
        }
    }

    /// The short word shown in the table and the menu bar while it runs.
    var progressWord: String {
        switch self {
        case .start, .startNow: "Starting…"
        case .stop: "Stopping…"
        case .forceQuit: "Force quitting…"
        case .restart: "Restarting…"
        case .turnOn: "Turning on…"
        case .turnOff, .keepOff: "Turning off…"
        case .load: "Loading…"
        case .unload: "Unloading…"
        case .reload: "Reloading…"
        case .signal: "Sending…"
        }
    }

    /// Operations that wait for a process to quit, where Force Quit can help.
    var waitsForExit: Bool { [.stop, .restart, .turnOff, .unload, .reload].contains(self) }
}

/// The inspector's main button.
enum PrimaryButton: Equatable, Sendable {
    case restart, startNow, runNow, start, enableAndStart

    var title: String {
        switch self {
        case .restart: "Restart"
        case .startNow: "Start Now"
        case .runNow: "Run Now"
        case .start: "Start"
        case .enableAndStart: "Enable & Start"
        }
    }

    var kind: OperationKind {
        switch self {
        case .restart: .restart
        case .startNow: .startNow
        case .runNow, .start, .enableAndStart: .start
        }
    }
}

/// Which buttons the inspector shows. Frozen while an operation runs, so a Stop
/// button doesn't vanish before the outcome that explains why.
struct ButtonLayout: Equatable, Sendable {
    var primary: PrimaryButton?
    var showsStop: Bool

    static func live(_ job: Job) -> ButtonLayout {
        switch job.status {
        case .invalid, .placeholder: return ButtonLayout(primary: nil, showsStop: false)
        default: break
        }
        if job.pid != nil { return ButtonLayout(primary: .restart, showsStop: !job.isAppleKeepAlive) }
        if job.status == .restarting { return ButtonLayout(primary: .startNow, showsStop: !job.isAppleKeepAlive) }
        if job.isDisabled && !job.scope.isReadOnly { return ButtonLayout(primary: .enableAndStart, showsStop: false) }
        if !job.isLoaded { return ButtonLayout(primary: .start, showsStop: false) }
        return ButtonLayout(primary: .runNow, showsStop: false)
    }
}

struct JobOperation: Sendable {
    let id = UUID()
    let kind: OperationKind
    let started: Date
    let pidBefore: Int?
    var phase: String
    var canForceQuit = false
    var forceQuitSent = false
    let layout: ButtonLayout
}

struct ActionOutcome: Sendable {
    enum FollowUp { case forceQuit, keepItOff }

    let kind: OperationKind
    var report: ActionReport
    let finished: Date
    var failure: LaunchctlFailure?
    /// The launchctl commands that ran, for the outcome's tooltip.
    var commands: [[String]] = []

    var followUp: FollowUp? { report.offerForceQuit ? .forceQuit : report.offerKeepOff ? .keepItOff : nil }
    /// The short form shows in the table and the menu bar for this long.
    var isFresh: Bool { Date().timeIntervalSince(finished) < 10 }
    var short: String { failure != nil || report.tone == .failure ? "Couldn’t \(kind.verb)" : report.short }
}

extension AppModel {
    // MARK: Entry points

    /// Start, or Start Now while launchd waits out its restart delay.
    func start(_ job: Job) {
        perform(job.status == .restarting ? .startNow : .start, on: job)
    }

    func perform(_ kind: OperationKind, on job: Job) {
        let label = job.label
        switch kind {
        case .start, .startNow:
            begin(kind, job, phase: job.isLoaded ? "Starting…" : "Loading…", ldm: ["start", label]) { fresh, phase in
                try Lifecycle.start(fresh, onPhase: phase)
            }
        case .stop:
            begin(kind, job, phase: job.stopUnloads ? "Stopping… unloading so launchd doesn’t restart it"
                  : job.pid.map { "Stopping… sent SIGTERM to PID \($0)" } ?? "Stopping…", ldm: ["stop", label]) { fresh, phase in
                try Lifecycle.stop(fresh, onPhase: phase)
            }
        case .forceQuit:
            forceQuit(job)
        case .restart:
            begin(kind, job, phase: job.pid.map { "Restarting… waiting for PID \($0) to quit" } ?? "Restarting…", ldm: ["restart", label]) { fresh, phase in
                try Lifecycle.restart(fresh, onPhase: phase)
            }
        case .turnOn:
            begin(kind, job, phase: "Turning on…", ldm: ["enable", label]) { fresh, _ in
                try Launchctl.perform(.enable, on: fresh)
                Thread.sleep(forTimeInterval: 0.5)
                let after = Inventory.reload(fresh)
                let summary = after.pid.map { "On · loaded and running as PID \($0)" }
                    ?? "On · loaded · launchd starts it: \(after.definition.schedule.summaryInSentence)"
                return ActionReport(tone: .success, summary: summary, short: "On", result: "enabled")
            }
        case .turnOff, .keepOff:
            begin(kind, job, phase: job.pid.map { "Turning off… waiting for PID \($0) to quit" } ?? "Turning off…", ldm: ["disable", label]) { fresh, phase in
                try Lifecycle.takeDown(.disable, fresh) { phase($0.replacingOccurrences(of: "Unloading", with: "Turning off… unloading")) }
            }
        case .load:
            begin(kind, job, phase: "Loading…", ldm: ["load", label]) { fresh, _ in
                try Launchctl.perform(.load, on: fresh)
                let after = Inventory.reload(fresh)
                return ActionReport(tone: .success, summary: "Loaded · \(after.resultSummary)", short: "Loaded", result: "loaded")
            }
        case .unload:
            begin(kind, job, phase: "Unloading…", ldm: ["unload", label]) { fresh, phase in
                try Lifecycle.takeDown(.unload, fresh, onPhase: phase)
            }
        case .reload, .signal:
            assertionFailure("Use reload(_:verb:) or sendSignal(_:to:)")
        }
    }

    /// The switch: on enables (and loads), off unloads and disables.
    func setActive(_ active: Bool, _ job: Job) {
        perform(active ? .turnOn : .turnOff, on: job)
    }

    func sendSignal(_ signal: String, to job: Job) {
        begin(.signal, job, phase: "Sending \(signal)…", ldm: ["signal", job.label, signal]) { fresh, _ in
            try Lifecycle.signal(signal, job: fresh)
        }
    }

    /// Unloads the copy launchd is running and loads the plist as it is now on disk.
    /// `job` is the job as it was before the file changed, so a changed Label still
    /// unloads the old one.
    func reload(_ job: Job, verb: String = "Saved") {
        let before = job
        let sameLabel = JobDefinition.load(url: job.definition.url, scope: job.scope).declaredLabel == job.definition.declaredLabel
        begin(.reload, job, phase: job.pid.map { "Reloading… waiting for the old copy (PID \($0)) to quit" } ?? "Reloading…",
              ldm: sameLabel ? ["reload", job.label] : nil, freshen: { _ in Inventory.refreshState(before) }) { old, phase in
            try Lifecycle.reload(old, new: Inventory.reload(old), verb: verb, onPhase: phase)
        }
    }

    /// Force Quit: on its own, or to end a stop or restart that is taking too long.
    func forceQuit(_ job: Job) {
        guard let op = operations[job.id] else {
            begin(.forceQuit, job, phase: job.pid.map { "Force quitting PID \($0)…" } ?? "Force quitting…",
                  ldm: ["signal", job.label, "SIGKILL"]) { fresh, phase in
                try Lifecycle.forceQuit(fresh, onPhase: phase)
            }
            return
        }
        guard op.canForceQuit, !op.forceQuitSent, let target = op.pidBefore else { return }
        let id = job.id, token = op.id
        operations[id]?.forceQuitSent = true
        operations[id]?.phase = "Force quitting PID \(target)…"
        let restore = { [weak self] (message: String) in
            guard let self, self.operations[id]?.id == token else { return }
            self.operations[id]?.forceQuitSent = false
            self.operations[id]?.phase = message
        }
        withPrivilege(job.scope.launchctlNeedsAdmin, reason: "Force quitting “\(job.title)” needs administrator rights.",
                      onCancel: { restore("Force Quit cancelled — still waiting for PID \(target) to quit") }) {
            Task { [weak self] in
                // Only the copy the user is waiting on: a restart may already have started a new one.
                let outcome: Result<Bool, Error> = await Task.detached {
                    let now = Inventory.reload(job)
                    guard now.pid == target else { return .success(false) }
                    return Result { try Launchctl.signal("SIGKILL", job: now) == .done }
                }.value
                switch outcome {
                case .success(true): self?.forceQuitAt[id] = Date()
                case .success(false): restore("PID \(target) already quit")
                case .failure(LDError.authorizationCancelled): restore("Force Quit cancelled — still waiting for PID \(target) to quit")
                case .failure(LDError.launchctl(let f)): restore("Couldn’t force quit: \(f.explanation)")
                case .failure(let e): restore("Couldn’t force quit: \(e.localizedDescription)")
                }
            }
        }
    }

    // MARK: State for views

    func isBusy(_ job: Job) -> Bool { operations[job.id] != nil }

    func layout(for job: Job) -> ButtonLayout {
        operations[job.id]?.layout ?? ButtonLayout.live(job)
    }

    func canStart(_ job: Job) -> Bool {
        !isBusy(job) && !isSheetOpen && job.pid == nil && job.status != .stopping && job.status != .invalid && job.status != .placeholder
    }

    func canStop(_ job: Job) -> Bool {
        !isBusy(job) && !isSheetOpen && (job.pid != nil || job.status == .restarting) && !job.isAppleKeepAlive
    }

    func canRestart(_ job: Job) -> Bool {
        !isBusy(job) && !isSheetOpen && job.isLoaded && job.status != .stopping
    }

    func canForceQuit(_ job: Job) -> Bool {
        if let op = operations[job.id] { return op.canForceQuit && !op.forceQuitSent }
        return job.pid != nil && !job.isAppleKeepAlive && !isSheetOpen
    }

    /// Menu commands act on the selected job; not while a sheet or dialog is up.
    var isSheetOpen: Bool { editorTarget != nil || privilegeRequest != nil || confirmTrash != nil }

    /// Force quit from here in the last 10 minutes: an expected SIGKILL, not a failure.
    func isRecentForceQuit(_ job: Job) -> Bool {
        guard let at = forceQuitAt[job.id] else { return false }
        return Date().timeIntervalSince(at) < 600 && job.pid == nil && job.lastExit == -9
    }

    func resultColor(_ job: Job) -> Color {
        isBusy(job) || isStoppedByRequest(job) || isRecentForceQuit(job) ? .secondary : job.resultColor
    }

    /// Stopped with Stop and still unloaded: says "Stopped", not "Not loaded".
    func isStoppedByRequest(_ job: Job) -> Bool {
        stoppedByRequest[job.id] != nil && !job.isLoaded && !job.isDisabled
    }

    /// The status to draw, with what the app knows on top of launchd's view.
    func displayStatus(_ job: Job) -> JobStatus {
        if let op = operations[job.id] {
            switch op.kind {
            case .stop, .forceQuit, .turnOff, .keepOff, .unload: return .stopping
            default: return job.status
            }
        }
        if isStoppedByRequest(job) { return .stopping }
        if isRecentForceQuit(job) { return .idle }
        return job.status
    }

    func statusTitle(_ job: Job) -> String {
        if let op = operations[job.id] { return op.kind.progressWord }
        if isStoppedByRequest(job) { return "Stopped" }
        if isRecentForceQuit(job) { return JobStatus.idle.title }
        return job.status.title
    }

    /// The table's Result column.
    func resultText(for job: Job) -> String {
        if let op = operations[job.id] { return op.kind.progressWord }
        if let o = outcomes[job.id], o.isFresh { return o.short }
        if isStoppedByRequest(job) { return "Stopped" }
        if isRecentForceQuit(job) { return "Force quit (SIGKILL)" }
        return job.resultSummary
    }

    /// The menu bar row's second line.
    func menuSubtitle(for job: Job) -> String {
        if let op = operations[job.id] { return op.kind.progressWord }
        if let o = outcomes[job.id], o.isFresh {
            return o.failure != nil || o.report.tone == .failure ? "\(o.short) — open LD Manager" : o.short
        }
        if isStoppedByRequest(job) { return "Stopped · back at next " + (job.scope.isDaemon ? "restart" : "login") }
        if isRecentForceQuit(job) { return "Force quit (SIGKILL)" }
        switch job.status {
        case .running: return job.launchdState == .spawning ? "Starting · PID \(job.pid ?? 0)" : "Running · PID \(job.pid ?? 0)"
        case .stopping: return "Stopping" + (job.pid.map { " · PID \($0)" } ?? "")
        case .restarting: return "Restarting soon"
        case .notLoaded: return "Not loaded · loads at " + (job.scope.isDaemon ? "boot" : "login")
        default: return job.resultSummary + " · " + job.definition.schedule.summaryInSentence
        }
    }

    // MARK: Running operations

    /// Takes the job's lock at once (before any password or helper prompt, so a
    /// second click is ignored), then runs `work` off the main thread.
    /// `ldm`: the same action as an ldm command, used to ask for the password once
    /// when the helper isn't available. `freshen`: how to re-read the job first.
    private func begin(_ kind: OperationKind, _ job: Job, phase: String, ldm: [String]?,
                       freshen: @escaping @Sendable (Job) -> Job = { Inventory.reload($0) },
                       work: @escaping @Sendable (Job, @escaping @Sendable (String) -> Void) throws -> ActionReport) {
        guard operations[job.id] == nil else { return }
        let id = job.id
        let admin = job.scope.launchctlNeedsAdmin
        let prompts = admin && helperState != .enabled
        let op = JobOperation(kind: kind, started: Date(), pidBefore: job.pid,
                              phase: prompts ? "Waiting for administrator rights…" : phase, layout: layout(for: job))
        operations[id] = op
        outcomes[id] = nil
        let token = op.id
        let cancelled = ActionOutcome(kind: kind, report: ActionReport(tone: .info, summary: "Cancelled — nothing was changed",
                                                                       short: "Cancelled", result: "cancelled"), finished: Date())
        withPrivilege(admin, reason: "Changing the system job “\(job.title)” needs administrator rights.",
                      onCancel: { [weak self] in self?.finish(id, token, job, cancelled) }) { [weak self] in
            guard let self, self.operations[id]?.id == token else { return }
            self.operations[id]?.phase = phase
            self.execute(token, job, admin: admin, ldm: ldm, freshen: freshen, work)
        }
    }

    private func execute(_ token: UUID, _ job: Job, admin: Bool, ldm: [String]?,
                         freshen: @escaping @Sendable (Job) -> Job,
                         _ work: @escaping @Sendable (Job, @escaping @Sendable (String) -> Void) throws -> ActionReport) {
        guard let op = operations[job.id] else { return }
        let id = job.id, kind = op.kind
        let setPhase: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in
                guard let self, let op = self.operations[id], op.id == token, !op.forceQuitSent else { return }
                self.operations[id]?.phase = text
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.operations[id]?.id == token else { return }
            AccessibilityNotification.Announcement("\(kind.progressWord.dropLast()) \(job.title)").post()
        }
        if kind.waitsForExit, let target = op.pidBefore {
            // Offer Force Quit while the copy the user asked to stop is still there, and only then.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                while let self, let current = self.operations[id], current.id == token {
                    let now = await Task.detached { Inventory.reload(job) }.value
                    guard self.operations[id]?.id == token else { return }
                    let stillThere = now.pid == target
                    if self.operations[id]?.canForceQuit != stillThere { self.operations[id]?.canForceQuit = stillThere }
                    if stillThere, kind == .stop, !job.restartsOnItsOwn, self.operations[id]?.forceQuitSent == false {
                        self.operations[id]?.phase = "Still running after \(Int(Date().timeIntervalSince(current.started))) s — PID \(target) hasn’t quit."
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        // Hard cap: controls come back even if launchd never answers. A late result is still applied.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, self.operations[id]?.id == token else { return }
            let now = await Task.detached { Inventory.reload(job) }.value
            var report = ActionReport(tone: .warning, summary: "Timed out waiting for launchd · state now: \(now.detail?.state ?? "not loaded")",
                                      short: "Timed out", result: "timedOut")
            report.timedOut = true
            report.offerForceQuit = now.pid != nil
            self.finish(id, token, job, ActionOutcome(kind: kind, report: report, finished: Date()))
            self.lateTokens.insert(token)
        }
        let ldmPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ldm").path
        Task { [weak self] in
            let log = CommandLog()
            var outcome: ActionOutcome
            do {
                let report = try await Task.detached {
                    // Without the helper each launchctl call would prompt; ldm does the whole action as root behind one prompt.
                    if admin, let ldm, !Privileged.usesHelper, FileManager.default.isExecutableFile(atPath: ldmPath) {
                        return try AdminLDM.run(ldmPath, ldm)
                    }
                    return try CommandLog.$current.withValue(log) { try work(freshen(job), setPhase) }
                }.value
                outcome = ActionOutcome(kind: kind, report: report, finished: Date())
            } catch LDError.launchctl(let f) {
                outcome = ActionOutcome(kind: kind, report: ActionReport(tone: .failure, summary: "Couldn’t \(kind.verb) it: \(f.explanation)",
                                                                         short: "Couldn’t \(kind.verb)", result: "failed"),
                                        finished: Date(), failure: f)
            } catch LDError.authorizationCancelled {
                // A later prompt in a multi-step action may come after earlier steps changed something.
                let now = await Task.detached { Inventory.reload(job) }.value
                let changed = now.isLoaded != job.isLoaded || now.isDisabled != job.isDisabled || now.pid != job.pid
                let report = changed
                    ? ActionReport(tone: .warning, summary: "Cancelled partway · it’s now \(now.status.title.lowercased())", short: "Cancelled", result: "cancelled")
                    : ActionReport(tone: .info, summary: "Cancelled — nothing was changed", short: "Cancelled", result: "cancelled")
                outcome = ActionOutcome(kind: kind, report: report, finished: Date())
            } catch {
                outcome = ActionOutcome(kind: kind, report: ActionReport(tone: .failure, summary: "Couldn’t \(kind.verb) it: \(error.localizedDescription)",
                                                                         short: "Couldn’t \(kind.verb)", result: "failed"), finished: Date())
            }
            outcome.commands = log.commands
            self?.finish(id, token, job, outcome)
        }
    }

    private func finish(_ id: Job.ID, _ token: UUID, _ job: Job, _ result: ActionOutcome) {
        if let op = operations[id], op.id == token {
            operations[id] = nil
        } else if lateTokens.remove(token) == nil || operations[id] != nil {
            return  // Superseded. A result arriving after the 90 s cap still counts if nothing newer started.
        }
        var outcome = result
        let forceQuitSent = forceQuitAt[id].map { outcome.finished.timeIntervalSince($0) < 120 } ?? false
        if forceQuitSent, outcome.report.tone == .success, ["stopped", "unloaded"].contains(outcome.report.result) {
            var r = Lifecycle.report(.forceQuit(pid: job.pid), job: job, wording: .app)
            if outcome.report.result == "unloaded" {
                r.summary += " · stays stopped until \(Lifecycle.Wording.app.until(job))"
                r.result = "unloaded"
            }
            outcome.report = r
        }
        outcomes[id] = outcome
        switch outcome.kind {
        case .stop where outcome.report.result == "unloaded":
            stoppedByRequest[id] = Date()
        case .start, .startNow, .restart, .turnOn, .load, .reload, .turnOff, .keepOff:
            stoppedByRequest[id] = nil
        default: break
        }
        if outcome.kind == .forceQuit && outcome.report.result == "forceQuit" { forceQuitAt[id] = Date() }

        // Inline in the inspector when it shows this job; otherwise an alert says what failed.
        let shownInInspector = selectedJobID == id && showInspector && sidebar != .problems && sidebar != .recent
        if outcome.report.tone == .failure && !shownInInspector {
            errorMessage = "Couldn’t \(outcome.kind.verb) “\(job.title)”. " + (outcome.failure.map { "\($0.explanation)\n\n\($0.details)" } ?? outcome.report.summary)
        }
        AccessibilityNotification.Announcement("\(job.title): \(outcome.report.summary)").post()

        Task { [weak self] in
            await self?.refresh(force: true)
            // launchd settles after an action (a KeepAlive restart, a slow exit); follow this job for a while.
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.operations[id] == nil else { return }
                let snapshot = self.background
                let fresh = await Task.detached { Inventory.reload(job, background: snapshot) }.value
                if let i = self.jobs.firstIndex(where: { $0.id == id }) { self.jobs[i] = fresh }
            }
        }
    }
}

/// Runs an action as `ldm … --json` as root, behind a single administrator prompt.
enum AdminLDM {
    struct Reply: Decodable {
        let result: String
        let tone: String
        let summary: String
        let short: String
        let timedOut: Bool
        let offerForceQuit: Bool
        let offerKeepOff: Bool
    }

    static func run(_ ldm: String, _ args: [String]) throws -> ActionReport {
        let command = Shell.commandLine([ldm] + args + ["--json", "--no-color"])
        let r = Shell.runAsAdmin([["/bin/sh", "-c", command + " 2>&1; echo \"__ldm_status=$?\""]])
        if r.status == 4 { throw LDError.authorizationCancelled }
        let text = (r.succeeded ? r.stdout : r.message).replacingOccurrences(of: "\r", with: "\n")
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"),
           let reply = try? JSONDecoder().decode(Reply.self, from: Data(text[open...close].utf8)) {
            return ActionReport(tone: ActionReport.Tone(rawValue: reply.tone) ?? .info, summary: reply.summary, short: reply.short,
                                timedOut: reply.timedOut, offerForceQuit: reply.offerForceQuit, offerKeepOff: reply.offerKeepOff,
                                result: reply.result)
        }
        let message = text.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("__ldm_status=") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.replacingOccurrences(of: "error: ", with: "") }
            .joined(separator: " ")
        throw LDError.launchd(message.isEmpty ? "ldm failed." : message)
    }
}
