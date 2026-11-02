import Foundation

/// A problem the user chose to stop seeing. It covers one finding of one job;
/// if that job develops a different problem (another finding, or the same check
/// with a different headline), the new one shows again.
public struct Dismissal: Codable, Hashable, Sendable {
    public let label: String
    public let findingID: String
    public let headline: String
    public let dismissedAt: Date
    /// The plist's modification date when it was dismissed (nil in older files).
    public let plistModified: Date?

    public init(label: String, findingID: String, headline: String, dismissedAt: Date = Date(), plistModified: Date? = nil) {
        self.label = label
        self.findingID = findingID
        self.headline = headline
        self.dismissedAt = dismissedAt
        self.plistModified = plistModified
    }

    func covers(_ finding: Finding, of job: Job) -> Bool {
        label == job.label && findingID == finding.id && headline == finding.headline
    }
}

/// Dismissed problems, shared by the app and ldm in one small JSON file.
public enum Dismissals {
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LDManager/dismissed.json")
    }

    public static func load(from url: URL = fileURL) -> [Dismissal] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Dismissal].self, from: data)) ?? []
    }

    public static func save(_ dismissals: [Dismissal], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(dismissals.sorted { ($0.label, $0.findingID) < ($1.label, $1.findingID) }).write(to: url, options: .atomic)
    }

    /// Dismisses every reportable finding of a diagnosis.
    public static func dismiss(_ diagnosis: Diagnosis, at url: URL = fileURL) throws {
        var all = load(from: url)
        let modified = modificationDate(diagnosis.job)
        for f in diagnosis.findings where f.severity >= .warning {
            all.removeAll { $0.label == diagnosis.job.label && $0.findingID == f.id }
            all.append(Dismissal(label: diagnosis.job.label, findingID: f.id, headline: f.headline, plistModified: modified))
        }
        try save(all, to: url)
    }

    /// Restores (un-dismisses) every dismissed problem of a job.
    public static func restore(label: String, at url: URL = fileURL) throws {
        try save(load(from: url).filter { $0.label != label }, to: url)
    }

    /// Drops dismissals whose problem no longer shows in `diagnoses`. Without the job
    /// list it can't tell a fixed problem from one that is absent only for now (the
    /// job happens to be running), so prefer `prune(current:jobs:)`.
    public static func prune(current diagnoses: [Diagnosis], at url: URL = fileURL) {
        let all = load(from: url)
        let kept = all.filter { d in
            diagnoses.contains { diag in diag.findings.contains { d.covers($0, of: diag.job) } }
        }
        if kept.count != all.count { try? save(kept, to: url) }
    }

    /// Findings that come and go with launchd's state (a run, a load, a Login Items
    /// switch), so their absence at one refresh doesn't mean they are fixed.
    static let runtimeFindings: Set<String> = ["exit", "loop", "logdir", "loaded", "background", "otherfile"]

    /// Drops dismissals whose problem is really gone, so a problem that is fixed and
    /// later comes back is shown again. `diagnoses` are the current problems, `jobs`
    /// every job. A dismissal is dropped when its job no longer exists, or when its
    /// finding is gone and the job isn't running or about to restart, and, for a
    /// runtime finding, the plist has changed since or the last run succeeded.
    public static func prune(current diagnoses: [Diagnosis], jobs: [Job], at url: URL = fileURL) {
        let all = load(from: url)
        let kept = all.filter { d in
            if diagnoses.contains(where: { diag in diag.findings.contains { d.covers($0, of: diag.job) } }) { return true }
            let mine = jobs.filter { $0.label == d.label }
            guard !mine.isEmpty else { return false }
            if mine.contains(where: { $0.pid != nil || $0.launchdState == .spawnScheduled }) { return true }
            guard runtimeFindings.contains(d.findingID) else { return false }
            let succeeded = mine.contains { $0.lastExit == 0 }
            let edited = d.plistModified.map { then in
                mine.contains { job in modificationDate(job).map { Int($0.timeIntervalSince1970) != Int(then.timeIntervalSince1970) } ?? true }
            } ?? false
            return !succeeded && !edited
        }
        if kept.count != all.count { try? save(kept, to: url) }
    }

    static func modificationDate(_ job: Job) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: job.definition.url.path))?[.modificationDate] as? Date
    }
}

extension Diagnosis {
    /// Reportable findings (warning or error) the user hasn't dismissed.
    public func activeFindings(_ dismissals: [Dismissal]) -> [Finding] {
        findings.filter { f in f.severity >= .warning && !dismissals.contains { $0.covers(f, of: job) } }
    }

    /// The dismissal date if every reportable finding is dismissed.
    public func dismissedAt(_ dismissals: [Dismissal]) -> Date? {
        let reportable = findings.filter { $0.severity >= .warning }
        guard !reportable.isEmpty else { return nil }
        let matches = reportable.compactMap { f in dismissals.first { $0.covers(f, of: job) } }
        return matches.count == reportable.count ? matches.map(\.dismissedAt).max() : nil
    }
}

extension Doctor {
    /// Problems split into those that need attention and those the user dismissed.
    public static func triage(_ jobs: [Job], dismissals: [Dismissal]) -> (active: [Diagnosis], dismissed: [Diagnosis]) {
        let all = problems(in: jobs)
        let dismissed = all.filter { $0.dismissedAt(dismissals) != nil }
        let active = all.filter { $0.dismissedAt(dismissals) == nil }
        return (active, dismissed)
    }
}
