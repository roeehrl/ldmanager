import Foundation

/// What a job's plist on disk says. Holds the raw dictionary so nothing is lost;
/// the typed accessors are read-only views over it.
public struct JobDefinition: @unchecked Sendable {
    public let url: URL
    public let scope: JobScope
    public let raw: [String: Any]
    /// Set when the file could not be read as a property list dictionary.
    public let parseError: String?
    /// LD Manager can't read the file (it's root-only); launchd, running as root, can.
    public let unreadable: Bool
    /// Foundation can't parse it but launchd can (launchd is more lenient in places),
    /// so the contents are unknown here although the job may load fine.
    public let lenientOnly: Bool

    public init(url: URL, scope: JobScope, raw: [String: Any], parseError: String? = nil,
                unreadable: Bool = false, lenientOnly: Bool = false) {
        self.url = url
        self.scope = scope
        self.raw = raw
        self.parseError = parseError
        self.unreadable = unreadable
        self.lenientOnly = lenientOnly
    }

    public static func load(url: URL, scope: JobScope) -> JobDefinition {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let ns = error as NSError
            let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if ns.code == NSFileReadNoPermissionError || posix == Int(EACCES) {
                return JobDefinition(url: url, scope: scope, raw: [:], unreadable: true)
            }
            return JobDefinition(url: url, scope: scope, raw: [:], parseError: ns.localizedDescription)
        }
        let launchd = LaunchdPlistParser.launchdAccepts(data)
        do {
            let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dict = obj as? [String: Any] else {
                return JobDefinition(url: url, scope: scope, raw: [:], parseError: "The file is a property list but not a dictionary.")
            }
            if launchd == false {
                // Foundation reads it, launchd doesn't (OpenStep format, <true></true>, bad base64…).
                return JobDefinition(url: url, scope: scope, raw: dict,
                                     parseError: "launchd can’t parse this file, although other tools can read it (an old OpenStep format, an element like <true></true>, or invalid <data>).")
            }
            return JobDefinition(url: url, scope: scope, raw: dict)
        } catch {
            if launchd == true { return JobDefinition(url: url, scope: scope, raw: [:], lenientOnly: true) }
            let ns = error as NSError
            let detail = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
            return JobDefinition(url: url, scope: scope, raw: [:], parseError: detail)
        }
    }

    /// The plist's contents can't be checked here (see `unreadable`, `lenientOnly`).
    public var contentsUnknown: Bool { unreadable || lenientOnly }

    /// An empty plist (or one with no Label and no program), like the {} files
    /// Google leaves behind: launchd ignores it; nothing is meant to run.
    public var isEmptyPlaceholder: Bool {
        guard parseError == nil, !contentsUnknown else { return false }
        if raw.isEmpty { return true }
        return raw["Label"] == nil && raw["Program"] == nil && raw["ProgramArguments"] == nil && raw["BundleProgram"] == nil
    }

    /// The label launchd knows this job by, for matching it to launchd's listing.
    /// A readable plist without a Label isn't matched by file name: launchd never does that.
    /// A broken plist may still be loaded from an earlier, valid copy, so it falls back to
    /// the file name (by convention the label).
    public var lookupLabel: String? { declaredLabel ?? (contentsUnknown || parseError != nil ? fileStem : nil) }

    public var fileStem: String { url.deletingPathExtension().lastPathComponent }

    /// The Label, if it is usable: a non-blank string (launchd keeps surrounding spaces).
    public var declaredLabel: String? {
        guard let l = raw["Label"] as? String, !l.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return l
    }
    /// Label, falling back to the file name for plists that lack one.
    public var label: String { declaredLabel ?? fileStem }

    public var programArguments: [String] { (raw["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? [] }
    public var programKey: String? { raw["Program"] as? String }
    public var bundleProgram: String? { raw["BundleProgram"] as? String }

    /// The executable launchd will run. A non-text first argument isn't skipped over.
    public var program: String? { programKey ?? ((raw["ProgramArguments"] as? [Any])?.first as? String) }

    /// The full command line as launchd runs it.
    public var commandLine: [String] {
        if let p = programKey {
            // With Program set, ProgramArguments[0] is argv[0], not the executable.
            return [p] + programArguments.dropFirst()
        }
        return programArguments
    }

    public var runAtLoad: Bool { Self.strictBool(raw["RunAtLoad"]) ?? false }
    /// A whole number of seconds above 0; launchd ignores anything else.
    public var startInterval: Int? { Self.strictInt(raw["StartInterval"]).flatMap { $0 > 0 ? $0 : nil } }
    public var calendarIntervals: [[String: Int]] {
        func conv(_ d: [String: Any]) -> [String: Int] {
            d.compactMapValues { ($0 as? NSNumber)?.intValue }
        }
        if let one = raw["StartCalendarInterval"] as? [String: Any] { return [conv(one)] }
        if let many = raw["StartCalendarInterval"] as? [[String: Any]] { return many.map(conv) }
        return []
    }
    public var keepAlive: KeepAlive? { KeepAlive(raw["KeepAlive"]) }
    public var watchPaths: [String] { raw["WatchPaths"] as? [String] ?? [] }
    public var queueDirectories: [String] { raw["QueueDirectories"] as? [String] ?? [] }
    public var startOnMount: Bool { Self.strictBool(raw["StartOnMount"]) ?? false }
    public var hasSocketsOrMachServices: Bool { raw["Sockets"] != nil || raw["MachServices"] != nil }
    public var standardOutPath: String? { raw["StandardOutPath"] as? String }
    public var standardErrorPath: String? { raw["StandardErrorPath"] as? String }
    public var workingDirectory: String? { raw["WorkingDirectory"] as? String }
    public var userName: String? { raw["UserName"] as? String }
    public var disabledKey: Bool? { Self.strictBool(raw["Disabled"]) }
    /// Seconds launchd waits after SIGTERM before SIGKILL (launchd's default is 20).
    public var exitTimeOut: Int { (raw["ExitTimeOut"] as? NSNumber)?.intValue ?? 20 }
    /// Minimum seconds between launches (launchd's default is 10).
    public var throttleInterval: Int { (raw["ThrottleInterval"] as? NSNumber)?.intValue ?? 10 }
    public var environment: [String: String] { raw["EnvironmentVariables"] as? [String: String] ?? [:] }

    public var schedule: Schedule { Schedule(definition: self) }

    /// KeepAlive makes launchd start the job by itself, not only restart it once
    /// something else has started it (AfterInitialDemand, Crashed=true alone).
    public var keepAliveStartsIt: Bool {
        let value = raw["KeepAlive"]
        if let b = Self.strictBool(value) { return b }
        guard let d = value as? [String: Any], Self.strictBool(d["AfterInitialDemand"]) != true else { return false }
        return Self.strictBool(d["SuccessfulExit"]) != nil || Self.strictBool(d["Crashed"]) == false
            || ["PathState", "OtherJobEnabled", "OtherJobActive"].contains { (d[$0] as? [String: Any])?.isEmpty == false }
    }

    /// A real plist boolean. launchd ignores <integer>1</integer> where it wants <true/>,
    /// although Foundation would bridge it to true.
    static func strictBool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// A real plist integer: not a boolean, not a <real>.
    static func strictInt(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        return n.intValue
    }
}

public enum KeepAlive: Equatable, Sendable {
    case always
    case never
    case onFailure      // SuccessfulExit = false
    case onSuccess      // SuccessfulExit = true
    case conditional([String])

    /// Only the keys launchd acts on count: NetworkState is ignored, wrong-typed values
    /// are ignored, and a dict left with nothing (or only AfterInitialDemand) does nothing.
    init?(_ value: Any?) {
        if let b = JobDefinition.strictBool(value) { self = b ? .always : .never; return }
        guard let d = value as? [String: Any] else { return nil }
        var keys = ["SuccessfulExit", "Crashed"].filter { JobDefinition.strictBool(d[$0]) != nil }
        keys += ["PathState", "OtherJobEnabled", "OtherJobActive"].filter { (d[$0] as? [String: Any])?.isEmpty == false }
        guard !keys.isEmpty else { self = .never; return }
        if JobDefinition.strictBool(d["AfterInitialDemand"]) == true { keys.append("AfterInitialDemand") }
        if keys == ["SuccessfulExit"], let s = JobDefinition.strictBool(d["SuccessfulExit"]) {
            self = s ? .onSuccess : .onFailure
            return
        }
        self = .conditional(keys.sorted())
    }
}
