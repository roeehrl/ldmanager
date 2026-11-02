import Foundation

/// What happened after asking launchd to run a job. Many jobs (periodic checks,
/// one-shot scripts) run for a moment and exit, so "it isn't running" right
/// after Start is normal; this tells that apart from a job that never started.
public struct RunOutcome: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        /// Still running after the settle time: a long-lived job.
        case running(pid: Int)
        /// Ran and exited (nil if launchd didn't report an exit status).
        case finished(exit: Int?)
        /// No new launch was recorded before the timeout.
        case didNotStart
    }

    public let result: Result
    public let started: Date
    /// nil when the job has no log file.
    public let logChanged: Bool?

    public var succeeded: Bool {
        switch result {
        case .running: true
        case .finished(let exit): exit == nil || exit == 0
        case .didNotStart: false
        }
    }

    /// "Ran and finished, exit 0 · log unchanged"
    public var summary: String {
        var text: String
        switch result {
        case .running(let pid): text = "Running now as PID \(pid)"
        case .finished(let exit?) where exit != 0: text = "Ran and failed: \(ExitCode.short(exit))"
        case .finished(let exit): text = "Ran and finished" + (exit == 0 ? ", exit 0" : "")
        case .didNotStart: text = "launchd didn’t start it within a few seconds"
        }
        switch logChanged {
        case true?: text += " · wrote to its log"
        case false?: text += " · log unchanged"
        case nil: break
        }
        return text
    }
}

public enum RunObserver {
    /// Latest modification time across the job's log files.
    public static func logStamp(_ job: Job) -> Date? {
        LogReader.logPaths(for: job).compactMap { path in
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }.max()
    }

    /// Polls launchd until the run started at `started` has an outcome.
    /// `before` is the job as it was just before the start. A KeepAlive job counts
    /// as running once it has stayed up for a moment; any other job is followed
    /// until it exits (up to `maxRun`), since a check or script can take a while.
    public static func observe(_ before: Job, started: Date, logBefore: Date?, maxRun: TimeInterval = 30) -> RunOutcome {
        let keepsRunning = before.definition.keepAlive.map { $0 != .never } ?? false
        let settle: TimeInterval = keepsRunning ? 1.5 : maxRun
        let timeout = keepsRunning ? 6 : maxRun + 1
        let runsBefore = before.runs ?? 0
        let pidBefore = before.pid
        let hasLog = !LogReader.logPaths(for: before).isEmpty
        let deadline = started.addingTimeInterval(timeout)
        var job = before
        var launched = false
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            job = Inventory.reload(job)
            // A new launch: more runs, or a different PID. An old PID that is still
            // shutting down (restart) is not a launch.
            if (job.runs ?? 0) > runsBefore || (job.pid != nil && job.pid != pidBefore) { launched = true }
            if let pid = job.pid, launched {
                if Date().timeIntervalSince(started) >= settle { return outcome(.running(pid: pid)) }
            } else if launched, job.pid == nil {
                return outcome(.finished(exit: job.lastExit))
            }
        }
        if let pid = job.pid, launched { return outcome(.running(pid: pid)) }
        return outcome(launched ? .finished(exit: job.lastExit) : .didNotStart)

        func outcome(_ r: RunOutcome.Result) -> RunOutcome {
            let after = logStamp(job)
            let changed: Bool? = hasLog ? (after.map { a in logBefore.map { a > $0 } ?? true } ?? false) : nil
            return RunOutcome(result: r, started: started, logChanged: changed)
        }
    }
}

/// What happened after Stop / Force Quit / unload.
public enum StopOutcome: Equatable, Sendable {
    /// The process exited; the job stays loaded (no KeepAlive).
    case stopped(pid: Int?, exit: Int?, seconds: TimeInterval)
    /// Unloaded so launchd doesn't restart it (KeepAlive).
    case unloaded(pid: Int?, seconds: TimeInterval, wasRestarting: Bool)
    case alreadyStopped(notLoaded: Bool)
    /// Something (KeepAlive, its app, another tool) started it again.
    case restarted(newPid: Int)
    /// It quit, but launchd has already scheduled a restart (its loaded copy keeps it alive).
    case willRestart
    /// Still there when we gave up waiting.
    case stillRunning(pid: Int)
    case forceQuit(pid: Int?)

    public var succeeded: Bool {
        switch self {
        case .stopped, .unloaded, .alreadyStopped, .forceQuit: true
        case .restarted, .willRestart, .stillRunning: false
        }
    }
}

public enum StopObserver {
    /// Follows a signal-based stop (no KeepAlive) until the process is gone, a new
    /// one appears, or `timeout` passes. `before` is the job just before the signal.
    public static func observe(_ before: Job, started: Date, timeout: TimeInterval = 60, force: Bool = false,
                               reload: (Job) -> Job = { Inventory.reload($0) },
                               sleeper: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                               clock: () -> Date = { Date() },
                               onTick: ((Job, TimeInterval) -> Void)? = nil) -> StopOutcome {
        let pidBefore = before.pid
        var job = before
        while true {
            sleeper(0.25)
            job = reload(job)
            let elapsed = clock().timeIntervalSince(started)
            onTick?(job, elapsed)
            if let pid = job.pid, pid != pidBefore { return .restarted(newPid: pid) }
            if job.pid == nil {
                if !force && (job.launchdState == .spawnScheduled || (job.runs ?? 0) > (before.runs ?? 0)) { return .willRestart }
                return force ? .forceQuit(pid: pidBefore) : .stopped(pid: pidBefore, exit: job.lastExit, seconds: elapsed)
            }
            if elapsed >= timeout { return .stillRunning(pid: job.pid ?? pidBefore ?? 0) }
        }
    }
}
