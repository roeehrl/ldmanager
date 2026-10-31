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
        let hasLog = !LogReader.logPaths(for: before).isEmpty
        let deadline = started.addingTimeInterval(timeout)
        var job = before
        var launched = false
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            job = Inventory.reload(job)
            if (job.runs ?? 0) > runsBefore { launched = true }
            if let pid = job.pid {
                launched = true
                if Date().timeIntervalSince(started) >= settle { return outcome(.running(pid: pid)) }
            } else if launched {
                return outcome(.finished(exit: job.lastExit))
            }
        }
        if let pid = job.pid { return outcome(.running(pid: pid)) }
        return outcome(launched ? .finished(exit: job.lastExit) : .didNotStart)

        func outcome(_ r: RunOutcome.Result) -> RunOutcome {
            let after = logStamp(job)
            let changed: Bool? = hasLog ? (after.map { a in logBefore.map { a > $0 } ?? true } ?? false) : nil
            return RunOutcome(result: r, started: started, logChanged: changed)
        }
    }
}
