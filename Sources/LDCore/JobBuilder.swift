import Foundation

/// The trigger choices offered by the editor and `ldm new`.
public enum Trigger: Equatable, Sendable {
    case atLoad
    case every(seconds: Int)
    case calendar([[String: Int]])
    case keepAlive(onlyOnFailure: Bool)
    case watch([String])
    case onDemand

    public init(definition d: JobDefinition) {
        if let k = d.keepAlive, k != .never { self = .keepAlive(onlyOnFailure: k == .onFailure); return }
        if let s = d.startInterval { self = .every(seconds: s); return }
        if !d.calendarIntervals.isEmpty { self = .calendar(d.calendarIntervals); return }
        if !d.watchPaths.isEmpty { self = .watch(d.watchPaths); return }
        if d.runAtLoad { self = .atLoad; return }
        self = .onDemand
    }

    /// Keys this trigger owns; the editor clears them before applying a new trigger.
    public static let keys = ["RunAtLoad", "StartInterval", "StartCalendarInterval", "KeepAlive", "WatchPaths"]

    public func updates(runAtLoad: Bool) -> [String: Any?] {
        var u: [String: Any?] = Dictionary(uniqueKeysWithValues: Trigger.keys.map { ($0, nil as Any?) })
        switch self {
        case .atLoad: u["RunAtLoad"] = true
        case .every(let s): u["StartInterval"] = s
        case .calendar(let c): u["StartCalendarInterval"] = c.count == 1 ? c[0] as Any : c as Any
        case .keepAlive(let f):
            u["KeepAlive"] = f ? ["SuccessfulExit": false] as Any : true as Any
            u["RunAtLoad"] = true
        case .watch(let p): u["WatchPaths"] = p
        case .onDemand: break
        }
        if runAtLoad, u["RunAtLoad"] == nil || u["RunAtLoad"]! == nil { u["RunAtLoad"] = true }
        return u
    }

    /// Parses "30s", "15m", "6h", "1d" into seconds.
    public static func parseDuration(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = t.last else { return nil }
        let mult: Int
        switch unit {
        case "s": mult = 1
        case "m": mult = 60
        case "h": mult = 3600
        case "d": mult = 86400
        default: return Int(t)
        }
        return Int(t.dropLast()).map { $0 * mult }
    }

    /// Parses a 5-field cron line ("30 9 * * 1") into calendar intervals.
    /// Supports numbers, `*` and comma lists; ranges and steps are rejected.
    public static func parseCron(_ text: String) throws -> [[String: Int]] {
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count == 5 else { throw LDError.invalid("A cron line has 5 fields: minute hour day month weekday.") }
        let names = ["Minute", "Hour", "Day", "Month", "Weekday"]
        var options: [[(String, Int)?]] = []
        for (i, f) in fields.enumerated() {
            if f == "*" { options.append([nil]); continue }
            let values = try f.split(separator: ",").map { part -> (String, Int)? in
                guard let n = Int(part) else { throw LDError.invalid("Unsupported cron field “\(f)”: use numbers, * or comma lists.") }
                return (names[i], n)
            }
            options.append(values)
        }
        var result: [[String: Int]] = [[:]]
        for opts in options {
            result = result.flatMap { base in
                opts.map { o in
                    var d = base
                    if let (k, v) = o { d[k] = v }
                    return d
                }
            }
        }
        return result
    }
}

public enum JobBuilder {
    /// A new job's plist contents.
    public static func make(label: String, program: [String], trigger: Trigger, runAtLoad: Bool = false,
                            standardOutPath: String? = nil, standardErrorPath: String? = nil,
                            workingDirectory: String? = nil) -> [String: Any] {
        var dict: [String: Any] = ["Label": label, "ProgramArguments": program]
        dict = PlistEditor.apply(trigger.updates(runAtLoad: runAtLoad), to: dict)
        if let o = standardOutPath { dict["StandardOutPath"] = o }
        if let e = standardErrorPath ?? standardOutPath { dict["StandardErrorPath"] = e }
        if let w = workingDirectory { dict["WorkingDirectory"] = w }
        return dict
    }

    /// Expands a leading ~ the way a shell would, since launchd won't.
    public static func expandTilde(_ s: String) -> String {
        s.hasPrefix("~") ? (s as NSString).expandingTildeInPath : s
    }

    public static func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || "-_.@".contains($0) } && !label.hasPrefix(".")
    }
}

/// Reads the end of a log file without loading all of it.
public enum LogReader {
    public static func tail(_ path: String, lines: Int = 40, maxBytes: Int = 64 * 1024) -> [String]? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        var all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if start > 0, !all.isEmpty { all.removeFirst() }  // partial first line
        while all.last == "" { all.removeLast() }
        return Array(all.suffix(lines))
    }

    public static func logPaths(for job: Job) -> [String] {
        var paths: [String] = []
        for p in [job.definition.standardOutPath, job.definition.standardErrorPath].compactMap({ $0 }) where p != "/dev/null" && !paths.contains(p) {
            paths.append(p)
        }
        return paths
    }
}
