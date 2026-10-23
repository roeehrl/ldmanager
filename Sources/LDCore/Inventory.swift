import Foundation

/// Scans the job folders and joins each plist with launchd's live state.
public enum Inventory {
    public struct Options: Sendable {
        public var scopes: [JobScope]
        /// Run `launchctl print` per job for runs/last-exit detail. Skipped for
        /// Apple jobs unless asked, since there are hundreds of them.
        public var details: Bool

        public init(scopes: [JobScope] = [.user, .allUsers, .system], details: Bool = true) {
            self.scopes = scopes
            self.details = details
        }

        public static let all = Options(scopes: JobScope.allCases)
    }

    public static func plistURLs(in scope: JobScope) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: scope.directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".plist") }.sorted().map { scope.directory.appendingPathComponent($0) }
    }

    public static func load(_ options: Options = Options()) -> [Job] {
        // Each domain is listed once, then joined per job.
        let domains = Set(options.scopes.map(\.domain))
        var services: [String: [String: ServiceListing]] = [:]
        var overrides: [String: [String: Bool]] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: domains.count * 2) { i in
            let domain = Array(domains)[i / 2]
            if i % 2 == 0 {
                let s = Launchctl.services(in: domain)
                lock.lock(); services[domain] = s; lock.unlock()
            } else {
                let o = Launchctl.disabledOverrides(in: domain)
                lock.lock(); overrides[domain] = o; lock.unlock()
            }
        }

        let defs = options.scopes.flatMap { scope in plistURLs(in: scope).map { JobDefinition.load(url: $0, scope: scope) } }
        var jobs = [Job?](repeating: nil, count: defs.count)
        DispatchQueue.concurrentPerform(iterations: defs.count) { i in
            let def = defs[i]
            let domain = def.scope.domain
            let listing = services[domain]?[def.label]
            var detail: ServiceDetail?
            if listing != nil, options.details, !def.scope.isApple {
                detail = Launchctl.detail(target: "\(domain)/\(def.label)")
            }
            let job = Job(definition: def, listing: listing, detail: detail, override: overrides[domain]?[def.label])
            lock.lock(); jobs[i] = job; lock.unlock()
        }
        return jobs.compactMap { $0 }
    }

    /// Reloads one job, with full detail.
    public static func reload(_ job: Job) -> Job {
        let def = JobDefinition.load(url: job.definition.url, scope: job.scope)
        let domain = job.scope.domain
        let listing = Launchctl.services(in: domain)[def.label]
        let detail = listing != nil ? Launchctl.detail(target: "\(domain)/\(def.label)") : nil
        return Job(definition: def, listing: listing, detail: detail, override: Launchctl.disabledOverrides(in: domain)[def.label])
    }

    /// Finds jobs by exact label, label suffix, file name, or substring.
    public static func resolve(_ query: String, in jobs: [Job]) throws -> Job {
        let q = query.lowercased()
        let tiers: [(Job) -> Bool] = [
            { $0.label.lowercased() == q },
            { $0.definition.fileStem.lowercased() == q || $0.definition.url.path == query },
            { $0.label.lowercased().hasSuffix("." + q) },
            { $0.label.lowercased().contains(q) },
        ]
        for match in tiers {
            let found = jobs.filter(match)
            if found.count == 1 { return found[0] }
            if found.count > 1 {
                // Prefer non-Apple jobs when a user job is among the matches.
                let mine = found.filter { !$0.scope.isApple }
                if mine.count == 1 { return mine[0] }
                throw LDError.ambiguous(query, found.map(\.label).sorted())
            }
        }
        throw LDError.notFound(query)
    }
}
