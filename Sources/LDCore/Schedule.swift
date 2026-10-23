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
    public let isDaemon: Bool

    public init(definition d: JobDefinition) {
        startInterval = d.startInterval
        calendar = d.calendarIntervals
        keepAlive = d.keepAlive
        runAtLoad = d.runAtLoad
        watchPaths = d.watchPaths
        queueDirectories = d.queueDirectories
        startOnMount = d.startOnMount
        onDemandServices = d.hasSocketsOrMachServices
        isDaemon = d.scope.isDaemon
    }

    public var hasTrigger: Bool {
        startInterval != nil || !calendar.isEmpty || runAtLoad || !watchPaths.isEmpty
            || !queueDirectories.isEmpty || startOnMount || onDemandServices
            || (keepAlive != nil && keepAlive != .never)
    }

    /// "Every 30 minutes · at login"
    public var summary: String {
        var parts: [String] = []
        switch keepAlive {
        case .always: parts.append("Always running")
        case .onFailure: parts.append("Restarts when it fails")
        case .onSuccess: parts.append("Restarts after it succeeds")
        case .conditional(let keys): parts.append("Kept alive when " + keys.map(Self.keepAliveWords).joined(separator: ", "))
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
        if runAtLoad && (keepAlive == nil || keepAlive == .never) {
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
        if let w = weekday, (0...7).contains(w) {
            when = weekdayNames[w]
        } else if let d = day {
            when = "On day \(d)"
            if let mo = month, (1...12).contains(mo) { when += " of \(monthNames[mo])" } else { when += " of each month" }
        } else if let mo = month, (1...12).contains(mo) {
            when = "Every day in \(monthNames[mo])"
        } else {
            when = hour != nil ? "Daily" : ""
        }
        return when.isEmpty ? time.prefix(1).uppercased() + time.dropFirst() : "\(when) \(time)"
    }

    /// The next few calendar-triggered run times after `date`.
    public func nextRuns(after date: Date = Date(), count: Int = 4) -> [Date] {
        guard !calendar.isEmpty else { return [] }
        let cal = Calendar.current
        var results: [Date] = []
        var cursor = date
        for _ in 0..<count {
            var best: Date?
            for c in calendar {
                var comps = DateComponents()
                comps.minute = c["Minute"]
                comps.hour = c["Hour"]
                comps.day = c["Day"]
                comps.month = c["Month"]
                if let w = c["Weekday"] { comps.weekday = (w % 7) + 1 }  // launchd 0=Sun, Calendar 1=Sun
                if comps.minute == nil { comps.second = 0 }
                if let next = cal.nextDate(after: cursor, matching: comps, matchingPolicy: .nextTime) {
                    if best == nil || next < best! { best = next }
                }
            }
            guard let b = best else { break }
            results.append(b)
            cursor = b.addingTimeInterval(1)
        }
        return results
    }
}
