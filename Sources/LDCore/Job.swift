import Foundation

public enum JobStatus: String, Codable, Sendable, CaseIterable {
    case running, idle, failed, disabled, blocked, notLoaded, invalid

    public var title: String {
        switch self {
        case .running: "Running"
        case .idle: "Loaded, waiting"
        case .failed: "Last run failed"
        case .disabled: "Disabled"
        case .blocked: "Off in Login Items"
        case .notLoaded: "Not loaded"
        case .invalid: "Invalid plist"
        }
    }

    /// Sort order: things that need attention first.
    public var rank: Int {
        switch self {
        case .invalid: 0
        case .failed: 1
        case .blocked: 2
        case .disabled: 2
        case .notLoaded: 3
        case .running: 4
        case .idle: 5
        }
    }
}

/// A job as seen through every layer: the plist on disk, live launchd state,
/// launchd's persistent enable/disable override, and the Background Task
/// Management record behind "App Background Activity".
public struct Job: Identifiable, @unchecked Sendable {
    public let definition: JobDefinition
    public let listing: ServiceListing?
    public let detail: ServiceDetail?
    /// true = disabled override, false = explicitly enabled, nil = no override.
    public let override: Bool?
    /// nil when BTM wasn't read, or has no record of this job yet.
    public var background: BackgroundItem?

    public init(definition: JobDefinition, listing: ServiceListing?, detail: ServiceDetail?, override: Bool?,
                background: BackgroundItem? = nil) {
        self.definition = definition
        self.listing = listing
        self.detail = detail
        self.override = override
        self.background = background
    }

    /// Switched off in System Settings, or blocked by policy.
    public var isBlockedInBackground: Bool { background.map { !$0.isOn } ?? false }

    public var id: String { definition.url.path }
    public var label: String { definition.label }
    public var scope: JobScope { definition.scope }
    public var isLoaded: Bool { listing != nil }
    public var pid: Int? { detail?.pid ?? listing?.pid }
    public var runs: Int? { detail?.runs }
    public var lastExit: Int? { detail?.lastExitCode ?? listing?.lastExit }

    /// Disabled either by launchd's override or, without one, by the plist's Disabled key.
    public var isDisabled: Bool {
        if let o = override { return o }
        return definition.disabledKey ?? false
    }

    public var status: JobStatus {
        if definition.parseError != nil || definition.declaredLabel == nil { return .invalid }
        if isDisabled && !isLoaded { return .disabled }
        if isBlockedInBackground && pid == nil { return .blocked }
        if pid != nil { return .running }
        if !isLoaded { return .notLoaded }
        if let e = lastExit, e != 0 { return .failed }
        return .idle
    }

    /// Display name: the last meaningful component of the label.
    public var title: String { Job.title(for: label) }

    static let genericWords: Set<String> = ["agent", "agents", "helper", "daemon", "service", "xpcservice", "update", "updater",
                                            "wake", "app", "console", "policy", "session", "server", "worker", "menu", "launcher"]

    public static func title(for label: String) -> String {
        let tlds: Set<String> = ["com", "org", "net", "io", "dev", "app", "co", "me", "local", "application"]
        var parts = label.split(separator: ".").map(String.init)
        if let first = parts.first, tlds.contains(first.lowercased()), parts.count > 1 { parts.removeFirst() }
        // Drop trailing hash-like components (long hex strings).
        while parts.count > 1, let last = parts.last, last.count >= 12, last.allSatisfy(\.isHexDigit) { parts.removeLast() }
        // Generic last words get the component before them: "keystone.agent" → "Keystone agent".
        var picked: [String] = []
        for p in parts.reversed() {
            picked.insert(p, at: 0)
            if !genericWords.contains(p.lowercased()) || picked.count == 3 { break }
        }
        if picked.count > 1 && picked.count == parts.count && parts.count > 2 { picked.removeFirst() }
        let text = picked.joined(separator: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The shortest name `ldm` resolves to this job: its last label component,
    /// unless that is generic or a hash.
    public var shortName: String {
        let last = label.split(separator: ".").last.map(String.init) ?? label
        if Job.genericWords.contains(last.lowercased()) || (last.count >= 12 && last.allSatisfy(\.isHexDigit)) { return label }
        return last
    }

    /// Vendor group derived from the label: com.acme.foo → acme, homebrew.mxcl.x → homebrew.
    public var group: String {
        let parts = label.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return label }
        let tlds: Set<String> = ["com", "org", "net", "io", "dev", "app", "co", "me", "de", "uk", "us", "local", "application"]
        return tlds.contains(parts[0].lowercased()) ? parts[1] : parts[0]
    }

    /// One-line result shown in tables.
    public var resultSummary: String {
        switch status {
        case .invalid:
            return definition.parseError != nil ? "Invalid plist" : "Invalid · no Label key"
        case .disabled: return "Disabled"
        case .blocked: return background?.summary ?? "Off in Login Items"
        case .notLoaded: return "Not loaded"
        default: break
        }
        guard let e = lastExit else { return status == .running ? "Running" : "Not run yet" }
        if e == 0 { return "OK" }
        let what = ExitCode.short(e)
        if status == .running { return "Previous: \(what)" }
        if let r = runs, r > 50, definition.keepAlive != nil, definition.keepAlive != .never {
            return "\(what) · \(r.formatted()) restarts"
        }
        return what
    }

    public var target: String { "\(scope.domain)/\(label)" }
}
