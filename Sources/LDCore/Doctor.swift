import Foundation

public enum Severity: Int, Comparable, Codable, Sendable {
    case info, warning, error
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

/// One-click remedies the app and CLI can offer for a finding.
public enum Fix: Hashable, Codable, Sendable {
    case disable
    case load
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
        case .chooseProgram: "Point the job at a program that exists. Shows a diff before saving."
        case .revealPlist: "Show the plist in Finder."
        case .editPlist: "Open the job editor."
        case .openTerminal(let d): "Investigate in \((d as NSString).abbreviatingWithTildeInPath)."
        case .removeQuarantine: "Clear the quarantine flag so launchd can run it."
        case .createDirectory(let p): "Create \((p as NSString).abbreviatingWithTildeInPath) so launchd can write the log."
        case .fixPermissions: "Set the owner and mode launchd requires."
        case .openLoginItems: "Turn it back on under Allow in the Background. Only you can change this switch."
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

    public var id: String { job.id }
    public var worst: Severity? { findings.map(\.severity).max() }
    public var isProblem: Bool { (worst ?? .info) >= .warning }
    public var primary: Finding? { findings.max { $0.severity < $1.severity } }
}

/// Answers "why isn't my job running?". Pure checks over the job's plist, the
/// file system and launchd state; nothing here changes anything.
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
        let fm = FileManager.default

        func check(_ id: String, _ name: String, _ passed: Bool?, _ note: String? = nil) {
            checks.append(CheckResult(id: id, name: name, passed: passed, note: note))
        }
        func find(_ id: String, _ sev: Severity, _ headline: String, _ detail: String, _ fixes: [Fix] = []) {
            findings.append(Finding(id: id, severity: sev, headline: headline, detail: detail, fixes: fixes))
        }

        // 1. Valid plist
        if let err = def.parseError {
            check("plist", "Plist is valid", false, err)
            find("plist", .error, "The plist can’t be read", "launchd can’t load a file that isn’t a valid property list: \(err)", [.editPlist, .revealPlist])
            return Diagnosis(job: job, checks: checks, findings: findings)
        }
        check("plist", "Plist is valid", true)

        // 2. Label
        if def.declaredLabel == nil {
            check("label", "Has a Label that matches the file name", false, "No Label key")
            find("label", .error, "Plist has no Label key", "Every launchd job needs a Label. launchd won’t load this file.", [.editPlist, .revealPlist])
        } else if def.label != def.fileStem {
            check("label", "Has a Label that matches the file name", false, "Label is \(def.label)")
            find("label", .warning, "Label doesn’t match the file name", "The file is \(def.url.lastPathComponent) but its Label is \(def.label). It works, but tools and people look jobs up by file name.", [.editPlist])
        } else {
            check("label", "Has a Label that matches the file name", true)
        }

        // 3. Program
        let usesShell = isShellCommand(def.commandLine)
        if let program = def.program {
            let resolved = resolveExecutable(program)
            if def.bundleProgram != nil {
                check("program", "Program exists and is executable", nil, "Bundle-relative program")
            } else if program.hasPrefix("~") {
                check("program", "Program exists and is executable", false, "\(program) — launchd doesn’t expand ~")
                find("program", .error, "Its program path uses ~", "launchd isn’t a shell and doesn’t expand ~. Use the full path.", [.chooseProgram])
            } else if let path = resolved, isExecutable(path, runsAsRoot: def.scope.isDaemon && def.userName == nil) {
                check("program", "Program exists and is executable", true, abbreviate(path))
                if hasQuarantine(path) {
                    check("quarantine", "Program isn’t quarantined", false)
                    find("quarantine", .warning, "Its program is quarantined", "\(abbreviate(path)) carries the com.apple.quarantine flag, which can stop launchd from running it on recent macOS.", [.removeQuarantine(path: path)])
                } else {
                    check("quarantine", "Program isn’t quarantined", true)
                }
            } else if let path = resolved, pathState(path) != .missing {
                check("program", "Program exists and is executable", false, "\(abbreviate(path)) — not executable")
                find("program", .error, "Its program isn’t executable", "\(abbreviate(path)) exists but doesn’t have execute permission.", [.chooseProgram, .revealPlist])
            } else {
                check("program", "Program exists and is executable", false, "\(abbreviate(program)) — not found")
                let dir = existingAncestor(of: program)
                find("program", .error, missingProgramHeadline(program), "The program the job points at, \(abbreviate(program)), doesn’t exist, so every start fails immediately.", [.chooseProgram] + (dir.map { [.openTerminal(directory: $0)] } ?? []) + [.disable])
            }
        } else {
            check("program", "Program exists and is executable", false, "No Program or ProgramArguments")
            find("program", .error, "It has no program to run", "Set Program or ProgramArguments.", [.editPlist])
        }

        // 4. Tilde in arguments (fine inside `sh -c` strings)
        let tildeArgs = def.commandLine.dropFirst().filter { $0.hasPrefix("~/") }
        if !usesShell, !tildeArgs.isEmpty {
            check("tilde", "No unexpanded ~ in arguments", false, tildeArgs.joined(separator: " "))
            find("tilde", .error, "Its arguments use ~", "launchd passes ~ literally. Use full paths, or run through /bin/sh -c.", [.editPlist])
        }
        let tildePaths = [def.standardOutPath, def.standardErrorPath, def.workingDirectory].compactMap { $0 }.filter { $0.hasPrefix("~") }
        if !tildePaths.isEmpty {
            find("tildepath", .error, "A log or working directory path uses ~", "launchd doesn’t expand ~ in \(tildePaths.joined(separator: ", ")).", [.editPlist])
        }

        // 5. Ownership and permissions
        if let attrs = try? fm.attributesOfItem(atPath: def.url.path),
           let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value,
           let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue {
            let expectedOwner: UInt32 = def.scope == .user ? getuid() : 0
            let writableByOthers = perms & 0o022 != 0
            if owner != expectedOwner || writableByOthers {
                var why: [String] = []
                if owner != expectedOwner { why.append(def.scope == .user ? "isn’t owned by you" : "isn’t owned by root") }
                if writableByOthers { why.append("is writable by group or others") }
                check("perms", "Owner and permissions are what launchd expects", false, why.joined(separator: ", "))
                find("perms", .error, "launchd will reject its permissions", "The plist \(why.joined(separator: " and ")). launchd refuses such files as “dubious”.", [.fixPermissions])
            } else {
                check("perms", "Owner and permissions are what launchd expects", true)
            }
        }

        // 6. Log folders
        let logPaths = Set([def.standardOutPath, def.standardErrorPath].compactMap { $0 }).filter { $0 != "/dev/null" && !$0.hasPrefix("~") }
        let missingDirs = logPaths.map { ($0 as NSString).deletingLastPathComponent }.filter { pathState($0) == .missing }
        if let dir = missingDirs.first {
            check("logdir", "Log folder exists", false, abbreviate(dir))
            find("logdir", .warning, "Its log folder doesn’t exist", "launchd doesn’t create folders; output to \(abbreviate(dir)) is lost.", [.createDirectory(path: dir)])
        } else if !logPaths.isEmpty {
            check("logdir", "Log folder exists", true)
        }

        // 7. Trigger
        if !def.schedule.hasTrigger {
            check("trigger", "Has a way to start", false, "Only starts when asked")
            find("trigger", .info, "It never starts by itself", "No RunAtLoad, schedule, KeepAlive or watched paths. That’s fine for jobs you start by hand.")
        } else {
            check("trigger", "Has a way to start", true, def.schedule.summary)
        }

        // 8. Watched paths
        let missingWatch = def.watchPaths.filter { pathState(($0 as NSString).deletingLastPathComponent) == .missing }
        if !missingWatch.isEmpty {
            find("watch", .info, "A watched folder doesn’t exist", "\(missingWatch.map(abbreviate).joined(separator: ", ")) can’t be watched until its folder exists.")
        }

        // Runtime checks only matter for jobs meant to run.
        if !job.isDisabled {
            check("enabled", "Enabled in launchd", true)
            if let bg = job.background {
                if bg.isOn {
                    check("background", "Allowed in the Background", true)
                } else {
                    check("background", "Allowed in the Background", false, bg.summary)
                    find("background", .error,
                         bg.isAllowed ? "It’s switched off in Login Items" : "A policy blocks it from running in the background",
                         bg.isAllowed
                            ? "launchd has it enabled, but System Settings → General → Login Items & Extensions → Allow in the Background has it switched off, so macOS won’t let it run."
                            : "A management profile or system policy disallows it in Background Items, so macOS won’t let it run.",
                         bg.isAllowed ? [.openLoginItems] : [])
                }
            }
            if !job.isLoaded && def.schedule.hasTrigger && def.declaredLabel != nil && !job.isBlockedInBackground {
                find("loaded", .warning, "It isn’t loaded", "The job is enabled but not loaded in launchd, so its triggers do nothing until it’s loaded or you log in again.", [.load])
            }
            if let code = job.lastExit, code != 0 {
                let looping = (job.runs ?? 0) > 100 && def.keepAlive != nil && def.keepAlive != .never && job.pid == nil
                let quiet = [def.standardOutPath, def.standardErrorPath].allSatisfy { $0 == nil || $0 == "/dev/null" }
                if looping {
                    check("loop", "Not stuck in a restart loop", false, "\(job.runs!.formatted()) runs")
                    find("loop", .error, quiet ? "Restart loop, output discarded" : "It’s stuck in a restart loop",
                         "launchd has started it \(job.runs!.formatted()) times and it keeps exiting (\(ExitCode.explain(code)))" + (quiet ? " Its output goes to /dev/null, so nothing records why." : ""),
                         [.disable, .editPlist])
                } else if job.pid == nil {
                    check("exit", "Last run succeeded", false, ExitCode.short(code))
                    let sev: Severity = [78, 126, 127].contains(code) || code < 0 ? .error : .warning
                    if !findings.contains(where: { $0.id == "program" }) {
                        find("exit", sev, "Its last run failed: \(ExitCode.short(code))", ExitCode.explain(code), [.editPlist, .disable])
                    }
                }
            } else if job.lastExit == 0 {
                check("exit", "Last run succeeded", true)
            }
        } else {
            check("enabled", "Enabled in launchd", false, "Disabled — skipped runtime checks")
        }

        return Diagnosis(job: job, checks: checks, findings: findings)
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
        if FileManager.default.isExecutableFile(atPath: path) { return true }
        guard runsAsRoot, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue else { return false }
        return perms & 0o111 != 0
    }

    static func isShellCommand(_ argv: [String]) -> Bool {
        guard let first = argv.first else { return false }
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
        return shells.contains((first as NSString).lastPathComponent) && argv.dropFirst().contains { $0.hasPrefix("-") && $0.contains("c") }
    }

    static func resolveExecutable(_ program: String) -> String? {
        if program.hasPrefix("/") { return program }
        for dir in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            let p = dir + "/" + program
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    static func hasQuarantine(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    static func existingAncestor(of path: String) -> String? {
        var p = (path as NSString).deletingLastPathComponent
        while p.count > 1 {
            if FileManager.default.fileExists(atPath: p) { return p }
            p = (p as NSString).deletingLastPathComponent
        }
        return nil
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
