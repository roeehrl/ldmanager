import Foundation

/// One record from macOS Background Task Management (BTM), the database behind
/// System Settings → General → Login Items & Extensions → Allow in the Background.
/// It is a second on/off layer, separate from launchd's own enable/disable override.
public struct BackgroundItem: Equatable, Sendable {
    public var name: String?
    public var developer: String?
    public var typeName: String = ""
    public var typeCode: Int = 0
    /// The record's raw disposition words, e.g. ["enabled", "allowed", "notified"].
    public var disposition: [String] = []
    public var identifier: String = ""
    public var url: String?
    public var executable: String?
    public var parent: String?
    public var teamIdentifier: String?
    public var associatedBundleIDs: [String] = []
    public var uid: Int = 0

    /// The switch in System Settings is on.
    public var isEnabled: Bool { disposition.contains("enabled") }
    /// Not blocked by policy (for example a management profile).
    public var isAllowed: Bool { !disposition.contains("disallowed") }
    /// Whether macOS lets launchd run it.
    public var isOn: Bool { isEnabled && isAllowed }

    /// BTM type bits for launchd jobs: agent 0x8, daemon 0x10 (legacy jobs add 0x10000).
    public var isLaunchJob: Bool { typeCode & 0x8 != 0 || typeCode & 0x10 != 0 }
    public var isDaemon: Bool { typeCode & 0x10 != 0 }

    /// The launchd label: the identifier without its numeric type prefix ("8.com.example.job").
    public var label: String {
        guard let dot = identifier.firstIndex(of: "."), Int(identifier[..<dot]) != nil else { return identifier }
        return String(identifier[identifier.index(after: dot)...])
    }

    /// "Off in Login Items", "Blocked by policy", "Allowed".
    public var summary: String {
        if !isAllowed { return "Blocked by policy" }
        return isEnabled ? "Allowed" : "Off in Login Items"
    }

    /// Who System Settings shows as the owner.
    public var owner: String? {
        if let d = developer, d != "(null)" { return d }
        if let p = parent, p != "Unknown Developer", !p.isEmpty { return p }
        return nil
    }
}

/// Reads BTM through `sfltool dumpbtm`. The command is undocumented and asks for an
/// administrator password every time it runs, so it only runs when the user asks
/// (`refresh()`); everything else reads the last result from a local cache.
/// The parser ignores fields it doesn't know.
public enum BackgroundItems {
    public struct Snapshot: Sendable {
        public let items: [BackgroundItem]
        public let date: Date

        /// Launch-job records keyed by "agent:<label>" / "daemon:<label>".
        public var byJob: [String: BackgroundItem] {
            var map: [String: BackgroundItem] = [:]
            let uid = Int(getuid())
            for item in items where item.isLaunchJob {
                let key = (item.isDaemon ? "daemon:" : "agent:") + item.label
                // Agents: prefer this user's record over other users'.
                if item.isDaemon || item.uid == uid || map[key] == nil { map[key] = item }
            }
            return map
        }

        public func item(for job: Job) -> BackgroundItem? {
            byJob[(job.scope.isDaemon ? "daemon:" : "agent:") + job.label]
        }
    }

    static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LDManager/background-items.txt")
    }

    /// The last snapshot read, without prompting. nil if never read.
    public static func cached() -> Snapshot? {
        guard let text = try? String(contentsOf: cacheURL, encoding: .utf8),
              let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        let items = parse(text)
        return items.isEmpty ? nil : Snapshot(items: items, date: date)
    }

    /// Runs `sfltool dumpbtm`, which shows macOS's administrator prompt, and caches
    /// the result. nil if the prompt was cancelled or the tool isn't available.
    public static func refresh() -> Snapshot? {
        let r = Shell.run("/usr/bin/sfltool", ["dumpbtm"])
        guard r.succeeded else { return nil }
        let items = parse(r.stdout)
        guard !items.isEmpty else { return nil }
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(r.stdout.utf8).write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        return Snapshot(items: items, date: Date())
    }

    public static func parse(_ text: String) -> [BackgroundItem] {
        var items: [BackgroundItem] = []
        var current: BackgroundItem?
        var uid = 0

        func flush() {
            if let c = current, !c.identifier.isEmpty { items.append(c) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") {
                flush()
                let rest = line.dropFirst("Records for UID ".count)
                uid = Int(rest.split(separator: " ").first ?? "") ?? 0
                continue
            }
            if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                flush()
                current = BackgroundItem(uid: uid)
                continue
            }
            guard current != nil, let colon = line.range(of: ": ") else { continue }
            let key = String(line[..<colon.lowerBound])
            let value = String(line[colon.upperBound...])
            switch key {
            case "Name": current!.name = value
            case "Developer Name": current!.developer = value
            case "Type":
                // "legacy agent (0x10008)"
                if let open = value.lastIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
                    current!.typeName = value[..<open].trimmingCharacters(in: .whitespaces)
                    let hex = value[value.index(after: open)..<close].replacingOccurrences(of: "0x", with: "")
                    current!.typeCode = Int(hex, radix: 16) ?? 0
                } else {
                    current!.typeName = value
                }
            case "Disposition":
                // "[enabled, allowed, notified] (0xb)"
                if let open = value.firstIndex(of: "["), let close = value.firstIndex(of: "]"), open < close {
                    current!.disposition = value[value.index(after: open)..<close]
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
            case "Identifier": current!.identifier = value
            case "URL": current!.url = value == "(null)" ? nil : value
            case "Executable Path": current!.executable = value == "(null)" ? nil : value
            case "Parent Identifier": current!.parent = value
            case "Team Identifier": current!.teamIdentifier = value == "(null)" ? nil : value
            case "Assoc. Bundle IDs":
                current!.associatedBundleIDs = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: break
            }
        }
        flush()
        return items
    }

    /// Opens System Settings → General → Login Items & Extensions.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}
