import Foundation

/// One entry of a domain's "services" table in `launchctl print <domain>`.
public struct ServiceListing: Equatable, Sendable {
    public let label: String
    public let pid: Int?
    public let lastExit: Int?
}

/// Selected fields of `launchctl print <domain>/<label>`.
public struct ServiceDetail: Equatable, Sendable {
    public var state: String?
    public var pid: Int?
    public var runs: Int?
    public var lastExitCode: Int?
    public var lastExitText: String?
    /// "exited", "spawn failed", … (launchctl print's `job state`).
    public var jobState: String?
    /// "OS_REASON_EXEC", "JETSAM_REASON_MEMORY_IDLE_EXIT", … when launchd records one.
    public var lastExitReason: String?
    /// The plist launchd loaded this job from.
    public var path: String?
    public var raw: String = ""
}

/// Thin wrapper over launchctl. `launchctl print` output is explicitly not an
/// API, so every parser here is defensive: unknown lines are ignored.
public enum Launchctl {
    public static let path = "/bin/launchctl"

    // MARK: Reading

    public static func services(in domain: String) -> [String: ServiceListing] {
        servicesIfListed(in: domain) ?? [:]
    }

    /// nil when launchctl couldn't list the domain, so "not listed" can't be read as "not loaded".
    public static func servicesIfListed(in domain: String) -> [String: ServiceListing]? {
        let r = Shell.run(path, ["print", domain])
        return r.succeeded ? parseServices(r.stdout) : nil
    }

    /// A job's listing from its own `print` when the domain listing failed.
    static func listing(fromDetailOf target: String, label: String) -> (ServiceListing, ServiceDetail)? {
        guard let d = detail(target: target) else { return nil }
        return (ServiceListing(label: label, pid: d.pid, lastExit: d.lastExitCode), d)
    }

    public static func parseServices(_ text: String) -> [String: ServiceListing] {
        var result: [String: ServiceListing] = [:]
        var inBlock = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if trimmed == "services = {" { inBlock = true }
                continue
            }
            if trimmed == "}" { break }
            let cols = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 3, let pid = Int(cols[0]) else { continue }
            let label = cols[2...].joined(separator: " ")
            result[label] = ServiceListing(label: label, pid: pid > 0 ? pid : nil, lastExit: Int(cols[1]))
        }
        return result
    }

    /// label → disabled?
    public static func disabledOverrides(in domain: String) -> [String: Bool] {
        parseDisabled(Shell.run(path, ["print-disabled", domain]).stdout)
    }

    public static func parseDisabled(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let arrow = t.range(of: "\" => ") else { continue }
            let label = String(t[t.index(after: t.startIndex)..<arrow.lowerBound])
            let value = t[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            result[label] = (value == "disabled" || value == "true")
        }
        return result
    }

    public static func detail(target: String) -> ServiceDetail? {
        let r = Shell.run(path, ["print", target])
        guard r.succeeded else { return nil }
        return parseDetail(r.stdout)
    }

    public static func parseDetail(_ text: String) -> ServiceDetail {
        var d = ServiceDetail(raw: text)
        // Only top-level fields (one tab deep) belong to the service itself.
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let eq = t.range(of: " = ") else { continue }
            let key = String(t[..<eq.lowerBound])
            let value = String(t[eq.upperBound...])
            switch key {
            case "state": d.state = value
            case "job state": d.jobState = value
            case "last exit reason": d.lastExitReason = value
            case "path": d.path = value
            case "pid": d.pid = Int(value)
            case "runs": d.runs = Int(value)
            case "last exit code":
                // "78: EX_CONFIG", "1", "(never exited)", or "(signal) 15: Terminated: 15"
                let head = value.split(separator: ":").first.map(String.init) ?? value
                if let n = Int(head.trimmingCharacters(in: .whitespaces)) {
                    d.lastExitCode = n
                } else if value.hasPrefix("(signal)") {
                    let rest = value.dropFirst("(signal)".count).trimmingCharacters(in: .whitespaces)
                    if let n = Int(rest.split(separator: ":").first ?? "") { d.lastExitCode = -n }
                }
                d.lastExitText = value
            case "last terminating signal":
                // "Terminated: 15"
                if let n = Int(value.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") {
                    d.lastExitCode = -n
                }
                d.lastExitText = value
            default: break
            }
        }
        return d
    }

    // MARK: Changing

    public enum Action: String, CaseIterable, Sendable {
        case start, stop, restart, load, unload, enable, disable, forceQuit
    }

    /// One step of an action: a launchctl call, or a wait until launchd has let go of a job.
    public enum Step: Equatable, Sendable {
        case run([String])
        case waitUntilGone(target: String, seconds: Int)

        public var rendered: String {
            switch self {
            case .run(let argv): Shell.commandLine(argv)
            case .waitUntilGone(_, let s): "(then wait until launchctl print reports it gone, up to \(s) s)"
            }
        }
    }

    /// How an action ended when it wasn't a plain "done".
    public enum Result: Equatable, Sendable {
        case done
        case alreadyStopped(notLoaded: Bool)
        case alreadyRunning(pid: Int)
        /// The unload was sent but launchd still lists the job after the wait.
        case stillUnloading(pid: Int?)
        /// Saved, but not reloaded: the job is turned off.
        case notReloadedDisabled
    }

    public enum GoneResult: Equatable, Sendable {
        case gone
        case timedOut(state: String?, pid: Int?)
    }

    /// Runs one launchctl invocation, as root when `admin`. Tests replace it.
    public static var runner: (_ argv: [String], _ admin: Bool) -> ShellResult = { argv, admin in
        admin ? Privileged.launchctl([argv]) : Shell.run(argv[0], Array(argv.dropFirst()), timeout: 60)
    }
    /// Tests replace these to run without real time passing.
    public static var sleeper: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    public static var clock: () -> Date = { Date() }

    /// How long to wait for launchd to finish unloading: the job's ExitTimeOut
    /// (after which launchd sends SIGKILL itself) plus a margin.
    public static func bootoutWait(_ job: Job) -> Int {
        min(max(job.definition.exitTimeOut, 1), 55) + 5
    }

    /// The steps an action takes for this job, in order (shown by --dry-run).
    public static func plan(for action: Action, job: Job) -> [Step] {
        let domain = job.scope.domain, target = job.target, plist = job.definition.url.path
        let load: [Step] = [.run([path, "bootstrap", domain, plist])]
        let unload: [Step] = [.run([path, "bootout", target]), .waitUntilGone(target: target, seconds: bootoutWait(job))]
        switch action {
        case .start:
            if job.pid != nil && job.launchdState != .stopping { return [] }
            let enable: [Step] = job.isDisabled ? [.run([path, "enable", target])] : []
            return enable + (job.isLoaded ? [] : load) + [.run([path, "kickstart", target])]
        case .restart:
            return job.isLoaded ? [.run([path, "kickstart", "-k", target])] : load + [.run([path, "kickstart", target])]
        case .stop:
            guard job.isLoaded else { return [] }
            if job.restartsOnItsOwn { return job.stopUnloads ? unload : [] }
            return job.pid == nil ? [] : [.run([path, "kill", "SIGTERM", target])]
        case .forceQuit:
            return job.pid == nil ? [] : [.run([path, "kill", "SIGKILL", target])]
        case .load:
            return job.isLoaded ? [] : load
        case .unload:
            return job.isLoaded ? unload : []
        case .enable:
            return [.run([path, "enable", target])] + (job.isLoaded ? [] : load)
        case .disable:
            return (job.isLoaded ? unload : []) + [.run([path, "disable", target])]
        }
    }

    /// The launchctl invocations of an action, without the waits.
    public static func commands(for action: Action, job: Job) -> [[String]] {
        plan(for: action, job: job).compactMap { if case .run(let argv) = $0 { argv } else { nil } }
    }

    /// Performs an action. Pass a freshly reloaded job: the steps depend on its state.
    /// Throws `LDError.launchctl` (with the command, exit code and an explanation)
    /// when launchd refuses; "already stopped / running" are results, not errors.
    @discardableResult
    public static func perform(_ action: Action, on job: Job,
                               onTick: ((ServiceDetail?, TimeInterval) -> Void)? = nil) throws -> Result {
        let readOnlyAllowed: Set<Action> = [.start, .stop, .restart, .forceQuit]
        if job.scope.isReadOnly && !readOnlyAllowed.contains(action) { throw LDError.readOnly(job.label) }
        let admin = job.scope.launchctlNeedsAdmin
        let target = job.target

        switch action {
        case .stop:
            if job.restartsOnItsOwn {
                if job.scope.isReadOnly {
                    throw LDError.invalid("launchd keeps this Apple job running; it can’t be stopped here. Restart is available.")
                }
                guard job.isLoaded else { return .alreadyStopped(notLoaded: true) }
                guard job.stopUnloads else { return .alreadyStopped(notLoaded: false) }
                switch try bootoutAndWait(job, onTick: onTick) {
                case .gone: return .done
                case .timedOut(_, let pid): return .stillUnloading(pid: pid)
                }
            }
            guard job.isLoaded else { return .alreadyStopped(notLoaded: true) }
            guard job.pid != nil else { return .alreadyStopped(notLoaded: false) }
            return try signal("SIGTERM", job: job)

        case .forceQuit:
            guard job.pid != nil else { return .alreadyStopped(notLoaded: !job.isLoaded) }
            return try signal("SIGKILL", job: job)

        case .start:
            var loaded = job.isLoaded
            if job.launchdState == .stopping {
                // The old copy is still quitting: let it go first, or the start is lost.
                let state = waitWhileStopping(target, timeout: TimeInterval(bootoutWait(job)))
                if state == nil { loaded = false } else if let pid = state?.pid, state?.state != "SIGTERMed" { return .alreadyRunning(pid: pid) }
            } else if let pid = job.pid {
                return .alreadyRunning(pid: pid)
            }
            if job.isDisabled { try check(run([path, "enable", target], admin), [path, "enable", target]) }
            if !loaded { try bootstrapRetrying(job) }
            let kick = [path, "kickstart", target]
            var r = run(kick, admin)
            if r.status == 113 {
                // Unloaded between our read and the kickstart: load it and try once more.
                try bootstrapRetrying(job)
                r = run(kick, admin)
            }
            try check(r, kick)
            return .done

        case .restart:
            if !job.isLoaded {
                try bootstrapRetrying(job)
                let kick = [path, "kickstart", target]
                try check(run(kick, admin), kick)
                return .done
            }
            let kick = [path, "kickstart", "-k", target]
            try check(run(kick, admin), kick)
            return .done

        case .load:
            guard !job.isLoaded else { return .done }
            try bootstrapRetrying(job)
            return .done

        case .unload:
            guard job.isLoaded else { return .alreadyStopped(notLoaded: true) }
            switch try bootoutAndWait(job, onTick: onTick) {
            case .gone: return .done
            case .timedOut(_, let pid): return .stillUnloading(pid: pid)
            }

        case .enable:
            let argv = [path, "enable", target]
            try check(run(argv, admin), argv)
            if !job.isLoaded { try bootstrapRetrying(job) }
            return .done

        case .disable:
            var result = Result.done
            if job.isLoaded, case .timedOut(_, let pid) = try bootoutAndWait(job, onTick: onTick) {
                result = .stillUnloading(pid: pid)
            }
            let argv = [path, "disable", target]
            try check(run(argv, admin), argv)
            return result
        }
    }

    /// Unloads a job and reloads it from its (possibly edited) plist without
    /// tripping over launchd finishing the unload in the background.
    public static func reload(old: Job, new: Job, onTick: ((ServiceDetail?, TimeInterval) -> Void)? = nil) throws -> Result {
        // A disabled job can't be loaded again; unloading it would just take it down.
        if new.isDisabled { return .notReloadedDisabled }
        if old.isLoaded, case .timedOut(_, let pid) = try bootoutAndWait(old, onTick: onTick) {
            return .stillUnloading(pid: pid)
        }
        try bootstrapRetrying(new)
        return .done
    }

    // MARK: Primitives

    /// Polls until launchd has finished stopping a SIGTERMed job. Returns its state
    /// then, or nil once it is no longer loaded.
    static func waitWhileStopping(_ target: String, timeout: TimeInterval) -> ServiceDetail? {
        let start = clock()
        while true {
            guard let d = parseDetailIfLoaded(target) else { return nil }
            if d.state != "SIGTERMed" || clock().timeIntervalSince(start) >= timeout { return d }
            sleeper(0.2)
        }
    }

    /// Every state-changing launchctl call goes through here, so an action can list what it ran.
    static func run(_ argv: [String], _ admin: Bool) -> ShellResult {
        CommandLog.current?.append(argv)
        return runner(argv, admin)
    }

    public static func signal(_ sig: String, job: Job) throws -> Result {
        let argv = [path, "kill", sig, job.target]
        let r = run(argv, job.scope.launchctlNeedsAdmin)
        // 3: no process to signal; 113: not loaded. Both mean "already stopped".
        if r.status == 3 || r.status == 113 { return .alreadyStopped(notLoaded: r.status == 113) }
        try check(r, argv)
        return .done
    }

    /// Polls `launchctl print` (never privileged) until launchd no longer lists the job.
    public static func waitUntilGone(target: String, timeout: TimeInterval,
                                     onTick: ((ServiceDetail?, TimeInterval) -> Void)? = nil) -> GoneResult {
        let start = clock()
        let parts = target.split(separator: "/")
        let domain = parts.dropLast().joined(separator: "/")
        let label = parts.last.map(String.init) ?? target
        while true {
            let r = runner([path, "print", target], false)
            if r.status == 113 { return .gone }
            var detail: ServiceDetail?
            if r.succeeded {
                detail = parseDetail(r.stdout)
            } else if parseServices(runner([path, "print", domain], false).stdout)[label] == nil {
                return .gone
            }
            let elapsed = clock().timeIntervalSince(start)
            onTick?(detail, elapsed)
            if elapsed >= timeout { return .timedOut(state: detail?.state, pid: detail?.pid) }
            sleeper(0.2)
        }
    }

    /// `bootout`, then wait until launchd has really let go of the job.
    public static func bootoutAndWait(_ job: Job, timeout: TimeInterval? = nil,
                                      onTick: ((ServiceDetail?, TimeInterval) -> Void)? = nil) throws -> GoneResult {
        try bootout(job)
        return waitUntilGone(target: job.target, timeout: timeout ?? TimeInterval(bootoutWait(job)), onTick: onTick)
    }

    /// Sends `bootout` without waiting for launchd to finish. Not loaded counts as done.
    public static func bootout(_ job: Job) throws {
        let argv = [path, "bootout", job.target]
        let r = run(argv, job.scope.launchctlNeedsAdmin)
        if !r.succeeded && r.status != 3 && r.status != 113 { try check(r, argv) }
    }

    /// `bootstrap`, riding out the moments after an unload when launchd still
    /// holds the old copy (it answers 5 or 37 then).
    public static func bootstrapRetrying(_ job: Job) throws {
        let admin = job.scope.launchctlNeedsAdmin
        let argv = [path, "bootstrap", job.scope.domain, job.definition.url.path]
        let wait = TimeInterval(bootoutWait(job))
        if parseDetailIfLoaded(job.target)?.state == "SIGTERMed" {
            _ = waitUntilGone(target: job.target, timeout: wait)
        }
        var delays: [TimeInterval] = [0.5, 1, 2]
        while true {
            let r = run(argv, admin)
            if r.succeeded { return }
            guard [5, 17, 37].contains(r.status) else { try check(r, argv); return }
            if let d = parseDetailIfLoaded(job.target) {
                if d.state == "SIGTERMed" {
                    _ = waitUntilGone(target: job.target, timeout: wait)
                } else if let other = d.path, !samePath(other, job.definition.url.path) {
                    throw LDError.launchctl(LaunchctlFailure(argv: argv, status: 17, stderr: "Already loaded from \(other)",
                                                             stdout: "", title: job.title))
                } else {
                    return  // It is loaded after all.
                }
            } else if parseDisabled(runner([path, "print-disabled", job.scope.domain], false).stdout)[job.label] == true {
                throw LDError.launchctl(LaunchctlFailure(argv: argv, status: 119, stderr: "Service is disabled", stdout: "", title: job.title))
            } else if hasQuarantine(job.definition.url.path) {
                throw LDError.launchctl(LaunchctlFailure(argv: argv, status: r.status, stderr: r.stderr, stdout: r.stdout,
                                                         title: job.title, quarantinedPlist: true))
            }
            guard !delays.isEmpty else { try check(r, argv); return }
            sleeper(delays.removeFirst())
        }
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    static func parseDetailIfLoaded(_ target: String) -> ServiceDetail? {
        let r = runner([path, "print", target], false)
        return r.succeeded ? parseDetail(r.stdout) : nil
    }

    static func hasQuarantine(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// Throws a descriptive error unless the command succeeded.
    static func check(_ r: ShellResult, _ argv: [String]) throws {
        if r.succeeded { return }
        if r.status == 4 && r.message.lowercased().contains("cancel") { throw LDError.authorizationCancelled }
        throw LDError.launchctl(LaunchctlFailure(argv: argv, status: r.status, stderr: r.stderr, stdout: r.stdout))
    }

    // MARK: Explaining failures

    /// Plain-language explanation of a launchctl failure, by verb and exit status.
    public static func explain(verb: String, status: Int32, message: String, title: String? = nil,
                               quarantinedPlist: Bool = false) -> String {
        let name = title.map { "“\($0)”" } ?? "This job"
        if quarantinedPlist {
            return "launchd won’t load a plist that carries macOS’s quarantine flag (it was downloaded). Remove the flag to load it."
        }
        switch status {
        case Shell.timedOutStatus: return "launchctl \(verb) didn’t return within 60 s."
        case -1 where message.isEmpty || message.contains("helper"):
            return "LD Manager’s helper didn’t answer. Repair it in the sidebar, or try again."
        case -1: return message
        case 64: return "LD Manager’s helper refused: \(message)"
        case 1 where message.contains("helper refused") || message.contains("isn’t allowed") || message.contains("Only "):
            return "LD Manager’s helper refused: \(message)"
        case 1: return "This needs administrator rights."
        case 3: return "launchd says there’s no such process."
        case 5 where verb == "bootstrap":
            return "launchd refused to load it. The plist may be invalid (check with ldm doctor), or the old copy is still shutting down — try again in a few seconds."
        case 5: return "launchd reported an input/output error."
        case 16: return "launchd is busy with this job. Try again in a few seconds."
        case 17 where verb == "bootstrap": return "launchd already has a job with this Label, loaded from another file (\(message.replacingOccurrences(of: "Already loaded from ", with: "")))."
        case 22: return "launchd rejected the request as invalid."
        case 37: return "launchd is already doing something with this job (or it’s already loaded). Try again in a few seconds."
        case 113: return "launchd doesn’t have this job loaded."
        case 119: return "\(name) is disabled. Turn on Keep this job active first."
        case 125, 134: return "launchd can’t do that for this kind of job."
        case 150: return "macOS protects this Apple job (System Integrity Protection)."
        default: return "launchd rejected the request."
        }
    }

    /// launchd's own text for an error code, e.g. 5 → "Input/output error".
    static func describe(status: Int32) -> String {
        let known: [Int32: String] = [
            1: "Operation not permitted", 3: "No such process", 5: "Input/output error", 16: "Resource busy",
            17: "File exists", 22: "Invalid argument", 37: "Operation already in progress",
            113: "Could not find specified service", 119: "Service is disabled",
            125: "Domain does not support specified action", 134: "Service cannot load in requested session",
            150: "Operation not permitted while System Integrity Protection is engaged",
        ]
        if let k = known[status] { return k }
        if status > 0 {
            let r = Shell.run(path, ["error", String(status)], timeout: 5)
            let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.succeeded, !t.isEmpty { return t }
        }
        return "exit status \(status)"
    }
}

/// A launchctl command that failed: what ran, how it exited and why.
public struct LaunchctlFailure: Equatable, Sendable {
    public let argv: [String]
    public let status: Int32
    public let stderr: String
    public let stdout: String
    public var title: String?
    public var quarantinedPlist = false

    public init(argv: [String], status: Int32, stderr: String, stdout: String, title: String? = nil, quarantinedPlist: Bool = false) {
        self.argv = argv
        self.status = status
        self.stderr = stderr
        self.stdout = stdout
        self.title = title
        self.quarantinedPlist = quarantinedPlist
    }

    public var verb: String { argv.count > 1 ? argv[1] : "" }

    /// What launchctl said, or launchd's text for the code when it said nothing.
    public var message: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e.replacingOccurrences(of: "\nTry re-running the command as root for richer errors.", with: "") }
        let o = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.isEmpty ? Launchctl.describe(status: status) : o
    }

    public var explanation: String {
        Launchctl.explain(verb: verb, status: status, message: message, title: title, quarantinedPlist: quarantinedPlist)
    }

    /// "/bin/launchctl kill SIGTERM gui/501/com.x → exit 3: No process to signal."
    public var details: String { "\(Shell.commandLine(argv)) → exit \(status): \(message)" }
}

/// Collects the launchctl commands an action ran, for its outcome's details.
public final class CommandLog: @unchecked Sendable {
    @TaskLocal public static var current: CommandLog?
    private let lock = NSLock()
    private var argvs: [[String]] = []

    public init() {}

    func append(_ argv: [String]) {
        lock.lock()
        argvs.append(argv)
        lock.unlock()
    }

    public var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return argvs
    }
}

public enum LDError: LocalizedError, Equatable {
    case readOnly(String)
    case authorizationCancelled
    case launchd(String)
    case launchctl(LaunchctlFailure)
    case notFound(String)
    case ambiguous(String, [String])
    case invalid(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .readOnly(let l): "\(l) is an Apple job on the read-only system volume."
        case .authorizationCancelled: "Administrator authorization was cancelled."
        case .launchd(let m): m
        case .launchctl(let f): "\(f.explanation) (launchctl \(f.verb) exited \(f.status): \(f.message))"
        case .notFound(let q): "No job matches “\(q)”."
        case .ambiguous(let q, let c): "“\(q)” matches \(c.count) jobs: \(c.prefix(6).joined(separator: ", "))\(c.count > 6 ? ", …" : "")"
        case .invalid(let m): m
        case .io(let m): m
        }
    }
}
