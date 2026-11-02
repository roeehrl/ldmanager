import Foundation
import Testing
@testable import LDCore

// MARK: - Fixtures

private func detail(state: String? = nil, pid: Int? = nil, runs: Int? = nil, exit: Int? = nil,
                    jobState: String? = nil, reason: String? = nil) -> ServiceDetail {
    var d = ServiceDetail()
    d.state = state
    d.pid = pid
    d.runs = runs
    d.lastExitCode = exit
    d.jobState = jobState
    d.lastExitReason = reason
    return d
}

private func job(_ raw: [String: Any] = [:], label: String = "com.example.job", scope: JobScope = .user,
                 url: URL? = nil, loaded: Bool = true, detail d: ServiceDetail? = nil, disabled: Bool? = nil) -> Job {
    var r = raw
    if r["Label"] == nil { r["Label"] = label }
    if r["ProgramArguments"] == nil && r["Program"] == nil { r["ProgramArguments"] = ["/bin/sleep", "600"] }
    let listing = loaded ? ServiceListing(label: label, pid: d?.pid, lastExit: d?.lastExitCode) : nil
    return Job(definition: JobDefinition(url: url ?? URL(fileURLWithPath: "/tmp/\(label).plist"), scope: scope, raw: r),
               listing: listing, detail: loaded ? d : nil, override: disabled)
}

/// A scratch folder that disappears with the test.
private final class Scratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ldm-tests-\(UUID().uuidString)")
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

    func quarantine(_ path: String, flags: String) {
        let value = "\(flags);6560d5a1;Safari;"
        _ = value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }

    /// A real binary (a copy of /usr/bin/true) at `name`.
    func binary(_ name: String) throws -> String {
        let p = path(name)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: p)
        return p
    }
}

private func findings(_ j: Job) -> [String: Severity] {
    Dictionary(Doctor.diagnose(j).findings.map { ($0.id, $0.severity) }, uniquingKeysWith: max)
}

// MARK: - States

@Suite struct LaunchdStates {
    @Test func stateStrings() {
        #expect(LaunchdState("running") == .running)
        #expect(LaunchdState("xpcproxy") == .spawning)
        #expect(LaunchdState("SIGTERMed") == .stopping)
        #expect(LaunchdState("spawn scheduled") == .spawnScheduled)
        #expect(LaunchdState("not running") == .notRunning)
        #expect(LaunchdState("something new") == .other("something new"))
        #expect(LaunchdState(nil) == nil)
    }

    @Test func parsesStoppingDetail() {
        let d = Launchctl.parseDetail("""
        gui/501/com.x = {
        \tstate = SIGTERMed
        \tpid = 4242
        \truns = 2
        \tjob state = running
        \tlast exit reason = OS_REASON_EXEC
        \tpath = /Users/me/Library/LaunchAgents/com.x.plist
        }
        """)
        #expect(d.state == "SIGTERMed")
        #expect(d.pid == 4242)
        #expect(d.jobState == "running")
        #expect(d.lastExitReason == "OS_REASON_EXEC")
        #expect(d.path == "/Users/me/Library/LaunchAgents/com.x.plist")
    }

    @Test func statuses() {
        #expect(job(detail: detail(state: "SIGTERMed", pid: 7, runs: 1)).status == .stopping)
        #expect(job(["KeepAlive": true], detail: detail(state: "spawn scheduled", runs: 2, exit: -15)).status == .restarting)
        #expect(job(detail: detail(state: "spawn scheduled", runs: 2, exit: 0)).status != .restarting)
        for polite in [-15, -2, -1] {
            #expect(job(detail: detail(state: "not running", runs: 1, exit: polite)).status == .idle)
        }
        #expect(job(detail: detail(state: "not running", runs: 1, exit: -9)).status == .failed)
        #expect(job(detail: detail(state: "not running", runs: 1, exit: 78)).status == .failed)
        #expect(job(detail: detail(state: "who knows", pid: 9, runs: 1)).status == .running)
    }

    @Test func politeStopsDontMakeALoop() {
        // Being asked to stop 200 times isn't the job failing.
        let j = job(["KeepAlive": true], detail: detail(state: "spawn scheduled", runs: 200, exit: -15))
        #expect(!j.isRestartLooping)
        let failing = job(["KeepAlive": true], detail: detail(state: "spawn scheduled", runs: 3, exit: 1))
        #expect(failing.isRestartLooping)
        #expect(failing.status == .failed)
    }

    @Test func resultSummaries() {
        #expect(job(detail: detail(state: "not running", runs: 1, exit: -15)).resultSummary == "Stopped (SIGTERM)")
        #expect(job(detail: detail(state: "SIGTERMed", pid: 3, runs: 1)).resultSummary == "Stopping…")
        #expect(job(["KeepAlive": true], detail: detail(state: "spawn scheduled", runs: 2, exit: -15)).resultSummary == "Restarting soon")
        #expect(job(detail: detail(state: "running", pid: 3, runs: 2, exit: -15)).resultSummary == "Running")
        #expect(job(detail: detail(state: "running", pid: 3, runs: 2, exit: 1)).resultSummary == "Previous: Exit 1")
    }

    @Test func exitCodeKinds() {
        #expect(ExitCode.isPoliteStop(-15) && ExitCode.isPoliteStop(-2) && ExitCode.isPoliteStop(-1))
        #expect(!ExitCode.isPoliteStop(-9))
        #expect(ExitCode.isFailure(1) && ExitCode.isFailure(-9) && ExitCode.isFailure(78))
        #expect(!ExitCode.isFailure(0) && !ExitCode.isFailure(-15))
    }
}

// MARK: - Doctor rules

@Suite struct DoctorRules {
    @Test func signalExits() {
        let polite = Doctor.diagnose(job(detail: detail(state: "not running", runs: 1, exit: -15)))
        #expect(!polite.findings.contains { $0.id == "exit" })
        #expect(polite.checks.first { $0.id == "exit" }?.passed == true)
        #expect(findings(job(detail: detail(state: "not running", runs: 1, exit: -9)))["exit"] == .warning)
        #expect(findings(job(detail: detail(state: "not running", runs: 1, exit: -9, reason: "JETSAM_REASON_MEMORY_IDLE_EXIT")))["exit"] == nil)
        #expect(findings(job(detail: detail(state: "not running", runs: 1, exit: 1)))["exit"] == .warning)
        #expect(findings(job(detail: detail(state: "not running", runs: 1, exit: 127)))["exit"] == .error)
    }

    @Test func spawnFailures() {
        let spawn = job(detail: detail(state: "not running", runs: 1, exit: 78, jobState: "spawn failed"))
        #expect(Doctor.diagnose(spawn).findings.first { $0.id == "exit" }?.headline == "launchd can’t start it")
        let exec = job(detail: detail(state: "not running", runs: 1, exit: 1, reason: "OS_REASON_EXEC"))
        #expect(findings(exec)["exit"] == .error)
        // The program's own exit 78 is just a failed run.
        #expect(findings(job(detail: detail(state: "not running", runs: 1, exit: 78, jobState: "exited")))["exit"] == .warning)
    }

    @Test func placeholdersAndUnreadable() {
        let empty = Job(definition: JobDefinition(url: URL(fileURLWithPath: "/tmp/com.google.keystone.agent.plist"), scope: .user, raw: [:]),
                        listing: nil, detail: nil, override: nil)
        #expect(empty.status == .placeholder)
        let d = Doctor.diagnose(empty)
        #expect(d.findings.map(\.id) == ["placeholder"])
        #expect(d.primary?.fixes.contains(.trash) == true)
        #expect(!d.isProblem)

        let locked = Job(definition: JobDefinition(url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.nordvpn.helper.plist"),
                                                   scope: .system, raw: [:], unreadable: true),
                         listing: ServiceListing(label: "com.nordvpn.helper", pid: 99, lastExit: nil), detail: nil, override: nil)
        #expect(locked.status != .invalid && locked.status != .placeholder)
        #expect(findings(locked)["unreadable"] == .info)
        #expect(!Doctor.diagnose(locked).isProblem)
    }

    @Test func labels() {
        let blank = job(["Label": "  "])
        #expect(findings(blank)["label"] == .error)
        let number = job(["Label": 5])
        #expect(Doctor.diagnose(number).findings.first { $0.id == "label" }?.detail.contains("number") == true)
        let renamed = job(url: URL(fileURLWithPath: "/tmp/other-name.plist"))
        #expect(findings(renamed)["label"] == nil)
    }

    @Test func quarantinedPlist() throws {
        let s = try Scratch()
        let plist = try s.file("com.example.job.plist", "x")
        s.quarantine(plist, flags: "0083")
        let notLoaded = job(["StartInterval": 60], url: URL(fileURLWithPath: plist), loaded: false)
        let f = findings(notLoaded)
        #expect(f["plistquarantine"] == .error)
        #expect(f["loaded"] == nil)  // the quarantine is the reason; don't also say "load it"
        #expect(findings(job(url: URL(fileURLWithPath: plist), detail: detail(state: "running", pid: 1, runs: 1)))["plistquarantine"] == .warning)
    }

    @Test func programPaths() throws {
        let s = try Scratch()
        #expect(findings(job(["Program": "tool"]))["program"] == .error)
        #expect(findings(job(["ProgramArguments": ["~/bin/tool"]]))["program"] == .error)
        #expect(findings(job(["ProgramArguments": ["true"]]))["program"] == nil)  // /usr/bin/true
        #expect(findings(job(["ProgramArguments": ["python3-nonexistent-xyz"]]))["program"] == .error)
        #expect(findings(job(["ProgramArguments": [s.url.path]]))["program"] == .error)  // a folder
        let notExec = try s.file("tool.sh", "#!/bin/sh\n", mode: 0o644)
        #expect(findings(job(["ProgramArguments": [notExec]]))["program"] == .error)
        let badInterp = try s.file("a.sh", "#!/nonexistent/python3\nprint(1)\n", mode: 0o755)
        #expect(Doctor.diagnose(job(["ProgramArguments": [badInterp]])).findings.first { $0.id == "program" }?.headline == "Its Python interpreter is gone")
        let crlf = try s.file("b.sh", "#!/bin/sh\r\necho hi\r\n", mode: 0o755)
        #expect(Doctor.diagnose(job(["ProgramArguments": [crlf]])).findings.first { $0.id == "program" }?.headline == "Its script has Windows line endings")
        let env = try s.file("c.sh", "#!/usr/bin/env python3\n", mode: 0o755)
        #expect(findings(job(["ProgramArguments": [env]]))["program"] == nil)
        // Relative with a slash resolves against WorkingDirectory.
        try s.file("bin/run", "#!/bin/sh\n", mode: 0o755)
        #expect(findings(job(["ProgramArguments": ["bin/run"], "WorkingDirectory": s.url.path]))["program"] == nil)
    }

    @Test func programQuarantine() throws {
        let s = try Scratch()
        let approved = try s.binary("approved")
        s.quarantine(approved, flags: "00c1")
        #expect(findings(job(["ProgramArguments": [approved]]))["quarantine"] == nil)
        let unapproved = try s.binary("unapproved")
        s.quarantine(unapproved, flags: "0081")
        #expect(findings(job(["ProgramArguments": [unapproved]]))["quarantine"] == .error)
        let hard = try s.binary("hard")
        s.quarantine(hard, flags: "00c5")
        #expect(Doctor.diagnose(job(["ProgramArguments": [hard]])).findings.first { $0.id == "quarantine" }?.headline == "macOS blocks its program")
        let script = try s.file("script.sh", "#!/bin/sh\n", mode: 0o755)
        s.quarantine(script, flags: "0081")
        #expect(findings(job(["ProgramArguments": [script]]))["quarantine"] == nil)
    }

    @Test func tildesAndWorkingDirectories() throws {
        let s = try Scratch()
        #expect(findings(job(["WorkingDirectory": "~/work"]))["workdir"] == .error)
        #expect(findings(job(["WorkingDirectory": s.path("missing")]))["workdir"] == .error)
        #expect(findings(job(["WorkingDirectory": s.url.path]))["workdir"] == nil)
        #expect(findings(job(["StandardOutPath": "~/out.log"]))["tildepath"] == .error)
        #expect(findings(job(["StandardOutPath": "~/out.log", "WorkingDirectory": s.url.path]))["tildepath"] == .warning)
        #expect(findings(job(["ProgramArguments": ["/bin/echo", "~/x"]]))["tilde"] == .warning)
        #expect(findings(job(["ProgramArguments": ["/bin/sh", "-c", "ls ~/x"]]))["tilde"] == nil)
    }

    @Test func permissions() throws {
        let s = try Scratch()
        let world = try s.file("w.plist", "x", mode: 0o666)
        #expect(findings(job(url: URL(fileURLWithPath: world)))["perms"] == .error)
        let group = try s.file("g.plist", "x", mode: 0o664)  // group staff: fine for your own agents
        #expect(findings(job(url: URL(fileURLWithPath: group)))["perms"] == nil)
        #expect(!Doctor.diagnose(job(url: URL(fileURLWithPath: world))).findings.contains { $0.detail.contains("dubious") })
    }

    @Test func logs() throws {
        let s = try Scratch()
        // Running, log folder deleted underneath it: restart reopens it.
        let running = job(["StandardOutPath": s.path("gone/out.log")], detail: detail(state: "running", pid: 5, runs: 1))
        let d = Doctor.diagnose(running).findings.first { $0.id == "logdir" }
        #expect(d?.severity == .warning)
        #expect(d?.fixes == [.restart])
        // Not running: launchd creates missing folders, so that's fine…
        #expect(findings(job(["StandardOutPath": s.path("new/dir/out.log")], detail: detail(state: "not running", runs: 0)))["logdir"] == nil)
        // …unless a file sits where a folder must go.
        try s.file("blocker", "x")
        let blocked = job(["StandardOutPath": s.path("blocker/out.log")], detail: detail(state: "not running", runs: 0))
        #expect(findings(blocked)["logdir"] == .error)
        #expect(findings(job(["StandardOutPath": s.path("blocker/out.log")], loaded: false))["logdir"] == .warning)
    }

    @Test func triggersAndLoading() {
        #expect(findings(job(["WatchPaths": ["relative/dir"], "StartInterval": 60]))["watch"] == .warning)
        #expect(findings(job(["WatchPaths": ["relative/dir"]]))["watch"] == .error)
        #expect(findings(job(["StartInterval": 60], loaded: false))["loaded"] == .warning)
        #expect(findings(job(["StartInterval": 60, "LimitLoadToSessionType": "Background"], loaded: false))["loaded"] == nil)
        #expect(findings(job(["StartInterval": 60, "LimitLoadToSessionType": "aqua"], loaded: false))["loaded"] == .error)
        #expect(findings(job([:], detail: detail(state: "not running", runs: 0)))["trigger"] == .info)
        #expect(findings(job([:], detail: detail(state: "not running", runs: 3, exit: 0)))["trigger"] == nil)
        // LaunchEvents and OnDemand=false count as triggers.
        #expect(findings(job(["LaunchEvents": ["com.apple.iokit.matching": ["x": [:]]]], detail: detail(state: "not running", runs: 0)))["trigger"] == nil)
    }
}

// MARK: - launchctl with a fake runner

/// Replies to launchctl calls from a script and records what ran.
private final class FakeLaunchctl: @unchecked Sendable {
    var calls: [[String]] = []
    var replies: [(verb: String, result: ShellResult)] = []
    var printReplies: [ShellResult] = []
    var now = Date(timeIntervalSince1970: 0)

    func install() {
        Launchctl.runner = { [unowned self] argv, _ in
            calls.append(argv)
            let verb = argv.count > 1 ? argv[1] : ""
            if verb == "print" {
                if argv.count > 2, argv[2].split(separator: "/").count <= 2 { return ok("") }  // the domain listing
                return printReplies.isEmpty ? ShellResult(status: 113, stdout: "", stderr: "Could not find service") : printReplies.removeFirst()
            }
            if verb == "print-disabled" { return ok("") }
            if let i = replies.firstIndex(where: { $0.verb == verb }) { return replies.remove(at: i).result }
            return ok("")
        }
        Launchctl.sleeper = { [unowned self] t in now += t }
        Launchctl.clock = { [unowned self] in now }
    }

    func ok(_ out: String) -> ShellResult { ShellResult(status: 0, stdout: out, stderr: "") }
    func fail(_ status: Int32, _ err: String = "") -> ShellResult { ShellResult(status: status, stdout: "", stderr: err) }
    func printing(_ state: String, pid: Int? = nil) -> ShellResult {
        ok("x = {\n\tstate = \(state)\n" + (pid.map { "\tpid = \($0)\n" } ?? "") + "}")
    }
    func verbs() -> [String] { calls.map { $0.count > 1 ? $0[1] : "" }.filter { $0 != "print" && $0 != "print-disabled" } }

    static func reset() {
        Launchctl.runner = { argv, admin in
            admin ? Privileged.launchctl([argv]) : Shell.run(argv[0], Array(argv.dropFirst()), timeout: 60)
        }
        Launchctl.sleeper = { Thread.sleep(forTimeInterval: $0) }
        Launchctl.clock = { Date() }
    }
}

/// Every suite that swaps Launchctl's global runner lives in here, so they never run at the same time.
@Suite(.serialized) struct FakeRunnerSuites {}

extension FakeRunnerSuites {
@Suite struct LaunchctlOperations {
    @Test func stopPlansByKind() {
        let running = detail(state: "running", pid: 10, runs: 1)
        let plain = Launchctl.plan(for: .stop, job: job(detail: running))
        #expect(plain == [.run([Launchctl.path, "kill", "SIGTERM", "gui/\(getuid())/com.example.job"])])
        let variants: [Any] = [true, ["SuccessfulExit": false], ["SuccessfulExit": true], ["PathState": ["/tmp/x": true]]]
        for k in variants {
            let steps = Launchctl.plan(for: .stop, job: job(["KeepAlive": k], detail: running))
            #expect(steps.count == 2)
            #expect(steps.first == .run([Launchctl.path, "bootout", "gui/\(getuid())/com.example.job"]))
            #expect(steps.last?.rendered.contains("wait until launchctl print reports it gone, up to 25 s") == true)
        }
        #expect(Launchctl.plan(for: .stop, job: job(detail: detail(state: "not running", runs: 1))).isEmpty)
        #expect(Launchctl.commands(for: .stop, job: job(["KeepAlive": true], detail: running)).count == 1)
        // ExitTimeOut stretches the wait (clamped).
        #expect(Launchctl.bootoutWait(job(["ExitTimeOut": 0])) == 6)
        #expect(Launchctl.bootoutWait(job(["ExitTimeOut": 600])) == 60)
    }

    @Test func appleKeepAliveRefusesStop() {
        let apple = job(["KeepAlive": true], label: "com.apple.x", scope: .appleAgent, detail: detail(state: "running", pid: 3, runs: 1))
        #expect(apple.isAppleKeepAlive)
        #expect(throws: LDError.self) { try Launchctl.perform(.stop, on: apple) }
        let appleOneShot = job(label: "com.apple.y", scope: .appleAgent, detail: detail(state: "running", pid: 3, runs: 1))
        #expect(Launchctl.plan(for: .stop, job: appleOneShot).first == .run([Launchctl.path, "kill", "SIGTERM", appleOneShot.target]))
    }

    @Test func killExit3IsAlreadyStopped() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        fake.replies = [("kill", fake.fail(3, "No process to signal."))]
        #expect(try Launchctl.perform(.stop, on: job(detail: detail(state: "running", pid: 10, runs: 1))) == .alreadyStopped(notLoaded: false))
        fake.replies = [("kill", fake.fail(113))]
        #expect(try Launchctl.perform(.stop, on: job(detail: detail(state: "running", pid: 10, runs: 1))) == .alreadyStopped(notLoaded: true))
        #expect(try Launchctl.perform(.start, on: job(detail: detail(state: "running", pid: 10, runs: 1))) == .alreadyRunning(pid: 10))
    }

    @Test func waitUntilGone() {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        fake.printReplies = [fake.printing("SIGTERMed", pid: 4), fake.printing("SIGTERMed", pid: 4)]
        #expect(Launchctl.waitUntilGone(target: "gui/501/com.x", timeout: 10) == .gone)
        fake.printReplies = Array(repeating: fake.printing("SIGTERMed", pid: 4), count: 200)
        #expect(Launchctl.waitUntilGone(target: "gui/501/com.x", timeout: 5) == .timedOut(state: "SIGTERMed", pid: 4))
    }

    @Test func keepAliveStopUnloadsAndWaits() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        fake.printReplies = [fake.printing("SIGTERMed", pid: 4)]
        #expect(try Launchctl.perform(.stop, on: job(["KeepAlive": true], detail: detail(state: "running", pid: 4, runs: 1))) == .done)
        #expect(fake.verbs() == ["bootout"])
        fake.calls = []
        fake.printReplies = Array(repeating: fake.printing("SIGTERMed", pid: 4), count: 500)
        #expect(try Launchctl.perform(.stop, on: job(["KeepAlive": true], detail: detail(state: "running", pid: 4, runs: 1))) == .stillUnloading(pid: 4))
    }

    @Test func bootstrapRidesOutTheOldCopy() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        let j = job(["KeepAlive": true], loaded: false)

        // 5 while the old copy is still SIGTERMed → wait for it → succeed.
        fake.replies = [("bootstrap", fake.fail(5)), ("bootstrap", fake.ok(""))]
        // Not loaded before; SIGTERMed when the first try fails; gone after the wait.
        fake.printReplies = [fake.fail(113), fake.printing("SIGTERMed", pid: 3), fake.fail(113)]
        try Launchctl.bootstrapRetrying(j)
        #expect(fake.verbs() == ["bootstrap", "bootstrap"])

        // 5, absent, 5, then success.
        fake.calls = []
        fake.replies = [("bootstrap", fake.fail(5)), ("bootstrap", fake.fail(5)), ("bootstrap", fake.ok(""))]
        fake.printReplies = []
        try Launchctl.bootstrapRetrying(j)
        #expect(fake.verbs() == ["bootstrap", "bootstrap", "bootstrap"])

        // 37 and the job turns out loaded: success without retrying.
        fake.calls = []
        fake.replies = [("bootstrap", fake.fail(37))]
        fake.printReplies = [fake.fail(113), fake.printing("running", pid: 9)]
        try Launchctl.bootstrapRetrying(j)
        #expect(fake.verbs() == ["bootstrap"])

        // Four 5s: give up with launchd's code and a plain explanation.
        fake.calls = []
        fake.replies = Array(repeating: ("bootstrap", fake.fail(5, "Bootstrap failed: 5: Input/output error")), count: 4)
        fake.printReplies = []
        do {
            try Launchctl.bootstrapRetrying(j)
            Issue.record("expected a failure")
        } catch LDError.launchctl(let f) {
            #expect(f.status == 5)
            #expect(f.explanation.hasPrefix("launchd refused to load it"))
        }
    }

    @Test func bootstrapOfADisabledJob() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        Launchctl.runner = { [fake] argv, admin in
            if argv[1] == "print-disabled" { return fake.ok("\tdisabled services = {\n\t\t\"com.example.job\" => disabled\n\t}") }
            if argv[1] == "print" { return argv[2].split(separator: "/").count <= 2 ? fake.ok("") : fake.fail(113) }
            return fake.fail(5)
        }
        do {
            try Launchctl.bootstrapRetrying(job(loaded: false))
            Issue.record("expected a failure")
        } catch LDError.launchctl(let f) {
            #expect(f.status == 119)
            #expect(f.explanation.contains("is disabled"))
        }
    }

    @Test func stopObserver() {
        let before = job(detail: detail(state: "running", pid: 10, runs: 1))
        var t = Date(timeIntervalSince1970: 0)
        func run(_ seq: [ServiceDetail], timeout: TimeInterval = 60) -> StopOutcome {
            var queue = seq
            t = Date(timeIntervalSince1970: 0)
            return StopObserver.observe(before, started: Date(timeIntervalSince1970: 0), timeout: timeout,
                                        reload: { _ in job(detail: queue.count > 1 ? queue.removeFirst() : queue[0]) },
                                        sleeper: { t += $0 }, clock: { t })
        }
        if case .stopped(let pid, let exit, _) = run([detail(state: "running", pid: 10, runs: 1), detail(state: "not running", runs: 1, exit: -15)]) {
            #expect(pid == 10 && exit == -15)
        } else { Issue.record("expected stopped") }
        #expect(run([detail(state: "running", pid: 11, runs: 2)]) == .restarted(newPid: 11))
        #expect(run([detail(state: "running", pid: 10, runs: 1)], timeout: 5) == .stillRunning(pid: 10))
    }

    @Test func explanations() {
        let rows: [(String, Int32, String)] = [
            ("kill", 1, "administrator"), ("kill", 3, "no such process"), ("bootstrap", 5, "refused to load it"),
            ("kill", 5, "input/output"), ("bootout", 16, "busy"), ("bootout", 22, "invalid"), ("bootstrap", 37, "already doing"),
            ("kill", 113, "doesn’t have this job loaded"), ("bootstrap", 119, "is disabled"), ("bootstrap", 125, "can’t do that"),
            ("bootstrap", 134, "can’t do that"), ("kill", 150, "System Integrity Protection"), ("kill", -2, "didn’t return within 60 s"),
            ("kill", -1, "helper didn’t answer"), ("kill", 999, "rejected the request"),
        ]
        for (verb, status, expected) in rows {
            let text = Launchctl.explain(verb: verb, status: status, message: "")
            #expect(text.lowercased().contains(expected.lowercased()), "\(verb) \(status): \(text)")
            #expect(!text.contains("without a message"))
        }
        let silent = LaunchctlFailure(argv: [Launchctl.path, "kill", "SIGTERM", "gui/501/com.x"], status: 3, stderr: "", stdout: "")
        #expect(silent.message == "No such process")
        #expect(silent.details == "/bin/launchctl kill SIGTERM gui/501/com.x → exit 3: No such process")
        #expect(LDError.launchctl(silent).errorDescription?.contains("without a message") == false)
    }

    @Test func adminFailuresKeepTheRealCode() {
        let r = Shell.unwrapAdminFailure(ShellResult(status: 1, stdout: "",
                                                     stderr: "0:180: execution error: No process to signal. (3)\n"))
        #expect(r.status == 3)
        #expect(r.stderr == "No process to signal.")
        let other = ShellResult(status: 1, stdout: "", stderr: "something else")
        #expect(Shell.unwrapAdminFailure(other).status == 1)
    }

    @Test func dryRunShowsWaits() {
        let steps = Launchctl.plan(for: .disable, job: job(["KeepAlive": true], detail: detail(state: "running", pid: 1, runs: 1)))
        #expect(steps.map(\.rendered) == [
            "/bin/launchctl bootout gui/\(getuid())/com.example.job",
            "(then wait until launchctl print reports it gone, up to 25 s)",
            "/bin/launchctl disable gui/\(getuid())/com.example.job",
        ])
    }
}

// MARK: - Review fixes

@Suite struct ReviewFixes {
    @Test func idleKeepAliveStopIsANoOp() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        // A conditional KeepAlive that is satisfied: loaded, not running, nothing pending.
        let idle = job(["KeepAlive": ["SuccessfulExit": false], "StartInterval": 3600], detail: detail(state: "not running", runs: 1, exit: 0))
        #expect(!idle.stopUnloads)
        #expect(Launchctl.plan(for: .stop, job: idle).isEmpty)
        #expect(try Launchctl.perform(.stop, on: idle) == .alreadyStopped(notLoaded: false))
        #expect(fake.verbs().isEmpty)
        // Waiting out the throttle still counts: Stop cancels the pending restart.
        let pending = job(["KeepAlive": true], detail: detail(state: "spawn scheduled", runs: 2, exit: -15))
        #expect(pending.stopUnloads)
        #expect(Lifecycle.report(.unloaded(pid: nil, seconds: 0, wasRestarting: false), job: idle, wording: .app).summary
                == "Stopped · stays stopped until you click Start or log in again")
    }

    @Test func stopThatLaunchdWillUndoIsAWarning() {
        let before = job(detail: detail(state: "running", pid: 10, runs: 1))
        var t = Date(timeIntervalSince1970: 0)
        let outcome = StopObserver.observe(before, started: t, timeout: 5,
                                           reload: { _ in job(detail: detail(state: "spawn scheduled", runs: 1, exit: -15)) },
                                           sleeper: { t += $0 }, clock: { t })
        #expect(outcome == .willRestart)
        let r = Lifecycle.report(outcome, job: before, wording: .app)
        #expect(r.tone == .warning && r.offerKeepOff)
    }

    @Test func startWaitsForAQuittingCopy() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        // SIGTERMed twice, then gone (it was being unloaded): load it and kick it.
        fake.printReplies = [fake.printing("SIGTERMed", pid: 4), fake.printing("SIGTERMed", pid: 4), fake.fail(113), fake.fail(113)]
        let quitting = job(["KeepAlive": true], detail: detail(state: "SIGTERMed", pid: 4, runs: 1))
        #expect(try Launchctl.perform(.start, on: quitting) == .done)
        #expect(fake.verbs() == ["bootstrap", "kickstart"])
    }

    @Test func startEnablesALoadedDisabledJob() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        let j = job(detail: detail(state: "not running", runs: 1, exit: 0), disabled: true)
        #expect(Launchctl.plan(for: .start, job: j).map(\.rendered).first?.contains(" enable ") == true)
        _ = try Launchctl.perform(.start, on: j)
        #expect(fake.verbs() == ["enable", "kickstart"])
    }

    @Test func reloadOfADisabledJobLeavesItAlone() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        let j = job(detail: detail(state: "running", pid: 3, runs: 1), disabled: true)
        #expect(try Launchctl.reload(old: j, new: j) == .notReloadedDisabled)
        #expect(fake.verbs().isEmpty)
    }

    @Test func labelLoadedFromAnotherFile() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        fake.replies = [("bootstrap", fake.fail(37))]
        fake.printReplies = [fake.fail(113), fake.ok("x = {\n\tstate = running\n\tpid = 9\n\tpath = /Library/LaunchAgents/other.plist\n}")]
        do {
            try Launchctl.bootstrapRetrying(job(loaded: false))
            Issue.record("expected a failure")
        } catch LDError.launchctl(let f) {
            #expect(f.status == 17)
            #expect(f.explanation.contains("/Library/LaunchAgents/other.plist"))
        }
    }

    @Test func commandsAreRecorded() throws {
        let fake = FakeLaunchctl()
        fake.install()
        defer { FakeLaunchctl.reset() }
        let log = CommandLog()
        try CommandLog.$current.withValue(log) {
            _ = try Launchctl.perform(.stop, on: job(detail: detail(state: "running", pid: 10, runs: 1)))
        }
        #expect(log.commands == [[Launchctl.path, "kill", "SIGTERM", "gui/\(getuid())/com.example.job"]])
    }

    @Test func helperExplanations() {
        #expect(Launchctl.explain(verb: "kill", status: 64, message: "Only the system domain is allowed.")
                == "LD Manager’s helper refused: Only the system domain is allowed.")
        #expect(Launchctl.explain(verb: "kill", status: -1, message: "The helper didn’t answer.").hasPrefix("LD Manager’s helper didn’t answer"))
        #expect(Launchctl.explain(verb: "kill", status: -1, message: "couldn’t launch") == "couldn’t launch")
    }

    @Test func daemonWording() throws {
        let daemon = job(["KeepAlive": true], scope: .system, detail: detail(state: "running", pid: 10, runs: 1))
        #expect(Lifecycle.Wording.app.until(daemon) == "you click Start or restart the Mac")
        #expect(Lifecycle.Wording.cli(daemon).until(daemon) == "`ldm start job` or the next restart")
    }
}

}

// MARK: - Reports

@Suite struct ActionReports {
    @Test func stopWording() {
        let plain = job(detail: detail(state: "running", pid: 10, runs: 1))
        #expect(Lifecycle.report(.stopped(pid: 10, exit: -15, seconds: 1.2), job: plain, wording: .app).summary == "Stopped · PID 10 quit after 1.2 s")
        let scheduled = job(["StartInterval": 1800], detail: detail(state: "running", pid: 10, runs: 1))
        #expect(Lifecycle.report(.stopped(pid: 10, exit: -15, seconds: 1), job: scheduled, wording: .app).summary
                == "Stopped · PID 10 quit after 1.0 s · launchd starts it again: every 30 minutes")
        let keep = job(["KeepAlive": true], detail: detail(state: "running", pid: 10, runs: 1))
        let unloaded = Lifecycle.report(.unloaded(pid: 10, seconds: 4.1, wasRestarting: false), job: keep, wording: .app)
        #expect(unloaded.summary == "Stopped · PID 10 quit after 4.1 s · stays stopped until you click Start or log in again")
        #expect(unloaded.offerKeepOff && unloaded.result == "unloaded")
        #expect(Lifecycle.report(.unloaded(pid: nil, seconds: 0, wasRestarting: true), job: keep, wording: .cli(keep)).summary
                == "Stopped · cancelled launchd’s pending restart · stays stopped until `ldm start job` or the next login")
        let still = Lifecycle.report(.stillRunning(pid: 10), job: plain, wording: .app, timeout: 30)
        #expect(still.summary == "Still running as PID 10 after 30 s · it’s ignoring SIGTERM")
        #expect(still.timedOut && still.offerForceQuit && still.tone == .warning)
        #expect(Lifecycle.report(.restarted(newPid: 11), job: keep, wording: .app).tone == .warning)
        #expect(Lifecycle.report(.alreadyStopped(notLoaded: true), job: keep, wording: .app).summary == "Isn’t loaded · nothing to stop")
    }

    @Test func signalNames() throws {
        let notRunning = job(detail: detail(state: "not running", runs: 1))
        #expect(try Lifecycle.signal("HUP", job: notRunning).summary == "Not sent — it isn’t running")
        #expect(try Lifecycle.signalName("hup") == "SIGHUP")
        #expect(try Lifecycle.signalName("sigterm") == "SIGTERM")
        #expect(try Lifecycle.signalName("15") == "15")
        #expect(throws: LDError.self) { try Lifecycle.signal("SIGSTOP", job: notRunning) }
    }
}
