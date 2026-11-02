import Foundation

public enum Severity: Int, Comparable, Codable, Sendable {
    case info, warning, error
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

/// One-click remedies the app and CLI can offer for a finding.
public enum Fix: Hashable, Codable, Sendable {
    case disable
    case load
    case restart
    case trash
    case chooseProgram
    case revealPlist
    case editPlist
    case openTerminal(directory: String)
    case removeQuarantine(path: String)
    case createDirectory(path: String)
    case fixPermissions
    case openLoginItems

    public var title: String {
        switch self {
        case .disable: "Disable job"
        case .load: "Load job"
        case .restart: "Restart job"
        case .trash: "Move to Trash…"
        case .chooseProgram: "Choose program…"
        case .revealPlist: "Reveal plist"
        case .editPlist: "Edit job…"
        case .openTerminal: "Open Terminal there"
        case .removeQuarantine: "Remove quarantine"
        case .createDirectory: "Create folder"
        case .fixPermissions: "Fix owner & permissions"
        case .openLoginItems: "Open Login Items settings"
        }
    }

    public var detail: String {
        switch self {
        case .disable: "Stop launchd from starting it until you’re ready. Reversible."
        case .load: "Load it into launchd now so its triggers take effect."
        case .restart: "launchd opens a fresh log file when it starts the job again."
        case .trash: "Remove the leftover file. A backup is kept in Recent Changes."
        case .chooseProgram: "Point the job at a program that exists. Shows a diff before saving."
        case .revealPlist: "Show the plist in Finder."
        case .editPlist: "Open the job editor."
        case .openTerminal(let d): "Investigate in \((d as NSString).abbreviatingWithTildeInPath)."
        case .removeQuarantine(let p): "Clear macOS’s download flag from \((p as NSString).lastPathComponent) so launchd accepts it."
        case .createDirectory(let p): "Create \((p as NSString).abbreviatingWithTildeInPath) so launchd can write the log."
        case .fixPermissions: "Set the owner and mode launchd requires."
        case .openLoginItems: "Turn it back on under App Background Activity. Only you can change this switch."
        }
    }
}

public struct CheckResult: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// nil = not applicable / skipped.
    public let passed: Bool?
    public let note: String?
}

public struct Finding: Identifiable, Sendable {
    public let id: String
    public let severity: Severity
    public let headline: String
    public let detail: String
    public let fixes: [Fix]
}

public struct Diagnosis: Identifiable, @unchecked Sendable {
    public let job: Job
    public let checks: [CheckResult]
    public let findings: [Finding]

    public init(job: Job, checks: [CheckResult], findings: [Finding]) {
        self.job = job
        self.checks = checks
        self.findings = findings
    }

    public var id: String { job.id }
    public var worst: Severity? { findings.map(\.severity).max() }
    public var isProblem: Bool { (worst ?? .info) >= .warning }
    public var primary: Finding? { findings.max { $0.severity < $1.severity } }
}

/// Answers "why isn't my job running?". Pure checks over the job's plist, the
/// file system and launchd state; nothing here changes anything. Every rule was
/// checked against what launchd actually does on macOS 27 with throwaway jobs.
public enum Doctor {
    public static func problems(in jobs: [Job]) -> [Diagnosis] {
        jobs.filter { !$0.scope.isApple }
            .map(diagnose)
            .filter(\.isProblem)
            .sorted { ($0.worst ?? .info, $0.job.label) > ($1.worst ?? .info, $1.job.label) }
    }

    public static func diagnose(_ job: Job) -> Diagnosis {
        var checks: [CheckResult] = []
        var findings: [Finding] = []
        let def = job.definition
        let plist = def.url.path

        func check(_ id: String, _ name: String, _ passed: Bool?, _ note: String? = nil) {
            checks.append(CheckResult(id: id, name: name, passed: passed, note: note))
        }
        func find(_ id: String, _ sev: Severity, _ headline: String, _ detail: String, _ fixes: [Fix] = []) {
            findings.append(Finding(id: id, severity: sev, headline: headline, detail: detail, fixes: fixes))
        }
        func done() -> Diagnosis { Diagnosis(job: job, checks: checks, findings: findings) }

        // 1. Can the file be read and parsed the way launchd does?
        if def.unreadable {
            check("plist", "Plist can be checked", nil, "Root-only file: launchd reads it, LD Manager can’t")
            find("unreadable", .info, "LD Manager can’t read this plist",
                 "Only root can read it. launchd reads job plists as root, so the job works normally; its settings just can’t be checked here.")
            runtimeChecks(job, checks: &checks, findings: &findings)
            return done()
        }
        if def.lenientOnly {
            check("plist", "Plist can be checked", nil, "launchd accepts it; macOS’s plist parser doesn’t")
            find("lenient", .warning, "LD Manager can’t check this plist",
                 "launchd reads it, but macOS’s own plist parser rejects part of it (for example a malformed number or invalid text), so its settings can’t be checked here. It probably loads; fixing the file makes it checkable.",
                 [.editPlist, .revealPlist])
            runtimeChecks(job, checks: &checks, findings: &findings)
            return done()
        }
        if def.isEmptyPlaceholder {
            check("plist", "Plist defines a job", nil, "Empty placeholder")
            let q = hasQuarantine(plist) ? " It also carries macOS’s download flag." : ""
            find("placeholder", .info, "Empty placeholder, launchd ignores it",
                 "This plist defines no job (no Label and no program), so launchd skips it and nothing runs. Apps sometimes leave these behind; Google’s updater does.\(q) It’s safe to leave it or move it to the Trash.",
                 [.trash, .revealPlist])
            return done()
        }
        if let err = def.parseError {
            check("plist", "Plist is valid", false, err)
            if job.isLoaded {
                find("plist", .warning, "The plist on disk is broken",
                     "launchd is still running the copy it loaded earlier, but it will refuse this file at the next login or reload: \(err)",
                     [.editPlist, .revealPlist])
            } else {
                find("plist", .error, "launchd can’t read this plist",
                     "\(err) launchd skips it at login without telling you; only the system log records it.",
                     [.editPlist, .revealPlist])
            }
            return done()
        }
        check("plist", "Plist is valid", true)

        // 2. A quarantined plist is refused outright (measured: bootstrap error 5).
        let plistQuarantined = hasQuarantine(plist)
        if plistQuarantined {
            check("plistquarantine", "Plist isn’t quarantined", false, "Carries macOS’s download flag")
            if job.isLoaded {
                find("plistquarantine", .warning, "Its plist is quarantined",
                     "It’s loaded now, but the plist carries macOS’s download flag and launchd refuses quarantined plists, so it won’t load again at the next login or reload.",
                     [.removeQuarantine(path: plist)])
            } else {
                find("plistquarantine", .error, "launchd refuses this file: it’s quarantined",
                     "The plist carries macOS’s download flag (com.apple.quarantine), usually because it came from a download. launchd won’t load quarantined plists, at login or by hand, so this job never runs.",
                     [.removeQuarantine(path: plist), .revealPlist])
            }
        } else {
            check("plistquarantine", "Plist isn’t quarantined", true)
        }

        // 3. Label
        if def.declaredLabel == nil {
            let value = def.raw["Label"]
            let what = value.map { $0 is String ? "is blank" : "is a \(typeName($0)), not text" } ?? "is missing"
            check("label", "Has a usable Label", false, "Label \(what)")
            find("label", .error, "Plist has no usable Label",
                 "Its Label \(what). launchd needs a Label to load a job, so it refuses this file and skips it at login without saying so.",
                 [.editPlist, .revealPlist])
        } else if def.label != def.fileStem {
            check("label", "Has a usable Label", true, "Label \(def.label) differs from the file name — that’s fine")
        } else {
            check("label", "Has a usable Label", true)
        }

        // 4. Program
        checkProgram(def, check: check, find: find)

        // 5. ~ and relative paths (launchd never expands ~)
        checkPaths(def, check: check, find: find)

        // 6. Ownership and permissions of the plist (stat follows symlinks)
        checkPermissions(job, check: check, find: find)

        // 7. Log files
        checkLogs(job, check: check, find: find)

        // 8. Triggers and watched paths
        checkTriggers(job, check: check, find: find)

        // 9. launchd state
        let refusedEarlier = programRefused(def)
            || findings.contains { $0.severity == .error && ["plistquarantine", "label", "perms"].contains($0.id) }
        runtimeChecks(job, checks: &checks, findings: &findings, refusedEarlier: refusedEarlier)
        return done()
    }

    // MARK: Program

    /// launchd refuses to load the plist at all: no program, or a Program key that
    /// isn't a full path. Measured: bootstrap error 5, "Invalid or missing Program".
    static func programRefused(_ def: JobDefinition) -> Bool {
        guard def.bundleProgram == nil else { return false }
        if let p = def.programKey { return !p.hasPrefix("/") }
        return ((def.raw["ProgramArguments"] as? [Any]) ?? []).isEmpty
    }

    static func checkProgram(_ def: JobDefinition, check: (String, String, Bool?, String?) -> Void,
                             find: (String, Severity, String, String, [Fix]) -> Void) {
        let name = "Program exists and is executable"
        if def.bundleProgram != nil { check("program", name, nil, "Bundle-relative program"); return }
        if let args = def.raw["ProgramArguments"] as? [Any], let i = args.firstIndex(where: { !($0 is String) }) {
            find("programargs", .warning, "One of its arguments isn’t text",
                 "ProgramArguments item \(i + 1) is \(describeValue(args[i])), but launchd expects text for every item, so the command may not run as written.",
                 [.editPlist])
        }
        if let key = def.programKey, !key.hasPrefix("/") {
            check("program", name, false, key.isEmpty ? "Program is empty" : "\(key) — not a full path")
            find("program", .error, "Its Program isn’t a full path",
                 (key.isEmpty ? "Program is empty. " : "") + "launchd only accepts a Program that starts with /, so it refuses to load this job. Use the full path.",
                 [.chooseProgram])
            return
        }
        guard let program = def.program, !program.isEmpty else {
            if programRefused(def) {
                check("program", name, false, "No Program or ProgramArguments")
                find("program", .error, "It has no program to run",
                     "Neither Program nor ProgramArguments is set, so launchd refuses to load it.", [.editPlist])
            } else {
                check("program", name, false, "The first ProgramArguments item isn’t a path")
                find("program", .error, "It has no program to run",
                     "The first item of ProgramArguments, which names the program, is empty or isn’t text, so launchd has nothing to run.", [.editPlist])
            }
            return
        }
        if program.hasPrefix("~") {
            check("program", name, false, "\(program) — launchd doesn’t expand ~")
            find("program", .error, "Its program path uses ~",
                 "launchd isn’t a shell and doesn’t expand ~, so every start fails with exit 78. Use the full path.", [.chooseProgram])
            return
        }
        let resolved: String?
        if program.hasPrefix("/") {
            resolved = program
        } else if program.contains("/") {
            let base = def.workingDirectory.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/"
            resolved = URL(fileURLWithPath: base).appendingPathComponent(program).standardizedFileURL.path
        } else {
            resolved = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map { "\($0)/\(program)" }.first {
                FileManager.default.fileExists(atPath: $0)
            }
            if resolved == nil {
                check("program", name, false, "\(program) — not in launchd’s search path")
                find("program", .error, "launchd can’t find its program",
                     "launchd looks for “\(program)” only in /usr/bin, /bin, /usr/sbin and /sbin — not your shell’s PATH — so every start fails with exit 78. Use the full path.",
                     [.chooseProgram])
                return
            }
        }
        guard let path = resolved else { return }
        switch pathState(path) {
        case .unknown:
            check("program", name, nil, "\(abbreviate(path)) — can’t check (no permission)")
            return
        case .missing:
            check("program", name, false, "\(abbreviate(path)) — not found")
            find("program", .error, missingProgramHeadline(program),
                 "The program the job points at, \(abbreviate(path)), doesn’t exist, so every start fails immediately (exit 78).",
                 [.chooseProgram, .disable, .revealPlist])
            return
        case .exists: break
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            check("program", name, false, "\(abbreviate(path)) — a folder")
            find("program", .error, "Its program is a folder",
                 "\(abbreviate(path)) is a folder, not a program, so every start fails with exit 78.", [.chooseProgram])
            return
        }
        let runsAsRoot = def.scope.isDaemon && def.userName == nil
        guard isExecutable(path, runsAsRoot: runsAsRoot) else {
            if def.userName != nil {
                check("program", name, nil, "\(abbreviate(path)) — can’t check for user \(def.userName!)")
                return
            }
            check("program", name, false, "\(abbreviate(path)) — not executable")
            find("program", .error, "Its program isn’t executable",
                 "\(abbreviate(path)) exists but doesn’t have execute permission, so every start fails with exit 78.",
                 [.chooseProgram, .revealPlist])
            return
        }
        // A script: its #! interpreter must exist and be executable too.
        var execd = path
        if let line = shebang(path) {
            let interpreter = line.interpreter
            if line.crlf {
                check("program", name, false, "\(abbreviate(path)) — Windows line endings")
                find("program", .error, "Its script has Windows line endings",
                     "The #! line of \(abbreviate(path)) ends in a carriage return, so macOS looks for an interpreter that doesn’t exist and every start fails with exit 78. Convert the script to LF line endings.",
                     [.revealPlist])
                return
            }
            switch pathState(interpreter) {
            case .missing:
                check("program", name, false, "\(abbreviate(path)) — interpreter \(interpreter) missing")
                find("program", .error, missingProgramHeadline(interpreter),
                     "\(abbreviate(path)) starts with #!\(interpreter), which doesn’t exist, so every start fails with exit 78.",
                     [.revealPlist, .disable])
                return
            case .unknown:
                check("program", name, nil, "\(abbreviate(path)) — can’t check its interpreter \(interpreter)")
                return
            case .exists: break
            }
            var interpIsDir: ObjCBool = false
            FileManager.default.fileExists(atPath: interpreter, isDirectory: &interpIsDir)
            let anyX = ((try? FileManager.default.attributesOfItem(atPath: interpreter))?[.posixPermissions] as? NSNumber)
                .map { $0.intValue & 0o111 != 0 } ?? true
            if interpIsDir.boolValue || !anyX || (!runsAsRoot && def.userName == nil && access(interpreter, X_OK) != 0) {
                check("program", name, false, "\(abbreviate(path)) — interpreter \(interpreter) not executable")
                find("program", .error, "Its script’s interpreter isn’t executable",
                     "\(abbreviate(path)) starts with #!\(interpreter), which is \(interpIsDir.boolValue ? "a folder" : "not executable"), so every start fails with exit 78.",
                     [.revealPlist, .disable])
                return
            }
            if (interpreter as NSString).lastPathComponent == "env" {
                checkEnvLookup(line.arguments, script: path, def: def, find: find)
            } else {
                if shebang(interpreter) != nil {
                    find("interpreter", .warning, "Its script’s interpreter is itself a script",
                         "\(abbreviate(path)) starts with #!\(interpreter), which is a script too. macOS doesn’t run an interpreter that is a script, so the job’s script runs under /bin/sh instead.",
                         [.revealPlist])
                }
                execd = interpreter
            }
        }
        check("program", name, true, abbreviate(path))

        // Quarantine on the program: only matters for code macOS hasn't approved.
        // Measured: a binary whose flag lacks 0x40 (user approved) sits "running" with
        // a PID but never starts; 0x04 (hard) can't be spawned at all; scripts run.
        if execd == path && shebangInterpreter(path) != nil {
            check("quarantine", "Program isn’t blocked by quarantine", true, nil)
            return
        }
        switch quarantineFlags(execd) {
        case nil:
            check("quarantine", "Program isn’t blocked by quarantine", true, nil)
        case let f? where f & 0x04 != 0:
            check("quarantine", "Program isn’t blocked by quarantine", false, "Hard quarantine")
            find("quarantine", .error, "macOS blocks its program",
                 "\(abbreviate(execd)) carries a hard quarantine flag, so macOS refuses to start it (exit 78).",
                 [.removeQuarantine(path: execd)])
        case let f? where f & 0x40 == 0:
            check("quarantine", "Program isn’t blocked by quarantine", false, "Quarantined, never approved")
            find("quarantine", .error, "Its program is quarantined and may never start",
                 "\(abbreviate(execd)) came from a download and hasn’t been approved. macOS holds such a program before it starts: launchd shows it as running with a PID, but it never actually runs, and a “not opened” dialog may appear. Remove the flag if you trust it.",
                 [.removeQuarantine(path: execd)])
        default:
            check("quarantine", "Program isn’t blocked by quarantine", true, "Downloaded, approved")
        }
    }

    // MARK: Paths

    static func checkPaths(_ def: JobDefinition, check: (String, String, Bool?, String?) -> Void,
                           find: (String, Severity, String, String, [Fix]) -> Void) {
        // The shell expands ~ in a -c script, but not in the arguments after it.
        let script = shellScriptIndex(def.commandLine)
        let tildeArgs = def.commandLine.enumerated().filter { i, arg in
            i > 0 && i != script && (arg == "~" || arg.hasPrefix("~/") || (arg.hasPrefix("~") && arg.contains("/")))
        }.map(\.element)
        if !tildeArgs.isEmpty {
            check("tilde", "Arguments don’t rely on ~", false, tildeArgs.joined(separator: " "))
            find("tilde", .warning, "Its arguments contain ~",
                 "launchd passes \(tildeArgs.joined(separator: ", ")) literally: the program receives “~” instead of your home folder. Use full paths, or run it through /bin/sh -c.",
                 [.editPlist])
        }

        var workingDirOK = true
        if let wd = def.workingDirectory {
            if wd.hasPrefix("~") || !wd.hasPrefix("/") {
                workingDirOK = false
                let resolved = "/" + wd
                if pathState(resolved) != .exists {
                    check("workdir", "Working directory exists", false, wd)
                    find("workdir", .error, wd.hasPrefix("~") ? "Its working directory uses ~" : "Its working directory isn’t a full path",
                         "launchd doesn’t expand ~ and treats \(wd) as relative to /, which doesn’t exist, so every start fails with exit 78. Use the full path.",
                         [.editPlist])
                }
            } else if pathState(wd) == .missing {
                workingDirOK = false
                check("workdir", "Working directory exists", false, abbreviate(wd))
                find("workdir", .error, "Its working directory doesn’t exist",
                     "launchd can’t change to \(abbreviate(wd)), so every start fails with exit 78 before the program runs.",
                     [.editPlist, .disable])
            } else {
                check("workdir", "Working directory exists", true, abbreviate(wd))
            }
        }

        // launchd resolves a relative log path (~ included) against the working
        // directory, or / without one, and creates missing folders there.
        let relativeLogs = Set([def.standardOutPath, def.standardErrorPath].compactMap { $0 }).filter { !$0.hasPrefix("/") }
        for path in relativeLogs.sorted() {
            let base = (workingDirOK ? def.workingDirectory.flatMap { $0.hasPrefix("/") ? $0 : nil } : nil) ?? "/"
            let resolved = URL(fileURLWithPath: base).appendingPathComponent(path).path
            let tilde = path.hasPrefix("~")
            var blocked: Bool
            switch logAccess(resolved, user: RunAs(def)) {
            case .blocked: blocked = true
            case .unknown: continue
            case .ok: blocked = false
            }
            // / is the read-only system volume: nothing new can be made there.
            var dir = (resolved as NSString).deletingLastPathComponent
            while dir.count > 1 && !FileManager.default.fileExists(atPath: dir) { dir = (dir as NSString).deletingLastPathComponent }
            if dir == "/" { blocked = true }
            if blocked {
                find("tildepath", .error, tilde ? "Its log path uses ~, so the job can’t start" : "Its log path isn’t a full path, so the job can’t start",
                     (tilde ? "launchd doesn’t expand ~. " : "") + "It treats \(path) as relative to \(abbreviate(base)), can’t create or open the log there, and every start fails with exit 78. Use the full path.",
                     [.editPlist])
            } else if tilde {
                find("tildepath", .warning, "Its log goes to a folder named ~",
                     "launchd doesn’t expand ~: it writes the log to \(abbreviate(resolved)), creating a folder literally named “~” in \(abbreviate(base)). Use the full path.",
                     [.editPlist])
            }
        }
    }

    // MARK: Permissions

    static func checkPermissions(_ job: Job, check: (String, String, Bool?, String?) -> Void,
                                 find: (String, Severity, String, String, [Fix]) -> Void) {
        var st = stat()
        guard stat(job.definition.url.path, &st) == 0 else { return }
        let mode = Int(st.st_mode) & 0o7777
        let me = getuid()
        let name = "Owner and permissions are what launchd expects"
        let loadedNote = job.isLoaded ? " It’s running now, but it won’t load again at the next login or reload." : ""
        if mode & 0o002 != 0 {
            check("perms", name, false, String(format: "writable by everyone (%o)", mode))
            find("perms", .error, "launchd won’t load this plist: anyone can edit it",
                 "The plist is writable by every user, and launchd refuses such files (it reports only “Input/output error”).\(loadedNote)",
                 [.fixPermissions])
            return
        }
        if job.scope == .user {
            if st.st_uid != me && st.st_uid != 0 {
                check("perms", name, false, "owned by user \(st.st_uid)")
                find("perms", .error, "launchd won’t load this plist: it belongs to another user",
                     "launchd only loads your agents from plists owned by you or by root.\(loadedNote)", [.fixPermissions])
                return
            }
            if mode & 0o020 != 0 && st.st_gid == 12 {  // everyone
                check("perms", name, false, "writable by group everyone")
                find("perms", .warning, "Others can edit what runs as you",
                     "Anyone in the group “everyone” can change this plist, and launchd will run whatever it says as you.", [.fixPermissions])
                return
            }
        } else {
            if st.st_uid != 0 {
                check("perms", name, false, "not owned by root")
                find("perms", .error, "launchd won’t load this plist: it isn’t owned by root",
                     "Plists in /Library must belong to root.\(loadedNote)", [.fixPermissions])
                return
            }
            if mode & 0o020 != 0 {
                let group = getgrgid(st.st_gid).map { String(cString: $0.pointee.gr_name) } ?? "\(st.st_gid)"
                check("perms", name, false, "writable by group \(group)")
                find("perms", .warning, job.scope.isDaemon ? "Its group can make it run anything as root" : "Its group can change what runs for every user",
                     "Anyone in the group “\(group)” can edit this plist" + (job.scope.isDaemon ? ", and launchd runs it as root." : "."),
                     [.fixPermissions])
                return
            }
        }
        check("perms", name, true, nil)
    }

    // MARK: Logs

    static func checkLogs(_ job: Job, check: (String, String, Bool?, String?) -> Void,
                          find: (String, Severity, String, String, [Fix]) -> Void) {
        let def = job.definition
        let paths = Set([def.standardOutPath, def.standardErrorPath].compactMap { $0 })
            .filter { $0 != "/dev/null" && $0.hasPrefix("/") }
        guard !paths.isEmpty else { return }
        let name = "Log can be written"
        var unknown: String?
        for path in paths.sorted() {
            let folder = (path as NSString).deletingLastPathComponent
            if job.pid != nil && pathState(folder) == .missing {
                check("logdir", name, false, "\(abbreviate(folder)) deleted while running")
                find("logdir", .warning, "Its log was deleted while it’s running",
                     "\(abbreviate(path)) no longer exists, but the running process still writes to the old, deleted file, so its output is lost until it restarts. launchd creates the folder and file again at the next start.",
                     [.restart])
                return
            }
            guard job.pid == nil else { continue }
            switch logAccess(path, user: RunAs(def)) {
            case .ok: break
            case .unknown:
                unknown = unknown ?? "\(abbreviate(path)) — can’t check for user \(def.userName ?? "")"
            case .blocked(let reason):
                check("logdir", name, false, reason)
                find("logdir", job.isLoaded ? .error : .warning, "launchd can’t open its log, so it won’t start",
                     "launchd opens \(abbreviate(path)) before starting the program, but \(reason). Every start fails with exit 78 and the program never runs.",
                     [.editPlist])
                return
            }
        }
        check("logdir", name, unknown == nil ? true : nil, unknown)
    }

    /// Who the job's program runs as, for permission checks.
    enum RunAs: Equatable {
        case me, root
        case other(String)

        init(_ def: JobDefinition) {
            guard def.scope.isDaemon else { self = .me; return }  // agents run as the logged-in user
            switch def.userName {
            case nil, "root": self = .root
            case let u? where u == NSUserName(): self = .me
            case let u?: self = .other(u)
            }
        }
    }

    enum LogAccess: Equatable { case ok, unknown, blocked(String) }

    /// Whether launchd can open a log path as the job's user (it creates missing
    /// folders itself). Agents run as us, so access() is authoritative for them; root
    /// is only stopped by a file in the way; another user is judged by mode bits.
    static func logAccess(_ path: String, user: RunAs) -> LogAccess {
        var isDir: ObjCBool = false
        let who = { () -> String in if case .other(let u) = user { return u } else { return "you" } }()
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue { return .blocked("\(abbreviate(path)) is a folder") }
            switch canAccess(path, W_OK, as: user) {
            case false?: return .blocked("\(abbreviate(path)) is read-only for \(who)")
            case nil: return .unknown
            case true?: return .ok
            }
        }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 && !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            dir = (dir as NSString).deletingLastPathComponent
        }
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), !isDir.boolValue {
            return .blocked("\(abbreviate(dir)) is a file, not a folder")
        }
        switch canAccess(dir, W_OK | X_OK, as: user) {
        case false?: return .blocked("\(abbreviate(dir)) isn’t writable by \(who)")
        case nil: return .unknown
        case true?: return .ok
        }
    }

    /// access() for another user, from the owner, group and mode bits (ACLs aside).
    /// nil when it can't be judged: an unknown user, or a path we can't stat.
    static func canAccess(_ path: String, _ mode: Int32, as user: RunAs) -> Bool? {
        switch user {
        case .me: return access(path, mode) == 0
        case .root: return true
        case .other(let name):
            guard let pw = getpwnam(name) else { return nil }
            let uid = pw.pointee.pw_uid, gid = pw.pointee.pw_gid
            if uid == 0 { return true }
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            var count: Int32 = 64
            var groups = [Int32](repeating: 0, count: Int(count))
            if getgrouplist(name, Int32(bitPattern: gid), &groups, &count) == -1 { return nil }
            let inGroup = groups.prefix(Int(count)).contains(Int32(bitPattern: st.st_gid))
            let shift: Int = st.st_uid == uid ? 6 : inGroup ? 3 : 0
            let bits = (Int(st.st_mode) >> shift) & 0o7
            let needed = (mode & W_OK != 0 ? 0o2 : 0) | (mode & X_OK != 0 ? 0o1 : 0) | (mode & R_OK != 0 ? 0o4 : 0)
            return bits & needed == needed
        }
    }

    // MARK: Triggers

    static func checkTriggers(_ job: Job, check: (String, String, Bool?, String?) -> Void,
                              find: (String, Severity, String, String, [Fix]) -> Void) {
        let def = job.definition
        let schedule = def.schedule
        let ignoredWatch = (def.watchPaths + def.queueDirectories).filter { !$0.hasPrefix("/") && !$0.hasPrefix("~") }
        if !ignoredWatch.isEmpty {
            let only = !schedule.hasTrigger
            let names = ignoredWatch.map { $0.isEmpty ? "An empty path" : $0 }.joined(separator: ", ")
            find("watch", only ? .error : .warning, "A watched path is ignored",
                 "\(names) doesn’t start with /, so launchd ignores it and changes there never start the job." + (only ? " Nothing else starts it either, so it never runs by itself." : ""),
                 [.editPlist])
        }

        // Settings launchd ignores because of their type or value: the author meant it to start.
        var ignored: [String] = []
        for key in ["RunAtLoad", "StartOnMount", "OnDemand", "Disabled"] {
            if let v = def.raw[key], JobDefinition.strictBool(v) == nil {
                ignored.append("\(key) is \(describeValue(v)), not true or false, so launchd ignores it.")
            }
        }
        if let v = def.raw["StartInterval"], def.startInterval == nil {
            ignored.append("StartInterval is \(describeValue(v)), not a whole number of seconds above 0, so launchd sets no timer.")
        }
        if let v = def.raw["KeepAlive"], JobDefinition.strictBool(v) == nil {
            if let d = v as? [String: Any] {
                let before = ignored.count
                for key in ["SuccessfulExit", "Crashed", "AfterInitialDemand"] {
                    if let x = d[key], JobDefinition.strictBool(x) == nil {
                        ignored.append("KeepAlive’s \(key) is \(describeValue(x)), not true or false, so launchd ignores it.")
                    }
                }
                if d.isEmpty {
                    ignored.append("KeepAlive is an empty dictionary, which does nothing.")
                } else if def.keepAlive == .never && ignored.count == before {
                    let keys = d.keys.sorted().joined(separator: " and ")
                    ignored.append("KeepAlive only has \(keys), which on \(d.count == 1 ? "its" : "their") own never start\(d.count == 1 ? "s" : "") it" + (d["NetworkState"] != nil ? " (macOS no longer uses NetworkState)." : "."))
                }
            } else {
                ignored.append("KeepAlive is \(describeValue(v)), not true, false or a dictionary, so launchd ignores it.")
            }
        }
        if !ignored.isEmpty {
            find("trigger", .warning, "Its start setting is ignored",
                 ignored.joined(separator: " ") + (schedule.hasTrigger ? "" : " Nothing else starts it, so it runs only when something starts it, such as Run Now."),
                 [.editPlist])
        }

        if schedule.hasTrigger {
            check("trigger", "Has a way to start", true, schedule.summary)
        } else if (job.runs ?? 0) > 0 {
            check("trigger", "Has a way to start", nil, "Starts when asked")
        } else if case .conditional(let keys)? = def.keepAlive {
            check("trigger", "Has a way to start", nil, "Only starts when asked")
            guard ignored.isEmpty else { return }
            if keys.contains("AfterInitialDemand") {
                find("trigger", .info, "It only starts when asked, then stays running",
                     "KeepAlive has AfterInitialDemand, so launchd keeps it running only after something has started it once, such as Run Now or another program.", [])
            } else {
                find("trigger", .info, "It only restarts after a crash",
                     "KeepAlive’s Crashed setting restarts it after a crash, but nothing starts it the first time.", [])
            }
        } else {
            check("trigger", "Has a way to start", nil, "Only starts when asked")
            guard ignored.isEmpty else { return }
            find("trigger", .info, "It only starts when asked",
                 "Nothing in its plist makes launchd start it: no RunAtLoad, schedule, KeepAlive, watched paths, sockets or events. It runs only when something starts it, such as Run Now or another program.", [])
        }
    }

    // MARK: Runtime

    static func runtimeChecks(_ job: Job, checks: inout [CheckResult], findings: inout [Finding], refusedEarlier: Bool = false) {
        let def = job.definition
        func check(_ id: String, _ name: String, _ passed: Bool?, _ note: String? = nil) {
            checks.append(CheckResult(id: id, name: name, passed: passed, note: note))
        }
        func find(_ id: String, _ sev: Severity, _ headline: String, _ detail: String, _ fixes: [Fix] = []) {
            findings.append(Finding(id: id, severity: sev, headline: headline, detail: detail, fixes: fixes))
        }
        guard !job.isDisabled else {
            check("enabled", "Enabled in launchd", false, "Disabled — skipped runtime checks")
            return
        }
        check("enabled", "Enabled in launchd", true)

        if let bg = job.background {
            if bg.isOn {
                check("background", "Allowed in App Background Activity", true)
            } else {
                check("background", "Allowed in App Background Activity", false, bg.summary)
                find("background", .error,
                     bg.isAllowed ? "It’s switched off in Login Items" : "A policy blocks it from running in the background",
                     bg.isAllowed
                        ? "launchd has it enabled, but System Settings → General → Login Items → App Background Activity has it switched off, so macOS won’t let it run."
                        : "A management profile or system policy disallows it in Background Items, so macOS won’t let it run.",
                     bg.isAllowed ? [.openLoginItems] : [])
            }
        }

        if let loadedFrom = job.detail?.path, loadedFrom != def.url.path,
           URL(fileURLWithPath: loadedFrom).resolvingSymlinksInPath().path != def.url.resolvingSymlinksInPath().path {
            find("otherfile", .warning, "launchd is running a different file with this Label",
                 "launchd loaded “\(def.label)” from \(abbreviate(loadedFrom)), not from this file, so this plist’s settings aren’t the ones in effect.",
                 [.revealPlist])
        }

        if !job.isLoaded && !refusedEarlier && def.schedule.hasTrigger && def.lookupLabel != nil && !job.isBlockedInBackground {
            let sessions = sessionTypes(def)
            let valid: Set<String> = ["Aqua", "Background", "LoginWindow", "StandardIO", "System"]
            let invalid = sessions.compactMap { v -> String? in
                if let s = v as? String { return valid.contains(s) ? nil : s }
                return describeValue(v)
            }
            if job.scope.isDaemon || sessions.contains(where: { $0 as? String == "Aqua" }) {
                find("loaded", .warning, "It isn’t loaded",
                     "launchd doesn’t have this job loaded, so its schedule and other triggers do nothing. It was probably added or changed since you logged in, or something unloaded it. launchd loads it again at your next " + (job.scope.isDaemon ? "boot." : "login."),
                     [.load])
            } else if sessions.contains(where: { $0 as? String == "Background" }) {
                check("loaded", "Loaded", nil, "Background-session agent")
            } else if sessions.isEmpty {
                check("loaded", "Loaded", nil, "LimitLoadToSessionType is an empty list")
            } else if !invalid.isEmpty {
                let what = def.raw["LimitLoadToSessionType"] is [Any] ? "includes" : "is"
                find("loaded", .error, "launchd will never load it",
                     "Its LimitLoadToSessionType \(what) \(invalid.joined(separator: ", ")), which \(invalid.count == 1 ? "isn’t a session type" : "aren’t session types") launchd knows (they’re case-sensitive: Aqua, Background, LoginWindow…).",
                     [.editPlist])
            } else {
                check("loaded", "Loaded", nil, "Loads only in \(sessions.compactMap { $0 as? String }.joined(separator: ", ")) sessions")
            }
        }

        let quiet = [def.standardOutPath, def.standardErrorPath].allSatisfy { $0 == nil || $0 == "/dev/null" }
        if job.isRestartLooping, let runs = job.runs, let code = job.lastExit {
            check("loop", "Not stuck in a restart loop", false, "\(runs.formatted()) runs")
            find("loop", .error, quiet ? "Restart loop, output discarded" : "It’s stuck in a restart loop",
                 "launchd has started it \(runs.formatted()) times and it keeps failing (\(ExitCode.explain(code)))" + (quiet ? " Its output goes to /dev/null, so nothing records why." : ""),
                 [.disable, .editPlist])
            return
        }
        guard job.pid == nil, let code = job.lastExit else {
            if job.lastExit == 0 { check("exit", "Last run succeeded", true) }
            return
        }
        let reason = job.detail?.lastExitReason ?? ""
        let alreadyExplained = findings.contains { ["program", "workdir", "tildepath", "logdir", "quarantine"].contains($0.id) && $0.severity == .error }
        switch code {
        case 0:
            check("exit", "Last run succeeded", true)
        case _ where reason.contains("OS_REASON_EXEC") || reason.contains("OS_REASON_CODESIGNING"):
            check("exit", "Last run succeeded", false, reason)
            if !alreadyExplained {
                find("exit", .error, "macOS stopped it before it ran",
                     reason.contains("CODESIGNING")
                        ? "The program’s code signature is invalid, so macOS killed it before it ran."
                        : "macOS refused to run the program (\(reason)), for example because it isn’t properly signed.",
                     [.revealPlist, .disable])
            }
        case _ where ExitCode.isPoliteStop(code):
            check("exit", "Last run succeeded", true, "Stopped (\(ExitCode.short(code)))")
        case -9:
            check("exit", "Last run succeeded", false, "Killed (SIGKILL)")
            if reason.hasPrefix("JETSAM") && !reason.contains("IDLE_EXIT") {
                find("exit", .warning, "macOS ended it to free memory",
                     "Its last run was killed by macOS’s memory manager (\(reason)).", [])
            } else if !reason.contains("IDLE_EXIT") {
                find("exit", .warning, "It was killed (SIGKILL)",
                     "Its last run was force quit, by a person, a tool, or launchd after a stop that took too long.")
            }
        case 78 where job.detail?.jobState != "exited":
            check("exit", "Last run succeeded", false, "launchd couldn’t start it")
            if !alreadyExplained {
                find("exit", .error, "launchd can’t start it",
                     "launchd tried to start it and the start itself failed (it records exit 78, but the program never ran). Check its program, working directory and log paths.",
                     [.editPlist, .disable])
            }
        default:
            check("exit", "Last run succeeded", false, ExitCode.short(code))
            if !alreadyExplained {
                let sev: Severity = [126, 127].contains(code) ? .error : .warning
                find("exit", sev, "Its last run failed: \(ExitCode.short(code))", ExitCode.explain(code), [.editPlist, .disable])
            }
        }
    }

    // MARK: Helpers

    enum PathState { case exists, missing, unknown }

    /// Whether a path exists, distinguishing "missing" from "can't tell":
    /// folders we can't search (root-only) make the answer unknown, not missing.
    static func pathState(_ path: String) -> PathState {
        if FileManager.default.fileExists(atPath: path) { return .exists }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if FileManager.default.fileExists(atPath: dir) {
                return access(dir, R_OK | X_OK) == 0 ? .missing : .unknown
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return .missing
    }

    /// Root-run daemons only need an execute bit for someone; agents need it for us.
    static func isExecutable(_ path: String, runsAsRoot: Bool) -> Bool {
        if access(path, X_OK) == 0 { return true }
        guard runsAsRoot, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue else { return false }
        return perms & 0o111 != 0
    }

    static func isShellCommand(_ argv: [String]) -> Bool { shellScriptIndex(argv) != nil }

    /// For `sh -c 'script' …` (also `bash -lc`, `env zsh -ec`), the index of the script
    /// string in argv. Only the options right after the shell count.
    static func shellScriptIndex(_ argv: [String]) -> Int? {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
        var i = 0
        if let first = argv.first, (first as NSString).lastPathComponent == "env" {
            i = 1
            while i < argv.count, argv[i].hasPrefix("-") || argv[i].contains("=") { i += 1 }
        }
        guard i < argv.count, shells.contains((argv[i] as NSString).lastPathComponent) else { return nil }
        i += 1
        var hasC = false
        while i < argv.count, argv[i].hasPrefix("-") || argv[i].hasPrefix("+"), argv[i].count > 1 {
            let option = argv[i]
            i += 1
            if option == "--" { break }
            if option.hasPrefix("--") { continue }
            if option.dropFirst().contains("c") && option.hasPrefix("-") { hasC = true }
            if option.dropFirst().contains("o") { i += 1 }  // -o pipefail takes a value
        }
        return hasC && i < argv.count ? i : nil
    }

    /// The interpreter named on a script's #! line, if the file starts with one.
    static func shebangInterpreter(_ path: String) -> String? { shebang(path)?.interpreter }

    /// A script's #! line: its interpreter, the words after it, and whether the
    /// interpreter itself ends in a carriage return (Windows line endings with no
    /// argument make the kernel look for "/bin/sh\r"). Not a folder, not a file we can't read.
    static func shebang(_ path: String) -> (interpreter: String, crlf: Bool, arguments: [String])? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 256)) ?? Data()
        guard head.starts(with: [0x23, 0x21]) else { return nil }  // "#!"
        let line = String(decoding: head.dropFirst(2).prefix { $0 != 0x0A }, as: UTF8.self)
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard var interpreter = words.first else { return nil }
        let crlf = interpreter.hasSuffix("\r")
        if crlf { interpreter.removeLast() }
        return (interpreter, crlf, Array(words.dropFirst()))
    }

    /// `#!/usr/bin/env X`: env looks X up in the job's PATH, not your shell's, and a
    /// miss makes every run exit 127. Flags (-S, -i…) make the line too complex to judge.
    static func checkEnvLookup(_ arguments: [String], script: String, def: JobDefinition,
                               find: (String, Severity, String, String, [Fix]) -> Void) {
        guard !arguments.contains(where: { $0.hasPrefix("-") }),
              let command = arguments.first(where: { !$0.contains("=") }), !command.contains("/") else { return }
        let path = def.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let found = path.split(separator: ":").contains { dir in
            dir.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: "\(dir)/\(command)")
        }
        guard !found else { return }
        let name = command.replacingOccurrences(of: "\r", with: "")
        let cr = command.hasSuffix("\r") ? " The #! line also ends in a carriage return (Windows line endings), which env treats as part of the name." : ""
        find("envlookup", .warning, "Its script can’t find \(name)",
             "\(abbreviate(script)) runs \(name) through env, which searches only the job’s PATH (\(path)), not your shell’s, and \(name) isn’t there, so every run exits 127.\(cr) Use the full path on the #! line, or set PATH in the job’s EnvironmentVariables.",
             [.revealPlist])
    }

    static func hasQuarantine(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// The flags field of com.apple.quarantine ("0081;…" → 0x81), or nil if absent.
    static func quarantineFlags(_ path: String) -> Int? {
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(path, "com.apple.quarantine", &buf, size, 0, 0) == size else { return nil }
        let value = String(decoding: buf, as: UTF8.self)
        return Int(value.split(separator: ";").first ?? "", radix: 16) ?? 0
    }

    /// LimitLoadToSessionType as a list; missing means Aqua. Entries that aren't text
    /// stay in the list (as themselves) so they can be reported.
    static func sessionTypes(_ def: JobDefinition) -> [Any] {
        switch def.raw["LimitLoadToSessionType"] {
        case nil: return ["Aqua"]
        case let s as String: return [s]
        case let a as [Any]: return a
        case let v?: return [v]
        }
    }

    static func typeName(_ value: Any) -> String {
        switch value {
        case let n as NSNumber: CFGetTypeID(n) == CFBooleanGetTypeID() ? "true/false value" : "number"
        case is [Any]: "list"
        case is [String: Any]: "dictionary"
        case is Data: "data blob"
        case is Date: "date"
        default: "non-text value"
        }
    }

    /// A plist value in words: “the text “yes””, “the number 1”, “a list”.
    static func describeValue(_ value: Any) -> String {
        switch value {
        case let s as String: "the text “\(s)”"
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): "the number \(n.stringValue)"
        default: "a \(typeName(value))"
        }
    }

    static func missingProgramHeadline(_ program: String) -> String {
        let name = (program as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("python") { return "Its Python interpreter is gone" }
        if name == "node" || name == "ruby" || name == "deno" || name == "bun" { return "Its \(name) runtime is gone" }
        return "Its program is missing"
    }

    public static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
