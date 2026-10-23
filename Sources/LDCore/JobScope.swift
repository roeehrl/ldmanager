import Foundation

/// Where a job's plist lives, which decides the launchd domain it loads into
/// and what it takes to change it.
public enum JobScope: String, CaseIterable, Codable, Sendable, Identifiable {
    case user
    case allUsers
    case system
    case appleAgent
    case appleDaemon

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .user: "My Agents"
        case .allUsers: "All Users’ Agents"
        case .system: "System Daemons"
        case .appleAgent: "Apple Agents"
        case .appleDaemon: "Apple Daemons"
        }
    }

    /// Short kind shown on a job ("User agent").
    public var kind: String {
        switch self {
        case .user: "User agent"
        case .allUsers: "Agent for all users"
        case .system: "System daemon"
        case .appleAgent: "Apple agent"
        case .appleDaemon: "Apple daemon"
        }
    }

    public var directory: URL {
        switch self {
        case .user: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        case .allUsers: URL(fileURLWithPath: "/Library/LaunchAgents")
        case .system: URL(fileURLWithPath: "/Library/LaunchDaemons")
        case .appleAgent: URL(fileURLWithPath: "/System/Library/LaunchAgents")
        case .appleDaemon: URL(fileURLWithPath: "/System/Library/LaunchDaemons")
        }
    }

    public var isApple: Bool { self == .appleAgent || self == .appleDaemon }

    /// Apple jobs live on the sealed system volume and cannot be modified.
    public var isReadOnly: Bool { isApple }

    public var isDaemon: Bool { self == .system || self == .appleDaemon }

    /// launchd domain the job is loaded into for the current user.
    public var domain: String {
        isDaemon ? "system" : "gui/\(getuid())"
    }

    /// launchctl verbs on this domain need root.
    public var launchctlNeedsAdmin: Bool { isDaemon && getuid() != 0 }

    /// Writing the plist file needs root.
    public var fileNeedsAdmin: Bool { self != .user && getuid() != 0 }

    public static var editable: [JobScope] { [.user, .allUsers, .system] }
}
