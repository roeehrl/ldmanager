import Foundation
import LDCore

/// Exit codes documented in `ldm --help`.
enum Exit {
    static let general: Int32 = 1
    static let usage: Int32 = 2
    static let notFound: Int32 = 3
    static let authorization: Int32 = 4
    static let launchd: Int32 = 5
    static let problems: Int32 = 6
    static let timedOut: Int32 = 7

    static func code(for error: Error) -> Int32 {
        switch error as? LDError {
        case .notFound: notFound
        case .ambiguous, .invalid: usage
        case .authorizationCancelled, .readOnly: authorization
        case .launchd: launchd
        case .launchctl(let f) where f.status == Shell.timedOutStatus: timedOut
        case .launchctl(let f) where f.status == 1 || f.status == 150: authorization
        case .launchctl: launchd
        default: general
        }
    }
}

struct Style {
    static var enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["NO_COLOR"] != nil || env["TERM"] == "dumb" { return false }
        return isatty(STDOUT_FILENO) != 0
    }()

    static func wrap(_ s: String, _ code: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func orange(_ s: String) -> String { wrap(s, "33") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func purple(_ s: String) -> String { wrap(s, "35") }

    static func status(_ s: JobStatus) -> String {
        switch s {
        case .running: green("● running ")
        case .stopping: dim("◍ stopping")
        case .restarting: green("↻ restart ")
        case .idle: dim("○ idle    ")
        case .failed: orange("▲ failed  ")
        case .disabled: dim("‖ disabled")
        case .blocked: orange("⊘ blocked ")
        case .notLoaded: dim("◌ unloaded")
        case .invalid: purple("◆ invalid ")
        case .placeholder: dim("· empty   ")
        }
    }
}

/// One self-overwriting dim progress line on stderr while waiting, only on a terminal.
final class Progress: @unchecked Sendable {
    /// The line on screen now, so an error can clear it before printing.
    nonisolated(unsafe) static var current: Progress?
    let label: String
    let enabled: Bool
    private var shown = false

    init(label: String, enabled: Bool) {
        self.label = label
        self.enabled = enabled && isatty(STDERR_FILENO) != 0
        Progress.current = self
    }

    func show(_ text: String) {
        guard enabled else { return }
        shown = true
        FileHandle.standardError.write(Data(("\r\u{1B}[2K" + Style.dim("\(label): \(text)")).utf8))
    }

    func clear() {
        guard shown else { return }
        shown = false
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }
}

struct ActionJSON: Encodable {
    let action: String
    let label: String
    let result: String
    let tone: String
    let summary: String
    let short: String
    let timedOut: Bool
    let offerForceQuit: Bool
    let offerKeepOff: Bool
    let pidBefore: Int?
    let pid: Int?
    let lastExit: Int?
    let seconds: Double
    let commands: [[String]]
    let job: JobJSON

    init(action: String, label: String, report: ActionReport, before: Job, commands: [[String]], seconds: Double, after: Job) {
        self.action = action
        self.label = label
        result = report.result
        tone = report.tone.rawValue
        summary = report.summary
        short = report.short
        timedOut = report.timedOut
        offerForceQuit = report.offerForceQuit
        offerKeepOff = report.offerKeepOff
        pidBefore = before.pid
        pid = after.pid
        lastExit = after.lastExit
        self.seconds = (seconds * 10).rounded() / 10
        self.commands = commands
        job = JobJSON(after)
    }

    // Keep null values, so scripts can rely on every key being present.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(label, forKey: .label)
        try c.encode(result, forKey: .result)
        try c.encode(tone, forKey: .tone)
        try c.encode(summary, forKey: .summary)
        try c.encode(short, forKey: .short)
        try c.encode(timedOut, forKey: .timedOut)
        try c.encode(offerForceQuit, forKey: .offerForceQuit)
        try c.encode(offerKeepOff, forKey: .offerKeepOff)
        try c.encode(pidBefore, forKey: .pidBefore)
        try c.encode(pid, forKey: .pid)
        try c.encode(lastExit, forKey: .lastExit)
        try c.encode(seconds, forKey: .seconds)
        try c.encode(commands, forKey: .commands)
        try c.encode(job, forKey: .job)
    }

    enum CodingKeys: String, CodingKey {
        case action, label, result, tone, summary, short, timedOut, offerForceQuit, offerKeepOff, pidBefore, pid, lastExit, seconds, commands, job
    }
}

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n - 1)) + "…" : s + String(repeating: " ", count: n - s.count)
}

/// Stable machine-readable form of a job (`--json`).
struct JobJSON: Encodable {
    struct State: Encodable {
        let status: String
        let loaded: Bool
        let running: Bool
        let pid: Int?
        let runs: Int?
        let lastExit: Int?
        let override: String
        /// "allowed", "off", "blocked by policy", or "unknown" when not read.
        let background: String
    }
    let label: String
    let title: String
    let scope: String
    let domain: String
    let plist: String
    let program: [String]
    let schedule: String
    let result: String
    let state: State

    init(_ j: Job) {
        label = j.label
        title = j.title
        scope = j.scope.rawValue
        domain = j.scope.domain
        plist = j.definition.url.path
        program = j.definition.commandLine
        schedule = j.definition.schedule.summary
        result = j.resultSummary
        state = State(status: j.status.rawValue, loaded: j.isLoaded, running: j.pid != nil, pid: j.pid, runs: j.runs,
                      lastExit: j.lastExit, override: j.override.map { $0 ? "disabled" : "enabled" } ?? "none",
                      background: j.background.map { !$0.isAllowed ? "blocked by policy" : $0.isEnabled ? "allowed" : "off" } ?? "unknown")
    }
}

struct DiagnosisJSON: Encodable {
    struct F: Encodable { let severity: String; let headline: String; let detail: String; let fixes: [String] }
    struct C: Encodable { let name: String; let passed: Bool?; let note: String? }
    let label: String
    let dismissedAt: Date?
    let findings: [F]
    let checks: [C]

    init(_ d: Diagnosis, dismissals: [Dismissal] = []) {
        label = d.job.label
        dismissedAt = d.dismissedAt(dismissals)
        findings = d.findings.map { F(severity: "\($0.severity)", headline: $0.headline, detail: $0.detail, fixes: $0.fixes.map(\.title)) }
        checks = d.checks.map { C(name: $0.name, passed: $0.passed, note: $0.note) }
    }
}

func emitJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
}
