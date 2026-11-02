import Foundation

/// How an action ended, in words: shared by the app (outcome line) and ldm.
public struct ActionReport: Equatable, Sendable {
    public enum Tone: String, Sendable, Codable { case success, info, warning, failure }

    public let tone: Tone
    public var summary: String
    /// One or two words for a table cell or the menu bar ("Stopped", "Still running").
    public let short: String
    /// The command didn't finish in time (ldm exits 7).
    public var timedOut = false
    /// Force Quit is the useful next step.
    public var offerForceQuit = false
    /// "Keep it off" (disable) is the useful next step.
    public var offerKeepOff = false
    /// What happened, as a stable word for JSON ("stopped", "unloaded", "restarted"…).
    public var result = ""

    public init(tone: Tone, summary: String, short: String, timedOut: Bool = false, offerForceQuit: Bool = false,
                offerKeepOff: Bool = false, result: String = "") {
        self.tone = tone
        self.summary = summary
        self.short = short
        self.timedOut = timedOut
        self.offerForceQuit = offerForceQuit
        self.offerKeepOff = offerKeepOff
        self.result = result
    }
}

/// Start / Stop / Restart / Force Quit, each followed to its real outcome.
/// Callers pass a freshly reloaded job; `onPhase` reports progress text while waiting.
public enum Lifecycle {
    /// Words for "until it is started again", per surface: the app's button or the ldm command.
    public struct Wording: Sendable {
        public var startAgain: String
        public var isCLI = false
        public init(startAgain: String, isCLI: Bool = false) {
            self.startAgain = startAgain
            self.isCLI = isCLI
        }
        public static let app = Wording(startAgain: "you click Start")
        public static func cli(_ job: Job) -> Wording { Wording(startAgain: "`ldm start \(job.shortName)`", isCLI: true) }

        /// "you click Start or log in again", "`ldm start x` or the next restart"
        public func until(_ job: Job) -> String {
            isCLI ? "\(startAgain) or the next " + (job.scope.isDaemon ? "restart" : "login")
                  : "\(startAgain) or " + (job.scope.isDaemon ? "restart the Mac" : "log in again")
        }
    }

    // MARK: Stop

    public static func stop(_ job: Job, timeout: TimeInterval = 60, wording: Wording = .app,
                            onPhase: ((String) -> Void)? = nil) throws -> ActionReport {
        let started = Date()
        let pid = job.pid
        if job.restartsOnItsOwn {
            if job.stopUnloads { onPhase?("Stopping… unloading so launchd doesn’t restart it") }
            let result = try Launchctl.perform(.stop, on: job) { detail, elapsed in
                if let p = detail?.pid ?? pid {
                    onPhase?("Stopping… waiting for PID \(p) to quit (\(Int(elapsed)) s)")
                }
            }
            switch result {
            case .alreadyStopped(let notLoaded): return report(.alreadyStopped(notLoaded: notLoaded), job: job, wording: wording)
            case .stillUnloading(let p): return report(.stillRunning(pid: p ?? pid ?? 0), job: job, wording: wording, timeout: timeout)
            default:
                return report(.unloaded(pid: pid, seconds: Date().timeIntervalSince(started), wasRestarting: job.status == .restarting),
                              job: job, wording: wording)
            }
        }
        if let pid { onPhase?("Stopping… sent SIGTERM to PID \(pid)") }
        let result = try Launchctl.perform(.stop, on: job)
        if case .alreadyStopped(let notLoaded) = result {
            return report(.alreadyStopped(notLoaded: notLoaded), job: job, wording: wording)
        }
        let outcome = StopObserver.observe(job, started: started, timeout: timeout) { _, elapsed in
            guard elapsed >= 3, let pid else { return }
            onPhase?(elapsed >= 10 ? "Still running after \(Int(elapsed)) s — PID \(pid) hasn’t quit."
                                   : "Stopping… waiting for PID \(pid) to quit (\(Int(elapsed)) s)")
        }
        return report(outcome, job: job, wording: wording, timeout: timeout)
    }

    /// `ldm stop --force`: SIGKILL at once, or for a KeepAlive job, unload and
    /// SIGKILL whatever is still there after `timeout`.
    public static func forceStop(_ job: Job, timeout: TimeInterval = 10, wording: Wording = .app,
                                 onPhase: ((String) -> Void)? = nil) throws -> ActionReport {
        guard job.restartsOnItsOwn else { return try forceQuit(job, wording: wording, onPhase: onPhase) }
        if job.scope.isReadOnly { throw LDError.invalid("launchd keeps this Apple job running; it can’t be stopped here. Restart is available.") }
        guard job.isLoaded else { return report(.alreadyStopped(notLoaded: true), job: job, wording: wording) }
        guard job.stopUnloads else { return report(.alreadyStopped(notLoaded: false), job: job, wording: wording) }
        let started = Date()
        let pid = job.pid
        onPhase?("Stopping… unloading so launchd doesn’t restart it")
        let gone = try Launchctl.bootoutAndWait(job, timeout: timeout) { detail, elapsed in
            if let p = detail?.pid ?? pid { onPhase?("Stopping… waiting for PID \(p) to quit (\(Int(elapsed)) s)") }
        }
        guard case .timedOut(_, let left) = gone, let left else {
            return report(.unloaded(pid: pid, seconds: Date().timeIntervalSince(started), wasRestarting: job.status == .restarting),
                          job: job, wording: wording)
        }
        onPhase?("Force quitting PID \(left)…")
        _ = try Launchctl.signal("SIGKILL", job: job)
        if case .timedOut = Launchctl.waitUntilGone(target: job.target, timeout: 5) {
            return stuck(left)
        }
        var r = report(.forceQuit(pid: left), job: job, wording: wording)
        r.summary += " · stays stopped until \(wording.until(job))"
        return r
    }

    /// `ldm stop --no-wait`: send the stop (SIGKILL with `force`) and return.
    public static func sendStop(_ job: Job, force: Bool = false, wording: Wording = .app) throws -> ActionReport {
        if job.restartsOnItsOwn {
            if job.scope.isReadOnly { throw LDError.invalid("launchd keeps this Apple job running; it can’t be stopped here. Restart is available.") }
            guard job.isLoaded else { return report(.alreadyStopped(notLoaded: true), job: job, wording: wording) }
            guard job.stopUnloads else { return report(.alreadyStopped(notLoaded: false), job: job, wording: wording) }
            try Launchctl.bootout(job)
            var summary = "Sent bootout" + (job.pid.map { " · launchd unloads it and stops PID \($0)" } ?? "")
            if force, let pid = job.pid {
                _ = try Launchctl.signal("SIGKILL", job: job)
                summary = "Sent bootout and SIGKILL to PID \(pid)"
            }
            return ActionReport(tone: .success, summary: summary, short: "Stopping", result: "sent")
        }
        guard job.isLoaded, let pid = job.pid else {
            return report(.alreadyStopped(notLoaded: !job.isLoaded), job: job, wording: wording)
        }
        let sig = force ? "SIGKILL" : "SIGTERM"
        if case .alreadyStopped(let notLoaded) = try Launchctl.signal(sig, job: job) {
            return report(.alreadyStopped(notLoaded: notLoaded), job: job, wording: wording)
        }
        return ActionReport(tone: .success, summary: "Sent \(sig) to PID \(pid)", short: "Stopping", result: "sent")
    }

    /// "hup", "SIGHUP", "15" → "SIGHUP", "SIGHUP", "15"; throws for signals the helper doesn't allow.
    public static func signalName(_ sig: String) throws -> String {
        let u = sig.uppercased()
        let name = u.hasPrefix("SIG") || Int(u) != nil ? u : "SIG" + u
        guard HelperPolicy.signals.contains(name) else {
            throw LDError.invalid("Signal \(sig) isn’t supported. Use one of SIGTERM, SIGKILL, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2.")
        }
        return name
    }

    /// Sends any signal the helper allows; the old "Stop" for jobs that handle signals themselves.
    public static func signal(_ sig: String, job: Job) throws -> ActionReport {
        let name = try signalName(sig)
        let notSent = ActionReport(tone: .info, summary: "Not sent — it isn’t running", short: "Not running", result: "alreadyStopped")
        guard job.isLoaded, let pid = job.pid else { return notSent }
        if case .alreadyStopped = try Launchctl.signal(name, job: job) { return notSent }
        // Give it up to 2 s to react.
        var after = job
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.25)
            after = Inventory.reload(job)
            if after.pid != pid { break }
        }
        if after.pid == pid {
            return ActionReport(tone: .success, summary: "Sent \(name) to PID \(pid) · still running", short: "Sent", result: "sent")
        }
        var summary = "Sent \(name) · PID \(pid) quit"
        if let newPid = after.pid {
            summary += " · it started again as PID \(newPid)"
        } else if job.restartsOnItsOwn {
            summary += " · launchd starts it again within \(job.definition.throttleInterval) s"
        }
        return ActionReport(tone: .success, summary: summary, short: "Sent", result: "sent")
    }

    public static func forceQuit(_ job: Job, wording: Wording = .app, onPhase: ((String) -> Void)? = nil) throws -> ActionReport {
        let started = Date()
        if let pid = job.pid { onPhase?("Force quitting PID \(pid)…") }
        let result = try Launchctl.perform(.forceQuit, on: job)
        if case .alreadyStopped(let notLoaded) = result {
            return report(.alreadyStopped(notLoaded: notLoaded), job: job, wording: wording)
        }
        let outcome = StopObserver.observe(job, started: started, timeout: 3, force: true)
        if case .stillRunning(let pid) = outcome { return stuck(pid) }
        return report(outcome, job: job, wording: wording)
    }

    static func stuck(_ pid: Int) -> ActionReport {
        var r = ActionReport(tone: .warning, summary: "PID \(pid) is still there after SIGKILL — it’s stuck in the kernel; restarting the Mac clears it.",
                             short: "Still running", result: "stillRunning")
        r.timedOut = true
        return r
    }

    public static func report(_ outcome: StopOutcome, job: Job, wording: Wording, timeout: TimeInterval = 60) -> ActionReport {
        let until = "stays stopped until \(wording.until(job))"
        switch outcome {
        case .stopped(let pid, let exit, let seconds):
            var text = "Stopped" + (pid.map { " · PID \($0) quit after \(format(seconds))" } ?? "")
            if let exit, ExitCode.isFailure(exit) { text += " · exited \(ExitCode.short(exit))" }
            let s = job.definition.schedule
            if s.startInterval != nil || !s.calendar.isEmpty || !s.watchPaths.isEmpty {
                text += " · launchd starts it again: \(s.summaryInSentence)"
            }
            return ActionReport(tone: .success, summary: text, short: "Stopped", result: "stopped")
        case .unloaded(let pid, let seconds, let wasRestarting):
            let text = wasRestarting ? "Stopped · cancelled launchd’s pending restart · \(until)"
                : pid.map { "Stopped · PID \($0) quit after \(format(seconds)) · \(until)" } ?? "Stopped · \(until)"
            var r = ActionReport(tone: .success, summary: text, short: "Stopped", result: "unloaded")
            r.offerKeepOff = true
            return r
        case .alreadyStopped(let notLoaded):
            return ActionReport(tone: .info, summary: notLoaded ? "Isn’t loaded · nothing to stop" : "Wasn’t running · nothing to stop",
                                short: "Already stopped", result: "alreadyStopped")
        case .willRestart:
            let disable = wording.isCLI ? "`ldm disable \(job.shortName)` keeps it off" : "Keep It Off stops that"
            var r = ActionReport(tone: .warning,
                                 summary: "Stopped, but launchd starts it again within \(job.definition.throttleInterval) s · \(disable)",
                                 short: "Restarting", result: "restartedByLaunchd")
            r.offerKeepOff = true
            return r
        case .restarted(let newPid):
            var r = ActionReport(tone: .warning, summary: "Stopped, but it started again as PID \(newPid)", short: "Started again",
                                 result: "restartedByLaunchd")
            r.offerKeepOff = true
            return r
        case .stillRunning(let pid):
            let text = job.restartsOnItsOwn
                ? "launchd still lists it after \(Launchctl.bootoutWait(job)) s · PID \(pid) hasn’t quit"
                : "Still running as PID \(pid) after \(Int(timeout)) s · it’s ignoring SIGTERM"
            var r = ActionReport(tone: .warning, summary: text, short: "Still running", result: "stillRunning")
            r.timedOut = true
            r.offerForceQuit = true
            return r
        case .forceQuit(let pid):
            return ActionReport(tone: .success, summary: "Force quit" + (pid.map { " · PID \($0) killed with SIGKILL" } ?? ""), short: "Force quit",
                                result: "forceQuit")
        }
    }

    // MARK: Start / Restart

    /// Start (or Run Now / Start Now / Enable & Start, depending on the job's state).
    public static func start(_ job: Job, onPhase: ((String) -> Void)? = nil) throws -> ActionReport {
        if job.launchdState == .stopping, let pid = job.pid {
            onPhase?("Waiting for PID \(pid) to quit before starting…")
        } else if let pid = job.pid {
            return ActionReport(tone: .info, summary: "Already running as PID \(pid)", short: "Running", result: "alreadyRunning")
        }
        let wasRestarting = job.status == .restarting
        let logBefore = RunObserver.logStamp(job)
        onPhase?(job.isLoaded ? "Starting…" : "Loading…")
        _ = try Launchctl.perform(.start, on: job)
        onPhase?("Starting…")
        let started = Date()
        let outcome = RunObserver.observe(job, started: started, logBefore: logBefore)
        if wasRestarting, case .running(let pid) = outcome.result {
            return ActionReport(tone: .success, summary: "Started now instead of waiting out launchd’s restart delay · PID \(pid)", short: "Started",
                                result: "started")
        }
        var r = ActionReport(tone: outcome.succeeded ? .success : .warning, summary: outcome.summary,
                             short: outcome.succeeded ? "Started" : "Didn’t start", result: resultWord(outcome.result))
        r.timedOut = outcome.result == .didNotStart
        return r
    }

    public static func restart(_ job: Job, onPhase: ((String) -> Void)? = nil) throws -> ActionReport {
        if job.status == .restarting || !job.isLoaded || job.pid == nil || job.launchdState == .stopping {
            return try start(job, onPhase: onPhase)
        }
        let oldPid = job.pid
        let logBefore = RunObserver.logStamp(job)
        if let oldPid { onPhase?("Restarting… waiting for PID \(oldPid) to quit") }
        // kickstart -k blocks until the old copy is gone and the throttle has passed.
        _ = try Launchctl.perform(.restart, on: job)
        onPhase?("Restarting… waiting for the new copy")
        let outcome = RunObserver.observe(job, started: Date(), logBefore: logBefore)
        let log = outcome.logChanged.map { $0 ? " · wrote to its log" : " · log unchanged" } ?? ""
        switch outcome.result {
        case .running(let pid):
            let was = oldPid.map { " (was \($0))" } ?? ""
            return ActionReport(tone: .success, summary: "Restarted · now PID \(pid)\(was)\(log)", short: "Restarted", result: "restarted")
        case .finished(let exit):
            if let exit, ExitCode.isFailure(exit) {
                return ActionReport(tone: .warning, summary: "Restarted · ran and failed: \(ExitCode.short(exit))\(log)", short: "Failed", result: "finished")
            }
            return ActionReport(tone: .success, summary: "Restarted · ran and finished" + (exit == 0 ? ", exit 0" : "") + log, short: "Restarted", result: "finished")
        case .didNotStart:
            var r = ActionReport(tone: .warning, summary: "launchd didn’t start a new copy within \(job.definition.throttleInterval + 26) s", short: "Didn’t start",
                                 result: "didNotStart")
            r.timedOut = true
            return r
        }
    }

    // MARK: Unload / Disable

    /// Unload or disable, waiting until launchd has let go of the job.
    public static func takeDown(_ action: Launchctl.Action, _ job: Job, onPhase: ((String) -> Void)? = nil) throws -> ActionReport {
        precondition(action == .unload || action == .disable)
        let pid = job.pid
        if job.isLoaded { onPhase?("Unloading" + (pid.map { " (PID \($0))" } ?? "") + "…") }
        let result = try Launchctl.perform(action, on: job) { detail, elapsed in
            if let p = detail?.pid ?? pid { onPhase?("Unloading (PID \(p), \(Int(elapsed)) s)…") }
        }
        if case .stillUnloading(let p) = result {
            var r = ActionReport(tone: .warning, summary: (action == .disable ? "Disabled, but " : "")
                                 + "launchd still lists it after \(Launchctl.bootoutWait(job)) s" + ((p ?? pid).map { " · PID \($0) hasn’t quit" } ?? ""),
                                 short: "Still running", result: "stillRunning")
            r.timedOut = true
            r.offerForceQuit = (p ?? pid) != nil
            return r
        }
        if action == .disable {
            let what = pid.map { "stopped PID \($0) and won’t start again" } ?? "won’t start again"
            let when = job.scope.isDaemon ? "not even after a restart" : "not even at login"
            return ActionReport(tone: .success, summary: "Off · \(what), \(when)", short: "Off", result: "disabled")
        }
        if case .alreadyStopped = result {
            return ActionReport(tone: .info, summary: "Isn’t loaded · nothing to unload", short: "Not loaded", result: "alreadyStopped")
        }
        let until = job.scope.isDaemon ? "the next restart" : "your next login"
        return ActionReport(tone: .success, summary: "Unloaded" + (pid.map { " · stopped PID \($0)" } ?? "") + " · loads again at \(until)",
                            short: "Unloaded", result: "unloaded")
    }

    /// Unload and load again from the plist on disk. `old` is the job as launchd
    /// has it loaded (pass the pre-edit job when the Label changed).
    public static func reload(_ old: Job, new: Job? = nil, verb: String = "Reloaded", onPhase: ((String) -> Void)? = nil) throws -> ActionReport {
        let fresh = new ?? Inventory.reload(old)
        if let pid = old.pid { onPhase?("Reloading… waiting for the old copy (PID \(pid)) to quit") }
        let result = try Launchctl.reload(old: old, new: fresh) { detail, elapsed in
            if let pid = detail?.pid ?? old.pid { onPhase?("Reloading… waiting for the old copy (PID \(pid)) to quit (\(Int(elapsed)) s)") }
        }
        switch result {
        case .stillUnloading(let pid):
            let p = pid ?? old.pid
            return ActionReport(tone: .warning,
                                summary: "\(verb) · the old copy" + (p.map { " (PID \($0))" } ?? "")
                                    + " didn’t quit within \(Launchctl.bootoutWait(old)) s, so the new settings aren’t loaded yet",
                                short: "Not reloaded", timedOut: true, offerForceQuit: p != nil, result: "stillRunning")
        case .notReloadedDisabled:
            return ActionReport(tone: .info, summary: verb == "Reloaded" ? "Not reloaded · it’s turned off" : "\(verb) · not reloaded because it’s turned off",
                                short: "Off", result: "disabled")
        default:
            onPhase?("Reloading… loading the new settings")
            Thread.sleep(forTimeInterval: 0.5)
            let after = Inventory.reload(fresh)
            return ActionReport(tone: .success, summary: (verb == "Reloaded" ? verb : "\(verb) and reloaded") + (after.pid.map { " · running as PID \($0)" } ?? ""),
                                short: "Reloaded", result: "reloaded")
        }
    }

    static func resultWord(_ r: RunOutcome.Result) -> String {
        switch r {
        case .running: "started"
        case .finished: "finished"
        case .didNotStart: "didNotStart"
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
    }
}
