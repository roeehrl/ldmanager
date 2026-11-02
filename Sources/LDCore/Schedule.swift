import Foundation

/// A job's triggers, in words people read.
public struct Schedule: Sendable {
    public let startInterval: Int?
    public let calendar: [[String: Int]]
    public let keepAlive: KeepAlive?
    public let runAtLoad: Bool
    public let watchPaths: [String]
    public let queueDirectories: [String]
    public let startOnMount: Bool
    public let onDemandServices: Bool
    /// KeepAlive starts it by itself (see `JobDefinition.keepAliveStartsIt`).
    public let keepAliveStarts: Bool
    public let isDaemon: Bool
    /// The plist couldn't be read here (root-only, or only launchd can parse it).
    public let unknown: Bool

    public init(definition d: JobDefinition) {
        unknown = d.contentsUnknown
        startInterval = d.startInterval
        calendar = d.calendarIntervals
        keepAlive = d.keepAlive
        runAtLoad = d.runAtLoad
        // launchd ignores entries that don't start with / or ~.
        let watchable = { (p: String) in p.hasPrefix("/") || p.hasPrefix("~") }
        watchPaths = d.watchPaths.filter(watchable)
        queueDirectories = d.queueDirectories.filter(watchable)
        startOnMount = d.startOnMount
        keepAliveStarts = d.keepAliveStartsIt
        // Sockets, Mach services and launch events (XPC events) start it on demand;
        // the legacy OnDemand=false means "keep alive".
        let events = (d.raw["LaunchEvents"] as? [String: Any])?.values.contains { ($0 as? [String: Any])?.isEmpty == false } ?? false
        onDemandServices = d.hasSocketsOrMachServices || events || JobDefinition.strictBool(d.raw["OnDemand"]) == false
        isDaemon = d.scope.isDaemon
    }

    public var hasTrigger: Bool {
        startInterval != nil || !calendar.isEmpty || runAtLoad || !watchPaths.isEmpty
            || !queueDirectories.isEmpty || startOnMount || onDemandServices
            || keepAliveStarts
    }

    /// "Every 30 minutes · at login"
    public var summary: String {
        if unknown { return "Unknown" }
        var parts: [String] = []
        switch keepAlive {
        case .always: parts.append("Always running")
        case .onFailure: parts.append("Restarts when it fails")
        case .onSuccess: parts.append("Restarts after it succeeds")
        case .conditional(let keys):
            let words = keys.filter { $0 != "AfterInitialDemand" }.map(Self.keepAliveWords).joined(separator: ", ")
            parts.append("Kept alive when " + words + (keys.contains("AfterInitialDemand") ? " after it’s first started" : ""))
        case .never, .none: break
        }
        if let s = startInterval { parts.append(Self.describe(interval: s)) }
        parts.append(contentsOf: calendar.map(Self.describe(calendar:)))
        if !watchPaths.isEmpty {
            parts.append(watchPaths.count == 1 ? "When \((watchPaths[0] as NSString).lastPathComponent) changes" : "When \(watchPaths.count) paths change")
        }
        if !queueDirectories.isEmpty { parts.append("When files arrive in \((queueDirectories[0] as NSString).lastPathComponent)") }
        if startOnMount { parts.append("When a volume mounts") }
        // KeepAlive implies starting at load; don't repeat it.
        if runAtLoad && !keepAliveStarts {
            parts.append(isDaemon ? "at boot" : "at login")
        }
        if parts.isEmpty { return onDemandServices ? "When another process asks for it" : "On demand" }
        var text = parts.joined(separator: " · ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text
    }

    static func keepAliveWords(_ key: String) -> String {
        switch key {
        case "NetworkState": "the network is up"
        case "PathState": "a path exists"
        case "OtherJobEnabled", "OtherJobActive": "another job is running"
        case "Crashed": "it crashed"
        case "SuccessfulExit": "on exit"
        case "AfterInitialDemand": "first started"
        default: key
        }
    }

    /// The summary for use mid-sentence: "every 30 minutes", but "Mondays at 09:30".
    public var summaryInSentence: String {
        let text = summary
        let properNouns = Self.weekdayNames + Self.monthNames.filter { !$0.isEmpty }
        if properNouns.contains(where: { text.hasPrefix($0) }) { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    public static func describe(interval s: Int) -> String {
        func unit(_ n: Int, _ one: String) -> String { n == 1 ? "Every \(one)" : "Every \(n) \(one)s" }
        if s % 86400 == 0 { return unit(s / 86400, "day") }
        if s % 3600 == 0 { return unit(s / 3600, "hour") }
        if s % 60 == 0 { return unit(s / 60, "minute") }
        return unit(s, "second")
    }

    static let weekdayNames = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
    static let monthNames = ["", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    public static func describe(calendar c: [String: Int]) -> String {
        let minute = c["Minute"], hour = c["Hour"], day = c["Day"], weekday = c["Weekday"], month = c["Month"]
        let time: String
        switch (hour, minute) {
        case let (h?, m?): time = String(format: "at %02d:%02d", h, m)
        case let (h?, nil): time = String(format: "every minute of %02d:00–%02d:59", h, h)
        case let (nil, m?): time = String(format: "every hour at :%02d", m)
        case (nil, nil): time = "every minute"
        }
        var when: String
        let monthName = month.flatMap { (1...12).contains($0) ? monthNames[$0] : nil }
        if let w = weekday, (0...7).contains(w) {
            // With Day as well, launchd runs on either one (like cron).
            when = weekdayNames[w]
            if let d = day { when += monthName.map { " and day \(d) in \($0)" } ?? " and on day \(d) of each month" }
            else if let mo = monthName { when += " in \(mo)" }
        } else if let d = day {
            when = "On day \(d)"
            if let mo = monthName { when += " of \(mo)" } else { when += " of each month" }
        } else if let mo = month, (1...12).contains(mo) {
            when = "Every day in \(monthNames[mo])"
        } else {
            when = hour != nil ? "Daily" : ""
        }
        return when.isEmpty ? time.prefix(1).uppercased() + time.dropFirst() : "\(when) \(time)"
    }

    /// The next few calendar-triggered run times after `date`. Day 31 only matches
    /// months that have one, and Day with Weekday matches either (as launchd does).
    public func nextRuns(after date: Date = Date(), count: Int = 4) -> [Date] {
        let patterns = calendar.flatMap(Self.datePatterns)
        guard !patterns.isEmpty else { return [] }
        let cal = Calendar.current
        var results: [Date] = []
        var cursor = date
        for _ in 0..<count {
            var best: Date?
            for comps in patterns {
                guard let next = cal.nextDate(after: cursor, matching: comps, matchingPolicy: .strict),
                      comps.day == nil || cal.component(.day, from: next) == comps.day else { continue }
                if best == nil || next < best! { best = next }
            }
            guard let b = best else { break }
            results.append(b)
            cursor = b.addingTimeInterval(1)
        }
        return results
    }

    /// One calendar entry as Calendar search patterns: two when it has both Day and
    /// Weekday, none when a value is out of range.
    static func datePatterns(_ c: [String: Int]) -> [DateComponents] {
        let ranges: [String: ClosedRange<Int>] = ["Minute": 0...59, "Hour": 0...23, "Day": 1...31, "Weekday": 0...7, "Month": 1...12]
        guard ranges.allSatisfy({ key, range in c[key].map(range.contains) ?? true }) else { return [] }
        var base = DateComponents()
        base.minute = c["Minute"]
        base.hour = c["Hour"]
        base.month = c["Month"]
        if base.minute == nil { base.second = 0 }
        var byDay = base, byWeekday = base
        byDay.day = c["Day"]
        byWeekday.weekday = c["Weekday"].map { ($0 % 7) + 1 }  // launchd 0=Sun, Calendar 1=Sun
        switch (c["Day"], c["Weekday"]) {
        case (_?, _?): return [byDay, byWeekday]
        case (_?, nil): return [byDay]
        case (nil, _?): return [byWeekday]
        case (nil, nil): return [base]
        }
    }
}
