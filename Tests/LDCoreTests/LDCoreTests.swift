import Foundation
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
