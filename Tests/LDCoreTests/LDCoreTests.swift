import Foundation
import Security
import Testing
@testable import LDCore

@Suite struct LaunchctlParsing {
    @Test func servicesTable() {
        let text = """
        gui/501 = {
        \tservices = {
        \t\t       0      1 \tcom.example.backup
        \t\t   37198   (pe) \tcom.example.sync
        \t\t     661      - \tcom.example.server
        \t\t       0    -15 \tcom.example.killed
        \t}
        \tunmanaged processes = {
        \t\t     999      - \tnot.a.service
        \t}
        }
        """
        let s = Launchctl.parseServices(text)
        #expect(s.count == 4)
        #expect(s["com.example.backup"] == ServiceListing(label: "com.example.backup", pid: nil, lastExit: 1))
        #expect(s["com.example.sync"]?.pid == 37198)
        #expect(s["com.example.server"]?.lastExit == nil)
        #expect(s["com.example.killed"]?.lastExit == -15)
        #expect(s["not.a.service"] == nil)
    }

    @Test func disabledOverrides() {
        let text = """
        \tdisabled services = {
        \t\t"com.example.off" => disabled
        \t\t"com.example.on" => enabled
        \t\t"com.example.legacy" => true
        \t}
        """
        let d = Launchctl.parseDisabled(text)
        #expect(d == ["com.example.off": true, "com.example.on": false, "com.example.legacy": true])
    }

    @Test func serviceDetail() {
        let text = """
        gui/501/com.example.sync = {
        \tactive count = 0
        \tstate = spawn scheduled
        \truns = 284
        \tlast exit code = 78: EX_CONFIG
        \tenvironment = {
        \t\tstate = nested-should-be-ignored
        \t}
        }
        """
        let d = Launchctl.parseDetail(text)
        #expect(d.state == "spawn scheduled")
        #expect(d.runs == 284)
        #expect(d.lastExitCode == 78)
        #expect(d.pid == nil)
    }

    @Test func terminatingSignal() {
        let d = Launchctl.parseDetail("x = {\n\tstate = running\n\tpid = 42\n\tlast terminating signal = Terminated: 15\n}")
        #expect(d.pid == 42)
        #expect(d.lastExitCode == -15)
    }
}

@Suite struct Schedules {
    func def(_ raw: [String: Any], scope: JobScope = .user) -> JobDefinition {
        JobDefinition(url: URL(fileURLWithPath: "/tmp/com.example.job.plist"), scope: scope, raw: raw)
    }

    @Test func intervals() {
        #expect(Schedule.describe(interval: 60) == "Every minute")
        #expect(Schedule.describe(interval: 1800) == "Every 30 minutes")
        #expect(Schedule.describe(interval: 21600) == "Every 6 hours")
        #expect(Schedule.describe(interval: 30) == "Every 30 seconds")
        #expect(Schedule.describe(interval: 86400) == "Every day")
    }

    @Test func calendar() {
        #expect(Schedule.describe(calendar: ["Weekday": 1, "Hour": 9, "Minute": 30]) == "Mondays at 09:30")
        #expect(Schedule.describe(calendar: ["Hour": 3, "Minute": 0]) == "Daily at 03:00")
        #expect(Schedule.describe(calendar: ["Minute": 15]) == "Every hour at :15")
        #expect(Schedule.describe(calendar: ["Day": 1, "Hour": 0, "Minute": 0]) == "On day 1 of each month at 00:00")
    }

    @Test func summaries() {
        #expect(def(["StartInterval": 60, "RunAtLoad": true]).schedule.summary == "Every minute · at login")
        #expect(def(["KeepAlive": true, "RunAtLoad": true]).schedule.summary == "Always running")
        #expect(def(["KeepAlive": ["SuccessfulExit": false]]).schedule.summary == "Restarts when it fails")
        #expect(def(["RunAtLoad": true], scope: .system).schedule.summary == "At boot")
        #expect(def([:]).schedule.summary == "On demand")
    }

    @Test func nextRunsAreMondays() {
        let s = def(["StartCalendarInterval": ["Weekday": 1, "Hour": 9, "Minute": 30]]).schedule
        let runs = s.nextRuns(count: 3)
        #expect(runs.count == 3)
        for r in runs {
            let c = Calendar.current.dateComponents([.weekday, .hour, .minute], from: r)
            #expect(c.weekday == 2 && c.hour == 9 && c.minute == 30)
        }
    }
}

@Suite struct Editing {
    @Test func unknownKeysSurvive() {
        let old: [String: Any] = ["Label": "com.example.job", "ProgramArguments": ["/bin/old"], "CustomKey": ["a": 1]]
        let new = PlistEditor.apply(["ProgramArguments": ["/bin/new"]], to: old)
        #expect((new["CustomKey"] as? [String: Int]) == ["a": 1])
        let diff = PlistEditor.diff(old, new)
        #expect(diff.count == 1)
        #expect(diff[0].key == "ProgramArguments")
        #expect(diff[0].old == "[/bin/old]")
        #expect(diff[0].new == "[/bin/new]")
    }

    @Test func triggerReplacesOtherTriggers() {
        let old: [String: Any] = ["Label": "x", "StartInterval": 60, "RunAtLoad": true]
        let new = PlistEditor.apply(Trigger.keepAlive(onlyOnFailure: true).updates(runAtLoad: false), to: old)
        #expect(new["StartInterval"] == nil)
        #expect((new["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
    }

    @Test func durationsAndCron() throws {
        #expect(Trigger.parseDuration("15m") == 900)
        #expect(Trigger.parseDuration("6h") == 21600)
        #expect(Trigger.parseDuration("abc") == nil)
        #expect(try Trigger.parseCron("30 9 * * 1") == [["Minute": 30, "Hour": 9, "Weekday": 1]])
        #expect(try Trigger.parseCron("0 8,20 * * *").count == 2)
        #expect(throws: LDError.self) { try Trigger.parseCron("*/5 * * * *") }
    }

    @Test func writeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ldm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("com.example.job.plist")
        let dict = JobBuilder.make(label: "com.example.job", program: ["/bin/echo", "hi"], trigger: .every(seconds: 900))
        try PlistEditor.write(dict, to: url, scope: .user)
        let def = JobDefinition.load(url: url, scope: .user)
        #expect(def.label == "com.example.job")
        #expect(def.startInterval == 900)
        #expect(def.commandLine == ["/bin/echo", "hi"])
    }
}

@Suite struct Naming {
    @Test func titles() {
        #expect(Job.title(for: "com.example.keystone.agent") == "Keystone agent")
        #expect(Job.title(for: "homebrew.mxcl.ollama") == "Ollama")
        #expect(Job.title(for: "com.example.nightly-backup") == "Nightly backup")
        #expect(Job.title(for: "com.vendor.pilot.28b077471d07ed03.e279b724ecfb4f7a") == "Pilot")
    }

    @Test func exitCodes() {
        #expect(ExitCode.explain(1) == "Exit 1: a general failure reported by the program. Its log usually says why.")
        #expect(ExitCode.explain(2) == "Exit 2: usually wrong command-line usage.")
        #expect(ExitCode.explain(13) == "Exit 13: often permission denied when a program passes errno through as its exit status; programs can use it for other meanings.")
        #expect(ExitCode.explain(255) == "Exit 255: often used by SSH for its own errors; an exit -1 can also be reported as 255. Programs may use it for other meanings.")
        #expect(ExitCode.short(78) == "Exit 78 · config error")
        #expect(ExitCode.short(-15) == "SIGTERM")
        #expect(ExitCode.explain(-9).contains("SIGKILL"))
        #expect(ExitCode.short(137) == "Exit 137 · SIGKILL")
    }

    @Test func resolve() throws {
        func job(_ label: String, _ scope: JobScope = .user) -> Job {
            Job(definition: JobDefinition(url: URL(fileURLWithPath: "/x/\(label).plist"), scope: scope, raw: ["Label": label]),
                listing: nil, detail: nil, override: nil)
        }
        let jobs = [job("com.example.backup"), job("com.example.backup-check"), job("com.apple.backup", .appleAgent)]
        #expect(try Inventory.resolve("backup", in: jobs).label == "com.example.backup")
        #expect(try Inventory.resolve("backup-check", in: jobs).label == "com.example.backup-check")
        #expect(throws: LDError.self) { try Inventory.resolve("nothing", in: jobs) }
    }
}

@Suite struct Diagnosing {
    @Test func missingProgram() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ldm-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("com.example.sync.plist")
        let raw: [String: Any] = ["Label": "com.example.sync", "ProgramArguments": [dir.path + "/venv/bin/python", "sync.py"], "StartInterval": 1800]
        try PlistEditor.xml(raw).write(to: url)
        let job = Job(definition: JobDefinition.load(url: url, scope: .user),
                      listing: ServiceListing(label: "com.example.sync", pid: nil, lastExit: 78), detail: nil, override: nil)
        let d = Doctor.diagnose(job)
        #expect(d.isProblem)
        #expect(d.primary?.headline == "Its Python interpreter is gone")
        #expect(d.primary?.fixes.first == .chooseProgram)
    }

    @Test func noLabel() {
        let job = Job(definition: JobDefinition(url: URL(fileURLWithPath: "/tmp/com.example.nolabel.plist"), scope: .user, raw: ["ProgramArguments": ["/bin/true"]]),
                      listing: nil, detail: nil, override: nil)
        #expect(job.status == .invalid)
        #expect(Doctor.diagnose(job).findings.contains { $0.headline == "Plist has no Label key" })
    }
}

@Suite struct BackgroundTaskManagement {
    static let sample = """
    ========================
     Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
    ========================

     ServiceManagement migrated: true

     #1:
                     UUID: 11111111-2222-3333-4444-555555555555
                     Name: exampled
           Developer Name: (null)
                     Type: legacy daemon (0x10010)
                    Flags: [ legacy ] (0x1)
              Disposition: [enabled, disallowed, notified] (0x9)
               Identifier: 16.com.example.daemon
                      URL: /Library/LaunchDaemons/com.example.daemon.plist
          Executable Path: /usr/local/bin/exampled
        Parent Identifier: Unknown Developer

    ========================
     Records for UID 501 : 7E868DFC-65F6-41BD-8EBA-9DDA89CA4353
    ========================

     #1:
                     UUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
                     Name: backup
           Developer Name: Example Corp
          Team Identifier: ABCDE12345
                     Type: legacy agent (0x10008)
                    Flags: [ legacy ] (0x1)
              Disposition: [disabled, allowed, notified] (0xa)
               Identifier: 8.com.example.backup
                      URL: /Users/501/Library/LaunchAgents/com.example.backup.plist
          Executable Path: /usr/local/bin/backup
        Parent Identifier: Example Corp

     #2:
                     UUID: AAAAAAAA-BBBB-CCCC-DDDD-FFFFFFFFFFFF
                     Name: Example App
           Developer Name: Example Corp
                     Type: app (0x2)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 2.com.example.app
                      URL: file:///Applications/Example.app/
    """

    @Test func parsesRecords() {
        let items = BackgroundItems.parse(Self.sample)
        #expect(items.count == 3)
        let daemon = items[0]
        #expect(daemon.uid == -2)
        #expect(daemon.label == "com.example.daemon")
        #expect(daemon.isDaemon && daemon.isLaunchJob)
        #expect(daemon.isEnabled && !daemon.isAllowed && !daemon.isOn)
        #expect(daemon.summary == "Blocked by policy")
        let agent = items[1]
        #expect(agent.uid == 501)
        #expect(agent.typeCode == 0x10008)
        #expect(!agent.isEnabled && agent.summary == "Off in Login Items")
        #expect(agent.owner == "Example Corp")
        #expect(agent.teamIdentifier == "ABCDE12345")
        #expect(!items[2].isLaunchJob)
    }

    @Test func joinsJobsAndBlocks() {
        let snap = BackgroundItems.Snapshot(items: BackgroundItems.parse(Self.sample), date: Date())
        let def = JobDefinition(url: URL(fileURLWithPath: "/tmp/com.example.backup.plist"), scope: .user,
                                raw: ["Label": "com.example.backup", "ProgramArguments": ["/bin/true"], "StartInterval": 60])
        var job = Job(definition: def, listing: nil, detail: nil, override: nil)
        job.background = snap.item(for: job)
        #expect(job.background?.label == "com.example.backup")
        #expect(job.status == .blocked)
        let d = Doctor.diagnose(job)
        #expect(d.findings.contains { $0.headline == "It’s switched off in Login Items" && $0.fixes == [.openLoginItems] })
        #expect(!d.findings.contains { $0.id == "loaded" })
    }
}

@Suite struct HelperPolicyChecks {
    @Test func launchctlAllowList() {
        #expect(HelperPolicy.validateLaunchctl(["bootstrap", "system", "/Library/LaunchDaemons/com.example.d.plist"]) == nil)
        #expect(HelperPolicy.validateLaunchctl(["bootout", "system/com.example.d"]) == nil)
        #expect(HelperPolicy.validateLaunchctl(["kickstart", "-k", "system/com.example.d"]) == nil)
        #expect(HelperPolicy.validateLaunchctl(["kill", "SIGTERM", "system/com.example.d"]) == nil)
        // Other domains, verbs and paths are refused.
        #expect(HelperPolicy.validateLaunchctl(["bootout", "gui/501/com.example.d"]) != nil)
        #expect(HelperPolicy.validateLaunchctl(["bootstrap", "system", "/tmp/evil.plist"]) != nil)
        #expect(HelperPolicy.validateLaunchctl(["bootstrap", "system", "/Library/LaunchAgents/x.plist"]) != nil)
        #expect(HelperPolicy.validateLaunchctl(["setenv", "X", "1"]) != nil)
        #expect(HelperPolicy.validateLaunchctl(["kill", "SIGSTOP; rm -rf /", "system/x"]) != nil)
        #expect(HelperPolicy.validateLaunchctl(["enable", "system/a b"]) != nil)
    }

    @Test func jobPaths() {
        #expect(HelperPolicy.validateJobPath("/Library/LaunchDaemons/com.example.d.plist") == nil)
        #expect(HelperPolicy.validateJobPath("/Library/LaunchAgents/com.example.a.plist") == nil)
        #expect(HelperPolicy.validateJobPath("/Library/LaunchDaemons/../../etc/sudoers.plist") != nil)
        #expect(HelperPolicy.validateJobPath("/Library/LaunchDaemons/sub/x.plist") != nil)
        #expect(HelperPolicy.validateJobPath("/System/Library/LaunchDaemons/x.plist") != nil)
        #expect(HelperPolicy.validateJobPath("/Library/LaunchDaemons/.hidden.plist") != nil)
        #expect(HelperPolicy.validateJobPath("Library/LaunchDaemons/x.plist") != nil)
    }

    @Test func directories() {
        #expect(HelperPolicy.validateDirectory("/Library/Logs/Example") == nil)
        #expect(HelperPolicy.validateDirectory("/usr/local/var/log/example") == nil)
        #expect(HelperPolicy.validateDirectory("/etc/example") != nil)
        #expect(HelperPolicy.validateDirectory("/Library/../etc") != nil)
        #expect(HelperPolicy.validateDirectory("/System/Library/x") != nil)
    }

    @Test func requirementNamesBothClients() {
        let r = HelperPolicy.clientRequirement(team: "ABCDE12345")
        #expect(r.contains("\"ABCDE12345\"") && r.contains(HelperPolicy.appIdentifier) && r.contains(HelperPolicy.cliIdentifier))
        var req: SecRequirement?
        #expect(SecRequirementCreateWithString(r as CFString, [], &req) == errSecSuccess)
    }
}

@Suite struct ReleaseFixes {
    func job(_ raw: [String: Any], listing: ServiceListing?, detail: ServiceDetail?) -> Job {
        var r = raw
        r["Label"] = "com.example.loop"
        r["ProgramArguments"] = ["/bin/sh", "-c", "exit 1"]
        return Job(definition: JobDefinition(url: URL(fileURLWithPath: "/tmp/com.example.loop.plist"), scope: .user, raw: r),
                   listing: listing, detail: detail, override: nil)
    }

    @Test func scheduleKeepsProperNounsCapitalised() {
        let monday = JobDefinition(url: URL(fileURLWithPath: "/tmp/x.plist"), scope: .user,
                                   raw: ["StartCalendarInterval": ["Weekday": 1, "Hour": 9, "Minute": 30]])
        #expect(monday.schedule.summaryInSentence == "Mondays at 09:30")
        let every = JobDefinition(url: URL(fileURLWithPath: "/tmp/x.plist"), scope: .user, raw: ["StartInterval": 1800])
        #expect(every.schedule.summaryInSentence == "every 30 minutes")
    }

    @Test func restartLoopStaysFailedWhileRespawning() {
        let listing = ServiceListing(label: "com.example.loop", pid: 4242, lastExit: 1)
        var detail = ServiceDetail()
        detail.pid = 4242
        detail.runs = 500
        detail.lastExitCode = 1
        detail.state = "running"
        let j = job(["KeepAlive": ["SuccessfulExit": false]], listing: listing, detail: detail)
        #expect(j.isRestartLooping)
        #expect(j.status == .failed)
        #expect(j.resultSummary == "Exit 1 · 500 restarts")
        #expect(Doctor.diagnose(j).findings.contains { $0.id == "loop" })
        #expect(Doctor.problems(in: [j]).count == 1)
    }

    @Test func spawnScheduledWithFailureIsFailed() {
        var detail = ServiceDetail()
        detail.state = "spawn scheduled"
        detail.runs = 300
        detail.lastExitCode = 1
        let j = job(["KeepAlive": true], listing: ServiceListing(label: "com.example.loop", pid: nil, lastExit: 1), detail: detail)
        #expect(j.status == .failed)
        #expect(Doctor.diagnose(j).findings.contains { $0.id == "loop" })
    }

    @Test func healthyKeepAliveIsNotALoop() {
        var detail = ServiceDetail()
        detail.pid = 10
        detail.runs = 1
        detail.lastExitCode = 0
        let j = job(["KeepAlive": true], listing: ServiceListing(label: "com.example.loop", pid: 10, lastExit: 0), detail: detail)
        #expect(!j.isRestartLooping)
        #expect(j.status == .running)
    }

    @Test func missingProgramDoesNotOfferTerminal() {
        let j = Job(definition: JobDefinition(url: URL(fileURLWithPath: "/tmp/com.example.gone.plist"), scope: .user,
                                              raw: ["Label": "com.example.gone", "ProgramArguments": ["/nonexistent/dir/tool"], "StartInterval": 60]),
                    listing: nil, detail: nil, override: nil)
        let fixes = Doctor.diagnose(j).findings.first { $0.id == "program" }?.fixes ?? []
        #expect(fixes.contains(.chooseProgram))
        #expect(!fixes.contains { if case .openTerminal = $0 { true } else { false } })
    }
}

@Suite struct NoUnaskedPrompts {
    /// The test runner isn't signed by LD Manager's team, so the helper never accepts it:
    /// a read that may not prompt must fail without running sfltool.
    @Test func backgroundReadWithoutHelperDoesNotPrompt() {
        let r = Privileged.dumpBackgroundItems(allowPrompt: false)
        #expect(!r.succeeded)
        #expect(r.stderr.contains("may not prompt"))
        #expect(BackgroundItems.refresh(allowPrompt: false) == nil)
    }
}
