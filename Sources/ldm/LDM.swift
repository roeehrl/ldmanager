import ArgumentParser
import Foundation
import LDCore

@main
struct LDM: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ldm",
        abstract: "See, diagnose and manage launchd jobs.",
        discussion: """
        Examples:
          ldm list --status failed
          ldm doctor
          ldm show ollama --json
          ldm enable nightly-backup --dry-run
          ldm new backup --every 6h -- /usr/local/bin/backup.sh
          ldm logs ollama -n 50

        A job can be named by its full label, its last label component, its file
        name, or any unique part of its label.

        Exit codes: 0 ok · 1 error · 2 usage or ambiguous name · 3 no such job ·
        4 authorization needed or cancelled · 5 launchd rejected the operation ·
        6 doctor found problems.
        """,
        version: "0.1.1",
        subcommands: [List.self, Show.self, Doctor.self, Start.self, Stop.self, Restart.self, Load.self, Unload.self,
                      Enable.self, Disable.self, Logs.self, New.self, Edit.self, Remove.self, Explain.self, HelperStatus.self]
    )
}

struct Common: ParsableArguments {
    @Flag(help: "Output JSON (stable for scripts).") var json = false
    @Flag(name: .customLong("no-color"), help: "Disable colors.") var noColor = false
    @Flag(help: "Include Apple's jobs on the system volume.") var apple = false
    @Flag(help: "Re-read Login Items › App Background Activity. macOS asks for your password; otherwise the last result is used.")
    var background = false

    func setup() { if noColor { Style.enabled = false } }

    /// Background Items: freshly read (one password prompt) with --background, otherwise the cached result.
    func backgroundSnapshot() -> BackgroundItems.Snapshot? {
        if background {
            if let fresh = BackgroundItems.refresh() { return fresh }
            printErr(Style.orange("note: ") + "couldn’t read Login Items (cancelled?); using the last result.")
        }
        return BackgroundItems.cached()
    }

    func loadJobs(details: Bool = true) -> [Job] {
        var scopes: [JobScope] = [.user, .allUsers, .system]
        if apple { scopes += [.appleAgent, .appleDaemon] }
        return Inventory.load(.init(scopes: scopes, details: details, background: backgroundSnapshot()))
    }

    /// Resolves a name and reloads the job with every layer.
    func resolveFull(_ name: String) throws -> Job {
        Inventory.reload(try resolve(name), background: backgroundSnapshot())
    }

    func resolve(_ name: String) throws -> Job {
        do {
            return try Inventory.resolve(name, in: loadJobs(details: false))
        } catch LDError.notFound(let q) where !apple {
            // Fall back to Apple's jobs before giving up.
            let all = Inventory.load(.init(scopes: [.appleAgent, .appleDaemon], details: false))
            if let j = try? Inventory.resolve(q, in: all) { return j }
            throw LDError.notFound(q)
        }
    }
}

/// Runs a body and maps LDError to documented exit codes.
func guarded(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let e as LDError {
        printErr(Style.red("error: ") + (e.errorDescription ?? "\(e)"))
        throw ExitCode(Exit.code(for: e))
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List jobs with their status, schedule and last result.")

    enum Filter: String, ExpressibleByArgument, CaseIterable { case all, running, failed, disabled, problems }

    @OptionGroup var common: Common
    @Option(help: "Filter: \(Filter.allCases.map(\.rawValue).joined(separator: ", ")).") var status: Filter = .all
    @Option(help: "Only one scope: user, allUsers, system, appleAgent, appleDaemon.") var scope: String?
    @Flag(help: "One label per line, no decoration.") var plain = false

    func run() throws {
        common.setup()
        var jobs = common.loadJobs()
        if let s = scope {
            guard let sc = JobScope(rawValue: s) else { throw ValidationError("Unknown scope \(s).") }
            jobs = jobs.filter { $0.scope == sc }
        }
        switch status {
        case .all: break
        case .running: jobs = jobs.filter { $0.status == .running }
        case .failed: jobs = jobs.filter { $0.status == .failed || $0.status == .invalid }
        case .disabled: jobs = jobs.filter { $0.status == .disabled || $0.status == .blocked }
        case .problems:
            let labels = Set(LDCore.Doctor.problems(in: jobs).map(\.job.id))
            jobs = jobs.filter { labels.contains($0.id) }
        }
        jobs.sort { ($0.status.rank, $0.label) < ($1.status.rank, $1.label) }

        if common.json { return emitJSON(jobs.map(JobJSON.init)) }
        if plain { jobs.forEach { print($0.label) }; return }
        if jobs.isEmpty { print(Style.dim("No jobs match.")); return }
        print(Style.dim(pad("STATUS", 11) + pad("JOB", 42) + pad("WHEN", 30) + "RESULT"))
        for j in jobs {
            let result = j.status == .failed || j.status == .invalid ? Style.orange(j.resultSummary) : j.resultSummary
            print(Style.status(j.status) + " " + pad(j.label, 42) + pad(j.definition.schedule.summary, 30) + result)
        }
    }
}

// MARK: - show

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show everything about one job: plist, launchd state, override, schedule.")

    @OptionGroup var common: Common
    @Argument(help: "Job name or label.") var name: String

    func run() throws {
        common.setup()
        try guarded {
            let job = try common.resolveFull(name)
            if common.json { return emitJSON(JobJSON(job)) }
            let d = job.definition
            print(Style.bold(job.title) + "  " + Style.dim(job.label))
            func row(_ k: String, _ v: String) { print("  " + Style.dim(pad(k, 14)) + v) }
            row("status", Style.status(job.status).trimmingCharacters(in: .whitespaces) + (job.pid.map { " · pid \($0)" } ?? ""))
            row("kind", "\(job.scope.kind) · \(job.target)")
            row("plist", LDCore.Doctor.abbreviate(d.url.path))
            row("runs", Shell.commandLine(d.commandLine))
            row("when", d.schedule.summary)
            let next = d.schedule.nextRuns(count: 3)
            if !next.isEmpty { row("next", next.map { $0.formatted(date: .abbreviated, time: .shortened) }.joined(separator: " · ")) }
            row("override", job.override.map { $0 ? "disabled" : "enabled" } ?? "none")
            if let snap = BackgroundItems.cached() {
                row("background", (job.background.map { b in b.summary + (b.owner.map { " · \($0)" } ?? "") } ?? "not listed in Login Items")
                    + Style.dim("  (read \(snap.date.formatted(.relative(presentation: .named))))"))
            } else {
                row("background", Style.dim("not read yet — run with --background (asks for your password)"))
            }
            if let r = job.runs { row("launches", r.formatted()) }
            if let e = job.lastExit { row("last exit", ExitCode.explain(e)) }
            for p in LogReader.logPaths(for: job) { row("log", LDCore.Doctor.abbreviate(p)) }
        }
    }
}

// MARK: - doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Explain why jobs aren't running and how to fix them. Exits 6 if problems are found.")

    @OptionGroup var common: Common
    @Argument(help: "Check one job (default: every job).") var name: String?

    func run() throws {
        common.setup()
        var found = false
        try guarded {
            let diagnoses: [Diagnosis]
            if let n = name {
                diagnoses = [LDCore.Doctor.diagnose(try common.resolveFull(n))]
            } else {
                diagnoses = LDCore.Doctor.problems(in: common.loadJobs())
            }
            found = diagnoses.contains { $0.isProblem }
            if common.json { return emitJSON(diagnoses.map(DiagnosisJSON.init)) }
            if diagnoses.isEmpty { print(Style.green("✓ ") + "No problems found."); return }
            for (i, d) in diagnoses.enumerated() {
                if i > 0 { print("") }
                let headline = d.primary?.headline ?? "No problems"
                print(Style.bold("\(d.job.title): \(headline)") + "  " + Style.dim(d.job.label))
                for c in d.checks {
                    let mark = c.passed == true ? Style.green("✓") : c.passed == false ? Style.red("✗") : Style.dim("–")
                    print("  \(mark) \(c.name)" + (c.note.map { Style.dim(" — \($0)") } ?? ""))
                }
                for f in d.findings where f.severity >= .warning {
                    print("  " + Style.dim("why: ") + f.detail)
                    let cli = f.fixes.compactMap { cliHint(for: $0, job: d.job) }
                    if let first = cli.first { print("  " + Style.dim("fix: ") + first) }
                    for more in cli.dropFirst() { print("       " + Style.dim(more)) }
                }
            }
        }
        if found { throw ExitCode(Exit.problems) }
    }

    func cliHint(for fix: Fix, job: Job) -> String? {
        let n = job.shortName
        switch fix {
        case .disable: return "ldm disable \(n)"
        case .load: return "ldm load \(n)"
        case .chooseProgram: return "ldm edit \(n) --program /path/to/program"
        case .editPlist: return "open \(Shell.quote(job.definition.url.path))"
        case .openTerminal(let dir): return "cd \(Shell.quote(dir))"
        case .removeQuarantine(let p): return "xattr -d com.apple.quarantine \(Shell.quote(p))"
        case .createDirectory(let p): return "mkdir -p \(Shell.quote(p))"
        case .fixPermissions: return job.scope == .user ? "chmod 644 \(Shell.quote(job.definition.url.path))" : "sudo chown root:wheel \(Shell.quote(job.definition.url.path)) && sudo chmod 644 \(Shell.quote(job.definition.url.path))"
        case .openLoginItems: return "open \"\(BackgroundItems.settingsURL.absoluteString)\""
        case .revealPlist: return nil
        }
    }
}

// MARK: - actions

protocol ActionCommand: ParsableCommand {
    static var action: Launchctl.Action { get }
    var common: Common { get }
    var name: String { get }
    var dryRun: Bool { get }
}

extension ActionCommand {
    func run() throws {
        common.setup()
        try guarded {
            let job = Inventory.reload(try common.resolve(name))
            let cmds = Launchctl.commands(for: Self.action, job: job)
            if dryRun {
                print(Style.dim(cmds.isEmpty ? "nothing to do" : "would run" + (job.scope.launchctlNeedsAdmin ? " (as administrator):" : ":")))
                cmds.forEach { print("  " + Shell.commandLine($0)) }
                return
            }
            try Launchctl.perform(Self.action, on: job)
            let after = Inventory.reload(job)
            if common.json { return emitJSON(JobJSON(after)) }
            print(Style.green("✓ ") + "\(Self.action.rawValue) \(job.label)  " + Style.dim(after.status.title))
        }
    }
}

struct Start: ActionCommand {
    static let configuration = CommandConfiguration(abstract: "Run a job now (loads it first if needed).")
    static let action = Launchctl.Action.start
    @OptionGroup var common: Common
    @Argument var name: String
    @Flag(name: [.customShort("n"), .long], help: "Print the launchctl commands instead of running them.") var dryRun = false
}

struct Stop: ActionCommand {
    static let configuration = CommandConfiguration(abstract: "Send SIGTERM to a running job. KeepAlive jobs restart; use disable to keep them down.")
    static let action = Launchctl.Action.stop
    @OptionGroup var common: Common
    @Argument var name: String
    @Flag(name: [.customShort("n"), .long], help: "Print the launchctl commands instead of running them.") var dryRun = false
}

struct Restart: ActionCommand {
    static let configuration = CommandConfiguration(abstract: "Kill and immediately restart a job.")
    static let action = Launchctl.Action.restart
    @OptionGroup var common: Common
    @Argument var name: String
    @Flag(name: [.customShort("n"), .long], help: "Print the launchctl commands instead of running them.") var dryRun = false
}

struct Load: ActionCommand {
    static let configuration = CommandConfiguration(abstract: "Load (bootstrap) a job into launchd.")
    static let action = Launchctl.Action.load
    @OptionGroup var common: Common
    @Argument var name: String
    @Flag(name: [.customShort("n"), .long], help: "Print the launchctl commands instead of running them.") var dryRun = false
}

struct Unload: ActionCommand {
    static let configuration = CommandConfiguration(abstract: "Unload (bootout) a job from launchd until next login or boot.")
    static let action = Launchctl.Action.unload
    @OptionGroup var common: Common
    @Argument var name: String
    @Flag(name: [.customShort("n"), .long], help: "Print the launchctl commands instead of running them.") var dryRun = false
}

struct Enable: ActionCommand {
    static let configuration = CommandConfiguration(abstract: "Enable a job persistently and load it.")
    static let action = Launchctl.Action.enable
    @OptionGroup var common: Common
    @Argument var name: String
    @Flag(name: [.customShort("n"), .long], help: "Print the launchctl commands instead of running them.") var dryRun = false
}

struct Disable: ActionCommand {
    static let configuration = CommandConfiguration(abstract: "Unload a job and disable it persistently (survives reboots).")
    static let action = Launchctl.Action.disable
    @OptionGroup var common: Common
    @Argument var name: String
    @Flag(name: [.customShort("n"), .long], help: "Print the launchctl commands instead of running them.") var dryRun = false
}

// MARK: - logs

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the end of a job's log files; -f to follow.")

    @OptionGroup var common: Common
    @Argument var name: String
    @Option(name: .shortAndLong, help: "Lines to show.") var lines = 40
    @Flag(name: .shortAndLong, help: "Keep printing new lines.") var follow = false

    func run() throws {
        common.setup()
        try guarded {
            let job = try common.resolve(name)
            let paths = LogReader.logPaths(for: job)
            if paths.isEmpty {
                printErr("\(job.label) has no StandardOutPath or StandardErrorPath. Try:")
                printErr("  log show --last 1h --predicate 'eventMessage CONTAINS \"\(job.label)\"'")
                throw ExitCode(Exit.general)
            }
            if follow {
                let tail = Process()
                tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
                tail.arguments = ["-n", "\(lines)", "-F"] + paths
                try tail.run()
                tail.waitUntilExit()
                return
            }
            for p in paths {
                if paths.count > 1 { print(Style.dim("==> \(LDCore.Doctor.abbreviate(p)) <==")) }
                guard let out = LogReader.tail(p, lines: lines) else { printErr("can’t read \(p)"); continue }
                out.forEach { print($0) }
            }
        }
    }
}

// MARK: - new / edit

struct TriggerOptions: ParsableArguments {
    @Option(help: "Run every interval: 30s, 15m, 6h, 1d.") var every: String?
    @Option(help: "Run on a cron schedule, e.g. \"30 9 * * 1\".") var cron: String?
    @Flag(help: "Keep it running; restart whenever it exits.") var keepAlive = false
    @Flag(help: "Restart only when it exits with an error.") var restartOnFailure = false
    @Option(help: "Run when this path changes (repeatable).") var watch: [String] = []
    @Flag(help: "Also run at login (agents) or boot (daemons).") var atLoad = false

    var specified: Bool { every != nil || cron != nil || keepAlive || restartOnFailure || !watch.isEmpty || atLoad }

    func trigger() throws -> Trigger {
        if let e = every {
            guard let s = Trigger.parseDuration(e), s > 0 else { throw ValidationError("Can’t read interval “\(e)”. Use 30s, 15m, 6h or 1d.") }
            return .every(seconds: s)
        }
        if let c = cron { return .calendar(try Trigger.parseCron(c)) }
        if keepAlive || restartOnFailure { return .keepAlive(onlyOnFailure: restartOnFailure) }
        if !watch.isEmpty { return .watch(watch.map(JobBuilder.expandTilde)) }
        return atLoad ? .atLoad : .onDemand
    }
}

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create and load a new job.",
        discussion: "Example: ldm new backup --every 6h --log ~/Library/Logs/backup.log -- /usr/local/bin/backup.sh --quiet"
    )

    @OptionGroup var common: Common
    @Argument(help: "Name or full label. A bare name becomes local.<user>.<name>.") var name: String
    @OptionGroup var triggerOptions: TriggerOptions
    @Option(help: "Write stdout and stderr to this file.") var log: String?
    @Option(help: "Working directory.") var workdir: String?
    @Option(help: "user (default), allUsers or system.") var scope: String = "user"
    @Flag(help: "Create the plist but don't load it.") var noLoad = false
    @Flag(name: [.customShort("n"), .long], help: "Print the plist instead of writing it.") var dryRun = false
    @Argument(parsing: .postTerminator, help: "Program and arguments, after --.") var command: [String] = []

    func run() throws {
        common.setup()
        try guarded {
            guard !command.isEmpty else { throw LDError.invalid("Give the program after --, e.g. ldm new \(name) --every 1h -- /path/to/script") }
            guard let sc = JobScope(rawValue: scope), JobScope.editable.contains(sc) else { throw LDError.invalid("Scope must be user, allUsers or system.") }
            let label = name.contains(".") ? name : "local.\(NSUserName()).\(name)"
            guard JobBuilder.isValidLabel(label) else { throw LDError.invalid("“\(label)” isn’t a valid label: use letters, digits, - _ . @") }
            let url = sc.directory.appendingPathComponent("\(label).plist")
            if FileManager.default.fileExists(atPath: url.path) { throw LDError.invalid("\(LDCore.Doctor.abbreviate(url.path)) already exists. Use ldm edit.") }
            var argv = command.map(JobBuilder.expandTilde)
            if !argv[0].hasPrefix("/"), let found = which(argv[0]) { argv[0] = found }
            let dict = JobBuilder.make(label: label, program: argv, trigger: try triggerOptions.trigger(), runAtLoad: triggerOptions.atLoad,
                                       standardOutPath: log.map(JobBuilder.expandTilde), workingDirectory: workdir.map(JobBuilder.expandTilde))
            if dryRun {
                print(String(decoding: try PlistEditor.xml(dict), as: UTF8.self))
                return
            }
            try PlistEditor.write(dict, to: url, scope: sc)
            let def = JobDefinition.load(url: url, scope: sc)
            var job = Job(definition: def, listing: nil, detail: nil, override: nil)
            if !noLoad {
                try Launchctl.perform(.enable, on: job)
                job = Inventory.reload(job)
            }
            if common.json { return emitJSON(JobJSON(job)) }
            print(Style.green("created ") + LDCore.Doctor.abbreviate(url.path) + Style.dim("  (\(def.schedule.summaryInSentence)\(noLoad ? "" : " · loaded"))"))
        }
    }

    func which(_ name: String) -> String? {
        let r = Shell.run("/usr/bin/which", [name])
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.succeeded && !p.isEmpty ? p : nil
    }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Change a job's program, schedule or log file. Shows a diff; every other key is kept.",
        discussion: "Example: ldm edit nightly-backup --program /opt/homebrew/bin/python3"
    )

    @OptionGroup var common: Common
    @Argument var name: String
    @Option(help: "Replace the program (first argument).") var program: String?
    @OptionGroup var triggerOptions: TriggerOptions
    @Option(help: "Write stdout and stderr to this file.") var log: String?
    @Flag(name: [.customShort("n"), .long], help: "Show the diff without saving.") var dryRun = false
    @Flag(help: "Don't reload the job after saving.") var noReload = false

    func run() throws {
        common.setup()
        try guarded {
            let job = Inventory.reload(try common.resolve(name))
            if job.scope.isReadOnly { throw LDError.readOnly(job.label) }
            var updates: [String: Any?] = [:]
            if let p = program {
                let path = JobBuilder.expandTilde(p)
                if job.definition.programKey != nil {
                    updates["Program"] = path
                } else {
                    var args = job.definition.programArguments
                    if args.isEmpty { args = [path] } else { args[0] = path }
                    updates["ProgramArguments"] = args
                }
            }
            if triggerOptions.specified {
                for (k, v) in try triggerOptions.trigger().updates(runAtLoad: triggerOptions.atLoad) { updates[k] = v }
            }
            if let l = log {
                updates["StandardOutPath"] = JobBuilder.expandTilde(l)
                updates["StandardErrorPath"] = JobBuilder.expandTilde(l)
            }
            guard !updates.isEmpty else { throw LDError.invalid("Nothing to change. Pass --program, a trigger option, or --log.") }
            let old = job.definition.raw
            let new = PlistEditor.apply(updates, to: old)
            let changes = PlistEditor.diff(old, new)
            if changes.isEmpty { print("No changes."); return }
            for c in changes {
                print(Style.dim(c.key))
                if let o = c.old { print(Style.red("  − \(o)")) }
                if let n = c.new { print(Style.green("  + \(n)")) }
            }
            if dryRun { return }
            let backup = try PlistEditor.write(new, to: job.definition.url, scope: job.scope)
            if !noReload && job.isLoaded {
                try Launchctl.perform(.unload, on: job)
                try Launchctl.perform(.load, on: Inventory.reload(job))
            }
            print(Style.green("✓ saved") + Style.dim(backup.map { "  backup: \(LDCore.Doctor.abbreviate($0.path))" } ?? ""))
        }
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unload a job and move its plist to the Trash (a backup is kept).")

    @OptionGroup var common: Common
    @Argument var name: String
    @Option(help: "Repeat the job's full label to confirm (required without a terminal).") var confirm: String?

    func run() throws {
        common.setup()
        try guarded {
            let job = try common.resolve(name)
            if confirm != job.label {
                guard isatty(STDIN_FILENO) != 0 else { throw LDError.invalid("Pass --confirm \(job.label) to remove it.") }
                print("Move \(LDCore.Doctor.abbreviate(job.definition.url.path)) to the Trash? Type the label to confirm: ", terminator: "")
                guard readLine() == job.label else { print("Cancelled."); return }
            }
            try PlistEditor.trash(job)
            print(Style.green("✓ ") + "removed \(job.label)" + Style.dim("  (in the Trash; backup kept)"))
        }
    }
}

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Explain a launchd exit code or signal (negative = signal).")
    @Argument(help: "Exit code, e.g. 78 or -15.") var code: Int
    func run() throws { print(ExitCode.explain(code)) }
}

struct HelperStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper",
        abstract: "Show whether LD Manager's privileged helper is reachable. Install and approve it from the app."
    )

    @Flag(help: "Restart the helper so it runs the copy in the current app (after an update).") var restart = false

    func run() throws {
        if HelperPolicy.currentTeamIdentifier() == nil {
            print("ldm isn’t signed with a team, so the helper won’t accept it. Use the copy bundled in LD Manager.app.")
            throw ExitCode(Exit.authorization)
        }
        if restart, HelperClient.shared.isAvailable {
            // The helper restarts itself; the connection drops as it exits, which is expected.
            _ = Privileged.launchctl([["/bin/launchctl", "kickstart", "-k", "system/\(HelperPolicy.machService)"]])
            HelperClient.shared.resetProbe()
            Thread.sleep(forTimeInterval: 1)
        }
        if HelperClient.shared.isAvailable {
            print(Style.green("✓ ") + "helper reachable — system changes and Login Items checks won’t prompt")
        } else {
            print("helper not reachable — install and approve it in LD Manager (sidebar or Settings)")
            throw ExitCode(Exit.authorization)
        }
    }
}
