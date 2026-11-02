import Foundation
import Testing
@testable import LDCore

// MARK: - Fixtures

private func reviewDetail(state: String? = nil, pid: Int? = nil, runs: Int? = nil, exit: Int? = nil) -> ServiceDetail {
    var d = ServiceDetail()
    d.state = state
    d.pid = pid
    d.runs = runs
    d.lastExitCode = exit
    return d
}

private func reviewJob(_ raw: [String: Any] = [:], label: String = "com.example.review", scope: JobScope = .user,
                       url: URL? = nil, loaded: Bool = true, detail d: ServiceDetail? = nil) -> Job {
    var r = raw
    if r["Label"] == nil { r["Label"] = label }
    if r["ProgramArguments"] == nil && r["Program"] == nil { r["ProgramArguments"] = ["/bin/sleep", "600"] }
    let listing = loaded ? ServiceListing(label: label, pid: d?.pid, lastExit: d?.lastExitCode) : nil
    return Job(definition: JobDefinition(url: url ?? URL(fileURLWithPath: "/tmp/\(label).plist"), scope: scope, raw: r),
               listing: listing, detail: loaded ? d : nil, override: nil)
}

private func reviewFindings(_ j: Job) -> [String: Severity] {
    Dictionary(Doctor.diagnose(j).findings.map { ($0.id, $0.severity) }, uniquingKeysWith: max)
}

private func reviewFinding(_ j: Job, _ id: String) -> Finding? {
    Doctor.diagnose(j).findings.first { $0.id == id }
}

/// Values as PropertyListSerialization produces them from XML, so <integer>1</integer>
/// is an NSNumber that Foundation would happily bridge to true.
private func parsed(_ body: String) throws -> [String: Any] {
    let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>\(body)</dict></plist>"
    return try #require(try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
}

private final class ReviewScratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ldm-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> String { url.appendingPathComponent(name).path }

    @discardableResult
    func file(_ name: String, _ text: String = "", mode: Int = 0o644) throws -> String {
        let p = path(name)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: p)
        return p
    }
}

// MARK: - Program refusals [9] [23]

@Suite struct ProgramRefusals {
    @Test func refusedProgramIsNotAlsoNotLoaded() {
        let relative = reviewJob(["Program": "tool", "StartInterval": 60], loaded: false)
        #expect(reviewFindings(relative)["program"] == .error)
        #expect(reviewFindings(relative)["loaded"] == nil)
        let none = reviewJob(["ProgramArguments": [String](), "StartInterval": 60], loaded: false)
        #expect(reviewFinding(none, "program")?.headline == "It has no program to run")
        #expect(reviewFindings(none)["loaded"] == nil)
    }

    @Test func emptyProgramIsNotAFullPath() {
        let j = reviewJob(["Program": "", "StartInterval": 60], loaded: false)
        let f = reviewFinding(j, "program")
        #expect(f?.headline == "Its Program isn’t a full path")
        #expect(f?.detail.contains("Program is empty") == true)
        #expect(reviewFindings(j)["loaded"] == nil)
    }

    @Test func nonTextArguments() {
        #expect(reviewFindings(reviewJob(["ProgramArguments": ["/bin/echo", 5]]))["programargs"] == .warning)
        // A number first isn't skipped over to find a program.
        let first = reviewJob(["ProgramArguments": [5, "/bin/echo"]])
        #expect(first.definition.program == nil)
        #expect(reviewFinding(first, "program")?.severity == .error)
        #expect(reviewFindings(reviewJob(["ProgramArguments": ["/bin/echo", "hi"]]))["programargs"] == nil)
    }
}

// MARK: - Lookup label for broken plists [11]

@Suite struct BrokenPlistLookup {
    @Test func parseErrorFallsBackToFileName() {
        let broken = JobDefinition(url: URL(fileURLWithPath: "/tmp/com.example.broken.plist"), scope: .user, raw: [:], parseError: "bad")
        #expect(broken.lookupLabel == "com.example.broken")
        let noLabel = JobDefinition(url: URL(fileURLWithPath: "/tmp/com.example.nolabel.plist"), scope: .user, raw: ["ProgramArguments": ["/bin/true"]])
        #expect(noLabel.lookupLabel == nil)
        let loaded = Job(definition: broken, listing: ServiceListing(label: "com.example.broken", pid: 4, lastExit: nil), detail: nil, override: nil)
        #expect(reviewFindings(loaded)["plist"] == .warning)
    }
}

// MARK: - Strict triggers [12] [13] [14]

@Suite struct StrictTriggers {
    @Test func keepAliveThatNeverStartsIt() throws {
        for value: Any in [[String: Any](), ["AfterInitialDemand": true], ["NetworkState": true]] {
            let j = reviewJob(["KeepAlive": value], loaded: false)
            #expect(j.definition.keepAlive == .never)
            #expect(!j.definition.schedule.hasTrigger)
            #expect(j.definition.schedule.summary == "On demand")
            #expect(reviewFinding(j, "trigger")?.headline == "Its start setting is ignored")
            #expect(reviewFindings(j)["loaded"] == nil)
        }
        #expect(reviewFinding(reviewJob(["KeepAlive": ["NetworkState": true]]), "trigger")?.detail.contains("NetworkState") == true)
    }

    @Test func keepAliveThatOnlyRestarts() {
        let crash = reviewJob(["KeepAlive": ["Crashed": true]], detail: reviewDetail(state: "not running", runs: 0))
        #expect(!crash.definition.schedule.hasTrigger)
        #expect(crash.restartsOnItsOwn)
        #expect(reviewFinding(crash, "trigger")?.headline == "It only restarts after a crash")
        #expect(reviewFinding(crash, "trigger")?.severity == .info)

        let afterDemand = reviewJob(["KeepAlive": ["SuccessfulExit": false, "AfterInitialDemand": true]],
                                    detail: reviewDetail(state: "not running", runs: 0))
        #expect(afterDemand.definition.keepAlive == .conditional(["AfterInitialDemand", "SuccessfulExit"]))
        #expect(!afterDemand.definition.schedule.hasTrigger)
        #expect(reviewFinding(afterDemand, "trigger")?.headline == "It only starts when asked, then stays running")
    }

    @Test func keepAliveThatStartsIt() {
        #expect(reviewJob(["KeepAlive": ["Crashed": false]]).definition.schedule.hasTrigger)
        #expect(reviewJob(["KeepAlive": ["PathState": ["/tmp/x": true]]]).definition.schedule.hasTrigger)
        let onFailure = reviewJob(["KeepAlive": ["SuccessfulExit": false, "NetworkState": true]]).definition
        #expect(onFailure.keepAlive == .onFailure)
        #expect(onFailure.schedule.hasTrigger)
    }

    @Test func startIntervalMustBeAPositiveInteger() {
        for value: Any in [0, -1, 60.5, true, "60"] {
            let j = reviewJob(["StartInterval": value], loaded: false)
            #expect(j.definition.startInterval == nil)
            #expect(!j.definition.schedule.hasTrigger)
            #expect(reviewFinding(j, "trigger")?.headline == "Its start setting is ignored")
            #expect(reviewFindings(j)["loaded"] == nil)
        }
        let ok = reviewJob(["StartInterval": 60])
        #expect(ok.definition.startInterval == 60)
        #expect(reviewFindings(ok)["trigger"] == nil)
    }

    @Test func booleansMustBeRealBooleans() throws {
        let raw = try parsed("""
            <key>RunAtLoad</key><integer>1</integer><key>StartOnMount</key><integer>1</integer>
            <key>Disabled</key><integer>1</integer><key>OnDemand</key><integer>0</integer>
            <key>KeepAlive</key><integer>1</integer>
            """)
        #expect(raw["RunAtLoad"] as? Bool == true)  // what the old reading saw
        let j = reviewJob(raw, loaded: false)
        let def = j.definition
        #expect(!def.runAtLoad && !def.startOnMount)
        #expect(def.disabledKey == nil && !j.isDisabled)
        #expect(def.keepAlive == nil)
        #expect(!def.schedule.onDemandServices)
        #expect(!def.schedule.hasTrigger)
        let f = reviewFinding(j, "trigger")
        #expect(f?.severity == .warning)
        for key in ["RunAtLoad", "StartOnMount", "Disabled", "OnDemand", "KeepAlive"] { #expect(f?.detail.contains(key) == true) }

        let exitNumber = try parsed("<key>KeepAlive</key><dict><key>SuccessfulExit</key><integer>0</integer></dict>")
        let k = reviewJob(exitNumber, loaded: false)
        #expect(k.definition.keepAlive == .never)
        #expect(reviewFinding(k, "trigger")?.detail.contains("SuccessfulExit") == true)

        let real = try parsed("<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>")
        #expect(reviewJob(real).definition.runAtLoad)
        #expect(reviewJob(real).definition.keepAlive == .onFailure)
        #expect(reviewFindings(reviewJob(real))["trigger"] == nil)
    }
}

// MARK: - Ignored watch paths [15]

@Suite struct IgnoredWatchPaths {
    @Test func ignoredEntriesAreNotTriggers() {
        let j = reviewJob(["WatchPaths": ["relative/dir"], "QueueDirectories": [""]], loaded: false)
        #expect(j.definition.schedule.watchPaths.isEmpty && j.definition.schedule.queueDirectories.isEmpty)
        #expect(!j.definition.schedule.hasTrigger)
        #expect(reviewFindings(j)["watch"] == .error)
        #expect(reviewFindings(j)["loaded"] == nil)
        #expect(reviewFinding(j, "watch")?.detail.contains("An empty path") == true)
        // Another trigger (StartOnMount too) makes it a warning.
        #expect(reviewFindings(reviewJob(["WatchPaths": ["relative"], "StartOnMount": true]))["watch"] == .warning)
        #expect(reviewJob(["WatchPaths": ["/tmp/x", "rel"]]).definition.schedule.watchPaths == ["/tmp/x"])
    }
}

// MARK: - Relative log paths and the job's user [16] [17]

@Suite struct LogPathsAndUsers {
    @Test func relativeLogUnderWritableBase() throws {
        let s = try ReviewScratch()
        #expect(reviewFindings(reviewJob(["StandardOutPath": "logs/out.log", "WorkingDirectory": s.url.path]))["tildepath"] == nil)
        #expect(reviewFindings(reviewJob(["StandardOutPath": "~/out.log", "WorkingDirectory": s.url.path]))["tildepath"] == .warning)
        // Relative to /, which is read-only.
        let rootRelative = reviewFinding(reviewJob(["StandardOutPath": "out.log"]), "tildepath")
        #expect(rootRelative?.severity == .error)
        #expect(rootRelative?.detail.contains("expand ~") == false)
        // A folder that exists under / is fine.
        #expect(reviewFindings(reviewJob(["StandardOutPath": String(s.path("out.log").dropFirst())]))["tildepath"] == nil)
    }

    @Test func rootDaemonIsNotJudgedByOurPermissions() throws {
        let s = try ReviewScratch()
        let locked = s.path("locked")
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o555])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        #expect(reviewFindings(reviewJob(["StandardOutPath": "~/out.log", "WorkingDirectory": locked], scope: .system))["tildepath"] == .warning)
        #expect(reviewFindings(reviewJob(["StandardOutPath": "~/out.log", "WorkingDirectory": locked]))["tildepath"] == .error)
        #expect(Doctor.logAccess(locked + "/out.log", user: .root) == .ok)
    }

    @Test func otherUsersAreJudgedByModeBits() throws {
        let s = try ReviewScratch()
        let mine = s.path("mine")
        try FileManager.default.createDirectory(atPath: mine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(Doctor.logAccess(mine + "/out.log", user: .me) == .ok)
        #expect(Doctor.logAccess(mine + "/out.log", user: .other("nobody")) == .blocked("\(Doctor.abbreviate(mine)) isn’t writable by nobody"))
        #expect(Doctor.logAccess(mine + "/out.log", user: .other("ldm-no-such-user-xyz")) == .unknown)
        let open = s.path("open")
        try FileManager.default.createDirectory(atPath: open, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: open)
        #expect(Doctor.logAccess(open + "/out.log", user: .other("nobody")) == .ok)

        // A UserName daemon we can't judge gets no "can't open its log" error.
        let j = reviewJob(["StandardOutPath": mine + "/out.log", "UserName": "ldm-no-such-user-xyz"], scope: .system,
                          detail: reviewDetail(state: "not running", runs: 0))
        #expect(reviewFindings(j)["logdir"] == nil)
        #expect(Doctor.diagnose(j).checks.first { $0.id == "logdir" }?.passed == nil)
        let nobody = reviewJob(["StandardOutPath": mine + "/out.log", "UserName": "nobody"], scope: .system,
                               detail: reviewDetail(state: "not running", runs: 0))
        #expect(reviewFindings(nobody)["logdir"] == .error)
    }
}

// MARK: - #! interpreters [19]

@Suite struct Interpreters {
    @Test func interpreterThatIsntExecutable() throws {
        let s = try ReviewScratch()
        let dirScript = try s.file("a.sh", "#!\(s.url.path)\n", mode: 0o755)
        #expect(reviewFinding(reviewJob(["ProgramArguments": [dirScript]]), "program")?.headline == "Its script’s interpreter isn’t executable")
        let plain = try s.file("interp", "binary", mode: 0o644)
        let plainScript = try s.file("b.sh", "#!\(plain)\n", mode: 0o755)
        #expect(reviewFinding(reviewJob(["ProgramArguments": [plainScript]]), "program")?.headline == "Its script’s interpreter isn’t executable")
    }

    @Test func carriageReturnOnlyCountsOnTheInterpreter() throws {
        let s = try ReviewScratch()
        let withArg = try s.file("c.sh", "#!/bin/sh -e\r\necho hi\r\n", mode: 0o755)
        #expect(reviewFindings(reviewJob(["ProgramArguments": [withArg]]))["program"] == nil)
        let bare = try s.file("d.sh", "#! /bin/sh\r\n", mode: 0o755)
        #expect(reviewFinding(reviewJob(["ProgramArguments": [bare]]), "program")?.headline == "Its script has Windows line endings")
    }

    @Test func envLooksInTheJobsPath() throws {
        let s = try ReviewScratch()
        let script = try s.file("e.sh", "#!/usr/bin/env ldm-no-such-tool-xyz\n", mode: 0o755)
        let f = reviewFinding(reviewJob(["ProgramArguments": [script]]), "envlookup")
        #expect(f?.severity == .warning)
        #expect(f?.detail.contains("127") == true)
        try s.file("bin/ldm-no-such-tool-xyz", "#!/bin/sh\n", mode: 0o755)
        let withPath = reviewJob(["ProgramArguments": [script], "EnvironmentVariables": ["PATH": s.path("bin") + ":/usr/bin"]])
        #expect(reviewFindings(withPath)["envlookup"] == nil)
        let flags = try s.file("f.sh", "#!/usr/bin/env -S ldm-no-such-tool-xyz -x\n", mode: 0o755)
        #expect(reviewFindings(reviewJob(["ProgramArguments": [flags]]))["envlookup"] == nil)
    }

    @Test func nestedInterpreter() throws {
        let s = try ReviewScratch()
        let inner = try s.file("inner", "#!/bin/sh\necho inner\n", mode: 0o755)
        let outer = try s.file("outer.sh", "#!\(inner)\necho body\n", mode: 0o755)
        let f = reviewFindings(reviewJob(["ProgramArguments": [outer]]))
        #expect(f["interpreter"] == .warning)
        #expect(f["program"] == nil)
    }
}

// MARK: - Calendar runs [20]

@Suite struct CalendarRuns {
    func schedule(_ c: [String: Int]) -> Schedule {
        JobDefinition(url: URL(fileURLWithPath: "/tmp/x.plist"), scope: .user, raw: ["StartCalendarInterval": c]).schedule
    }

    @Test func day31OnlyInLongMonths() {
        let runs = schedule(["Day": 31, "Hour": 9, "Minute": 0]).nextRuns(count: 4)
        #expect(runs.count == 4)
        #expect(runs.allSatisfy { Calendar.current.component(.day, from: $0) == 31 })
        #expect(schedule(["Day": 30, "Month": 2, "Hour": 9, "Minute": 0]).nextRuns(count: 2).isEmpty)
    }

    @Test func dayAndWeekdayMeanEither() throws {
        let cal = Calendar.current
        // Sunday 2026-11-01 12:00: the next Monday (Nov 2) comes before day 5.
        let start = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        let runs = schedule(["Day": 5, "Weekday": 1, "Hour": 9, "Minute": 0]).nextRuns(after: start, count: 3)
        let days = runs.map { cal.component(.day, from: $0) }
        #expect(days == [2, 5, 9])
        #expect(Schedule.describe(calendar: ["Day": 5, "Weekday": 1, "Hour": 9, "Minute": 0]) == "Mondays and on day 5 of each month at 09:00")
        #expect(Schedule.describe(calendar: ["Weekday": 1, "Month": 3, "Hour": 9, "Minute": 0]) == "Mondays in March at 09:00")
    }
}

// MARK: - Shell -c detection [21]

@Suite struct ShellScripts {
    @Test func onlyARealDashCExemptsTheScript() {
        #expect(reviewFindings(reviewJob(["ProgramArguments": ["/bin/sh", "/tmp/x.sh", "--force-color", "~/x"]]))["tilde"] == .warning)
        #expect(reviewFindings(reviewJob(["ProgramArguments": ["/bin/sh", "-c", "ls \"$1\"", "sh", "~/x"]]))["tilde"] == .warning)
        #expect(reviewFindings(reviewJob(["ProgramArguments": ["/usr/bin/env", "bash", "-lc", "~/bin/run"]]))["tilde"] == nil)
        #expect(reviewFindings(reviewJob(["ProgramArguments": ["/bin/zsh", "-o", "pipefail", "-c", "~/bin/run"]]))["tilde"] == nil)
        #expect(Doctor.shellScriptIndex(["/bin/bash", "-ec", "true"]) == 2)
        #expect(Doctor.shellScriptIndex(["/bin/bash", "--norc", "x.sh"]) == nil)
    }
}

// MARK: - Session types [22]

@Suite struct SessionTypes {
    @Test func badSessionTypes() {
        func loaded(_ v: Any) -> Finding? {
            reviewFinding(reviewJob(["StartInterval": 60, "LimitLoadToSessionType": v], loaded: false), "loaded")
        }
        #expect(loaded([String]()) == nil)
        #expect(loaded(["aqua", "LoginWindow"])?.severity == .error)
        #expect(loaded(["aqua", "LoginWindow"])?.detail.contains("includes aqua,") == true)
        #expect(loaded([5])?.severity == .error)
        #expect(loaded(["LoginWindow"]) == nil)
        #expect(loaded(["Aqua", 5])?.headline == "It isn’t loaded")
        #expect(loaded("aqua")?.detail.contains("is aqua, which isn’t a session type") == true)
    }
}

// MARK: - Dismissals that survive runtime changes [10]

@Suite struct DismissalPruning {
    @Test func runtimeProblemsStayDismissedWhileRunning() throws {
        let s = try ReviewScratch()
        let store = URL(fileURLWithPath: s.path("dismissed.json"))
        let plist = URL(fileURLWithPath: try s.file("com.example.review.plist", "x"))
        let failed = reviewJob(["StartInterval": 60], url: plist, detail: reviewDetail(state: "not running", runs: 1, exit: 1))
        let diag = Doctor.diagnose(failed)
        #expect(diag.findings.contains { $0.id == "exit" })
        try Dismissals.dismiss(diag, at: store)
        #expect(Dismissals.load(from: store).first?.plistModified != nil)

        // Running now: the exit problem is gone for the moment, not fixed.
        let running = reviewJob(["StartInterval": 60], url: plist, detail: reviewDetail(state: "running", pid: 9, runs: 2, exit: 1))
        Dismissals.prune(current: Doctor.problems(in: [running]), jobs: [running], at: store)
        #expect(Dismissals.load(from: store).count == 1)
        // Stopped again without a new exit status: still kept.
        let idle = reviewJob(["StartInterval": 60], url: plist, detail: reviewDetail(state: "not running", runs: 2))
        Dismissals.prune(current: Doctor.problems(in: [idle]), jobs: [idle], at: store)
        #expect(Dismissals.load(from: store).count == 1)
        // The failure comes back: still dismissed.
        #expect(Doctor.triage([failed], dismissals: Dismissals.load(from: store)).dismissed.count == 1)
        // A successful run means it's fixed.
        let fixed = reviewJob(["StartInterval": 60], url: plist, detail: reviewDetail(state: "not running", runs: 3, exit: 0))
        Dismissals.prune(current: Doctor.problems(in: [fixed]), jobs: [fixed], at: store)
        #expect(Dismissals.load(from: store).isEmpty)
    }

    @Test func editedPlistOrRemovedJobDropsIt() throws {
        let s = try ReviewScratch()
        let store = URL(fileURLWithPath: s.path("dismissed.json"))
        let plist = URL(fileURLWithPath: try s.file("com.example.review.plist", "x"))
        let failed = reviewJob(["StartInterval": 60], url: plist, detail: reviewDetail(state: "not running", runs: 1, exit: 1))
        try Dismissals.dismiss(Doctor.diagnose(failed), at: store)
        let idle = reviewJob(["StartInterval": 60], url: plist, detail: reviewDetail(state: "not running", runs: 1))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: plist.path)
        Dismissals.prune(current: Doctor.problems(in: [idle]), jobs: [idle], at: store)
        #expect(Dismissals.load(from: store).isEmpty)

        try Dismissals.dismiss(Doctor.diagnose(failed), at: store)
        Dismissals.prune(current: [], jobs: [], at: store)
        #expect(Dismissals.load(from: store).isEmpty)
    }

    @Test func staticProblemsDropAsSoonAsTheyAreGone() throws {
        let s = try ReviewScratch()
        let store = URL(fileURLWithPath: s.path("dismissed.json"))
        let broken = reviewJob(["ProgramArguments": ["/nonexistent/tool"], "StartInterval": 60])
        try Dismissals.dismiss(Doctor.diagnose(broken), at: store)
        let repaired = reviewJob(["StartInterval": 60])
        Dismissals.prune(current: Doctor.problems(in: [repaired]), jobs: [repaired], at: store)
        #expect(Dismissals.load(from: store).isEmpty)
    }

    @Test func olderFilesStillDecode() throws {
        let s = try ReviewScratch()
        let store = URL(fileURLWithPath: s.path("dismissed.json"))
        try Data(#"[{"label":"a","findingID":"exit","headline":"h","dismissedAt":"2026-01-01T00:00:00Z"}]"#.utf8).write(to: store)
        let d = Dismissals.load(from: store)
        #expect(d.count == 1 && d[0].plistModified == nil)
    }
}
