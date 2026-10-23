import Foundation

/// One changed top-level key.
public struct PlistChange: Identifiable, Sendable {
    public let key: String
    public let old: String?
    public let new: String?
    public var id: String { key }
}

/// Edits job plists without losing anything: changes are applied to the file's
/// own dictionary, so unknown keys survive, and every write is backed up first.
public enum PlistEditor {
    public static var backupRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LDManager/Backups")
    }

    /// Applies `updates` (nil removes a key) to the plist's current contents.
    public static func apply(_ updates: [String: Any?], to raw: [String: Any]) -> [String: Any] {
        var dict = raw
        for (key, value) in updates {
            if let v = value { dict[key] = v } else { dict.removeValue(forKey: key) }
        }
        return dict
    }

    public static func diff(_ old: [String: Any], _ new: [String: Any]) -> [PlistChange] {
        let keys = Set(old.keys).union(new.keys).sorted()
        return keys.compactMap { key in
            let a = old[key], b = new[key]
            if let a, let b, (a as AnyObject).isEqual(b) { return nil }
            if a == nil && b == nil { return nil }
            return PlistChange(key: key, old: a.map(render), new: b.map(render))
        }
    }

    /// Compact, readable value rendering for diffs and the Keys view.
    public static func render(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let a as [Any]: return "[" + a.map(render).joined(separator: ", ") + "]"
        case let d as [String: Any]: return "{" + d.keys.sorted().map { "\($0): \(render(d[$0]!))" }.joined(separator: ", ") + "}"
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let data as Data: return "<\(data.count) bytes>"
        default: return String(describing: value)
        }
    }

    public static func xml(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    /// Writes `dict` to the job's plist, backing up the current file first.
    /// Returns the backup's URL (nil for a new file).
    @discardableResult
    public static func write(_ dict: [String: Any], to url: URL, scope: JobScope) throws -> URL? {
        if scope.isReadOnly { throw LDError.readOnly(url.lastPathComponent) }
        guard PropertyListSerialization.propertyList(dict, isValidFor: .xml) else {
            throw LDError.invalid("The job contains values that can’t be stored in a plist.")
        }
        let data = try xml(dict)
        let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let backup = try backupIfPresent(url, label: label)

        if scope.fileNeedsAdmin {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ldm-\(UUID().uuidString).plist")
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = Shell.runAsAdmin([
                ["/bin/cp", tmp.path, url.path],
                ["/usr/sbin/chown", "root:wheel", url.path],
                ["/bin/chmod", "644", url.path],
            ])
            if !r.succeeded { throw r.status == 4 ? LDError.authorizationCancelled : LDError.io(r.message) }
        } else {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        return backup
    }

    static func backupIfPresent(_ url: URL, label: String) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let dir = backupRoot.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.backupStamp.string(from: Date())
        let dest = dir.appendingPathComponent("\(stamp).plist")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        // Remember where it came from, for Restore.
        try? url.path.write(to: dir.appendingPathComponent("origin.txt"), atomically: true, encoding: .utf8)
        return dest
    }

    public struct Backup: Identifiable, Sendable {
        public let label: String
        public let url: URL
        public let date: Date
        public let originalPath: String?
        public var id: String { url.path }
    }

    public static func backups() -> [Backup] {
        let fm = FileManager.default
        guard let labels = try? fm.contentsOfDirectory(atPath: backupRoot.path) else { return [] }
        var all: [Backup] = []
        for label in labels {
            let dir = backupRoot.appendingPathComponent(label)
            let origin = try? String(contentsOf: dir.appendingPathComponent("origin.txt"), encoding: .utf8)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".plist") {
                let stem = String(name.dropLast(6))
                guard let date = ISO8601DateFormatter.backupStamp.date(from: stem) else { continue }
                all.append(Backup(label: label, url: dir.appendingPathComponent(name), date: date, originalPath: origin))
            }
        }
        return all.sorted { $0.date > $1.date }
    }

    /// Moves a plist to the Trash (after backing it up). Unloads first if loaded.
    public static func trash(_ job: Job) throws {
        if job.scope.isReadOnly { throw LDError.readOnly(job.label) }
        if job.isLoaded { try Launchctl.perform(.unload, on: job) }
        _ = try backupIfPresent(job.definition.url, label: job.label)
        if job.scope.fileNeedsAdmin {
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(job.definition.url.lastPathComponent)")
            let r = Shell.runAsAdmin([["/bin/mv", job.definition.url.path, trash.path]])
            if !r.succeeded { throw LDError.io(r.message) }
        } else {
            try FileManager.default.trashItem(at: job.definition.url, resultingItemURL: nil)
        }
    }
}

extension ISO8601DateFormatter {
    static let backupStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        f.timeZone = .current
        return f
    }()
}
