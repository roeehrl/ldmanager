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

    static func code(for error: Error) -> Int32 {
        switch error as? LDError {
        case .notFound: notFound
        case .ambiguous, .invalid: usage
        case .authorizationCancelled, .readOnly: authorization
        case .launchd: launchd
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
        case .idle: dim("○ idle    ")
        case .failed: orange("▲ failed  ")
        case .disabled: dim("‖ disabled")
        case .notLoaded: dim("◌ unloaded")
        case .invalid: purple("◆ invalid ")
        }
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
                      lastExit: j.lastExit, override: j.override.map { $0 ? "disabled" : "enabled" } ?? "none")
    }
}

struct DiagnosisJSON: Encodable {
    struct F: Encodable { let severity: String; let headline: String; let detail: String; let fixes: [String] }
    struct C: Encodable { let name: String; let passed: Bool?; let note: String? }
    let label: String
    let findings: [F]
    let checks: [C]

    init(_ d: Diagnosis) {
        label = d.job.label
        findings = d.findings.map { F(severity: "\($0.severity)", headline: $0.headline, detail: $0.detail, fixes: $0.fixes.map(\.title)) }
        checks = d.checks.map { C(name: $0.name, passed: $0.passed, note: $0.note) }
    }
}

func emitJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
}
