import Foundation

/// What a job's plist on disk says. Holds the raw dictionary so nothing is lost;
/// the typed accessors are read-only views over it.
public struct JobDefinition: @unchecked Sendable {
    public let url: URL
    public let scope: JobScope
    public let raw: [String: Any]
    /// Set when the file could not be read as a property list dictionary.
    public let parseError: String?

    public init(url: URL, scope: JobScope, raw: [String: Any], parseError: String? = nil) {
        self.url = url
        self.scope = scope
        self.raw = raw
        self.parseError = parseError
    }

    public static func load(url: URL, scope: JobScope) -> JobDefinition {
        do {
            let data = try Data(contentsOf: url)
            let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dict = obj as? [String: Any] else {
                return JobDefinition(url: url, scope: scope, raw: [:], parseError: "The file is a property list but not a dictionary.")
            }
            return JobDefinition(url: url, scope: scope, raw: dict)
        } catch {
            let ns = error as NSError
            let detail = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
            return JobDefinition(url: url, scope: scope, raw: [:], parseError: detail)
        }
    }

    public var fileStem: String { url.deletingPathExtension().lastPathComponent }

    public var declaredLabel: String? { raw["Label"] as? String }
    /// Label, falling back to the file name for plists that lack one.
    public var label: String { declaredLabel ?? fileStem }

    public var programArguments: [String] { (raw["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? [] }
    public var programKey: String? { raw["Program"] as? String }
    public var bundleProgram: String? { raw["BundleProgram"] as? String }

    /// The executable launchd will run.
    public var program: String? { programKey ?? programArguments.first }

    /// The full command line as launchd runs it.
    public var commandLine: [String] {
        if let p = programKey {
            // With Program set, ProgramArguments[0] is argv[0], not the executable.
            return [p] + programArguments.dropFirst()
        }
        return programArguments
    }

    public var runAtLoad: Bool { raw["RunAtLoad"] as? Bool ?? false }
    public var startInterval: Int? { (raw["StartInterval"] as? NSNumber)?.intValue }
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
    public var startOnMount: Bool { raw["StartOnMount"] as? Bool ?? false }
    public var hasSocketsOrMachServices: Bool { raw["Sockets"] != nil || raw["MachServices"] != nil }
    public var standardOutPath: String? { raw["StandardOutPath"] as? String }
    public var standardErrorPath: String? { raw["StandardErrorPath"] as? String }
    public var workingDirectory: String? { raw["WorkingDirectory"] as? String }
    public var userName: String? { raw["UserName"] as? String }
    public var disabledKey: Bool? { raw["Disabled"] as? Bool }
    public var environment: [String: String] { raw["EnvironmentVariables"] as? [String: String] ?? [:] }

    public var schedule: Schedule { Schedule(definition: self) }
}

public enum KeepAlive: Equatable, Sendable {
    case always
    case never
    case onFailure      // SuccessfulExit = false
    case onSuccess      // SuccessfulExit = true
    case conditional([String])

    init?(_ value: Any?) {
        if let b = value as? Bool { self = b ? .always : .never; return }
        guard let d = value as? [String: Any] else { return nil }
        if d.count == 1, let s = d["SuccessfulExit"] as? Bool {
            self = s ? .onSuccess : .onFailure
            return
        }
        self = .conditional(d.keys.sorted())
    }
}
