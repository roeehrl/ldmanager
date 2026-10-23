import Foundation
import Security

/// The privileged helper's XPC interface. Every method takes data, never a
/// command line: the helper decides what runs, and `HelperPolicy` validates
/// each request before it does anything.
@objc public protocol LDHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// launchctl verbs on the system domain only. Replies (status, stdout, stderr).
    func launchctl(_ arguments: [String], reply: @escaping (Int32, String, String) -> Void)
    /// Writes a job plist into /Library/LaunchDaemons or /Library/LaunchAgents as root:wheel 0644.
    func installPlist(_ data: Data, at path: String, reply: @escaping (String?) -> Void)
    /// Moves a job plist from those folders to the calling user's Trash.
    func trashPlist(at path: String, reply: @escaping (String?) -> Void)
    func fixPlistPermissions(at path: String, reply: @escaping (String?) -> Void)
    func createDirectory(at path: String, reply: @escaping (String?) -> Void)
    func removeQuarantine(at path: String, reply: @escaping (String?) -> Void)
    /// `sfltool dumpbtm` output. Replies (output, error).
    func dumpBackgroundItems(reply: @escaping (String?, String?) -> Void)
    /// Points /usr/local/bin/ldm at the ldm bundled in an LD Manager app.
    func linkCommandLineTool(_ bundledPath: String, reply: @escaping (String?) -> Void)
}

/// What the helper agrees to do. Kept here, outside the helper, so it is unit-tested.
public enum HelperPolicy {
    public static let machService = "io.github.roeehrl.ldmanager.helper"
    public static let appIdentifier = "io.github.roeehrl.ldmanager"
    public static let cliIdentifier = "io.github.roeehrl.ldmanager.ldm"
    public static let version = "1"

    public static let jobDirectories = ["/Library/LaunchDaemons", "/Library/LaunchAgents"]
    /// Where the helper may create folders (for job logs).
    public static let directoryPrefixes = ["/Library/", "/usr/local/", "/opt/", "/private/var/log/", "/var/log/", "/Users/Shared/"]
    static let signals: Set<String> = ["SIGTERM", "SIGKILL", "SIGINT", "SIGHUP", "SIGQUIT", "SIGUSR1", "SIGUSR2", "15", "9", "2", "1"]

    /// Only LD Manager and its bundled ldm, signed by the helper's own team.
    public static func clientRequirement(team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (identifier \"\(appIdentifier)\" or identifier \"\(cliIdentifier)\")"
    }

    public static func helperRequirement(team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(machService)\""
    }

    /// nil if the path is a .plist directly inside one of the job folders.
    public static func validateJobPath(_ path: String, daemonsOnly: Bool = false) -> String? {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.hasPrefix("/"), std == path, !path.contains("/../"), !path.contains("/./") else { return "Path must be absolute and normalized." }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let allowed = daemonsOnly ? ["/Library/LaunchDaemons"] : jobDirectories
        guard allowed.contains(dir) else { return "Only \(allowed.joined(separator: " and ")) are allowed." }
        guard name.hasSuffix(".plist"), !name.hasPrefix("."), name.count > 6 else { return "Not a job plist name." }
        return nil
    }

    public static let cliLinkPath = "/usr/local/bin/ldm"

    /// nil if `path` looks like the ldm inside an app bundle. The helper also checks its signature.
    public static func validateBundledCLI(_ path: String) -> String? {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.hasPrefix("/"), std == path, path.hasSuffix(".app/Contents/Helpers/ldm") else {
            return "Only the ldm inside an LD Manager app can be linked."
        }
        return nil
    }

    /// Code requirement the bundled ldm must satisfy before it is linked.
    public static func cliRequirement(team: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(cliIdentifier)\""
    }

    public static func validateTarget(_ target: String) -> String? {
        guard target.hasPrefix("system/") else { return "Only the system domain is allowed." }
        let label = String(target.dropFirst("system/".count))
        return JobBuilder.isValidLabel(label) ? nil : "Invalid label."
    }

    /// nil if the arguments (without the launchctl path) are an allowed request.
    public static func validateLaunchctl(_ args: [String]) -> String? {
        guard let verb = args.first else { return "No verb." }
        switch verb {
        case "bootstrap":
            guard args.count == 3, args[1] == "system" else { return "Usage: bootstrap system <plist>." }
            return validateJobPath(args[2], daemonsOnly: true)
        case "bootout", "enable", "disable":
            guard args.count == 2 else { return "Usage: \(verb) system/<label>." }
            return validateTarget(args[1])
        case "kickstart":
            if args.count == 2 { return validateTarget(args[1]) }
            guard args.count == 3, args[1] == "-k" else { return "Usage: kickstart [-k] system/<label>." }
            return validateTarget(args[2])
        case "kill":
            guard args.count == 3, signals.contains(args[1]) else { return "Usage: kill <signal> system/<label>." }
            return validateTarget(args[2])
        default:
            return "launchctl \(verb) isn’t allowed."
        }
    }

    public static func validateDirectory(_ path: String) -> String? {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.hasPrefix("/"), std == (path.hasSuffix("/") ? String(path.dropLast()) : path) else { return "Path must be absolute and normalized." }
        guard directoryPrefixes.contains(where: { std.hasPrefix($0) }) else { return "Folders can only be created under \(directoryPrefixes.joined(separator: ", "))." }
        return nil
    }

    /// The team identifier this process is signed with, or nil (ad-hoc / unsigned).
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Talks to the helper over XPC. Calls are synchronous with a timeout so the
/// shared core (also used by the CLI) can stay synchronous.
public final class HelperClient: @unchecked Sendable {
    public static let shared = HelperClient()

    private let lock = NSLock()
    private var probed: Bool?

    /// True when the helper is installed, approved and accepts us. Probed once
    /// per process; call `resetProbe()` after installing or approving it.
    public var isAvailable: Bool {
        lock.lock()
        if let p = probed { lock.unlock(); return p }
        lock.unlock()
        let ok = call(timeout: 3, fallback: nil as String?) { proxy, done in proxy.version { done($0) } } != nil
        lock.lock(); probed = ok; lock.unlock()
        return ok
    }

    public func resetProbe() {
        lock.lock(); probed = nil; lock.unlock()
    }

    /// Calls the helper and waits for the reply. Returns `fallback` if the helper
    /// can't be reached, rejects us, or doesn't answer in time.
    public func call<T>(timeout: TimeInterval = 120, fallback: T,
                        _ body: (LDHelperProtocol, @escaping (T) -> Void) -> Void) -> T {
        let connection = NSXPCConnection(machServiceName: HelperPolicy.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LDHelperProtocol.self)
        // Make sure we are talking to our own helper, when we have a team to check against.
        if let team = HelperPolicy.currentTeamIdentifier() {
            connection.setCodeSigningRequirement(HelperPolicy.helperRequirement(team: team))
        }
        connection.resume()
        defer { connection.invalidate() }

        let done = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result = fallback
        var finished = false
        func finish(_ value: T?) {
            resultLock.lock()
            if !finished {
                finished = true
                if let value { result = value }
                done.signal()
            }
            resultLock.unlock()
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(nil) }
        guard let helper = proxy as? LDHelperProtocol else { return fallback }
        body(helper) { finish($0) }
        _ = done.wait(timeout: .now() + timeout)
        resultLock.lock(); defer { resultLock.unlock() }
        return result
    }
}

/// Root-level operations. Each goes through the helper when it is available,
/// otherwise through macOS's administrator prompt (one prompt per call).
public enum Privileged {
    public static var usesHelper: Bool { HelperClient.shared.isAvailable }

    /// Runs launchctl invocations (`["/bin/launchctl", verb, …]`) as root.
    public static func launchctl(_ commands: [[String]]) -> ShellResult {
        guard usesHelper else { return Shell.runAsAdmin(commands) }
        var last = ShellResult(status: 0, stdout: "", stderr: "")
        for argv in commands {
            let args = Array(argv.dropFirst())
            last = HelperClient.shared.call(fallback: ShellResult(status: -1, stdout: "", stderr: "The helper didn’t answer.")) { proxy, done in
                proxy.launchctl(args) { status, out, err in done(ShellResult(status: status, stdout: out, stderr: err)) }
            }
            if !last.succeeded { break }
        }
        return last
    }

    public static func installPlist(_ data: Data, at path: String) throws {
        if usesHelper {
            try helperCall { proxy, done in proxy.installPlist(data, at: path, reply: done) }
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ldm-\(UUID().uuidString).plist")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try admin([["/bin/cp", tmp.path, path], ["/usr/sbin/chown", "root:wheel", path], ["/bin/chmod", "644", path]])
    }

    public static func trash(_ path: String) throws {
        if usesHelper {
            try helperCall { proxy, done in proxy.trashPlist(at: path, reply: done) }
            return
        }
        let dest = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\((path as NSString).lastPathComponent)").path
        try admin([["/bin/mv", path, dest]])
    }

    public static func fixPlistPermissions(_ path: String) throws {
        if usesHelper {
            try helperCall { proxy, done in proxy.fixPlistPermissions(at: path, reply: done) }
            return
        }
        try admin([["/usr/sbin/chown", "root:wheel", path], ["/bin/chmod", "644", path]])
    }

    public static func createDirectory(_ path: String) throws {
        if usesHelper {
            try helperCall { proxy, done in proxy.createDirectory(at: path, reply: done) }
            return
        }
        try admin([["/bin/mkdir", "-p", path]])
    }

    public static func removeQuarantine(_ path: String) throws {
        if usesHelper {
            try helperCall { proxy, done in proxy.removeQuarantine(at: path, reply: done) }
            return
        }
        try admin([["/usr/bin/xattr", "-d", "com.apple.quarantine", path]])
    }

    /// Links /usr/local/bin/ldm to the bundled CLI: silently through the helper, otherwise with a prompt.
    public static func linkCommandLineTool(_ bundledPath: String) throws {
        if usesHelper {
            try helperCall { proxy, done in proxy.linkCommandLineTool(bundledPath, reply: done) }
            return
        }
        try admin([["/bin/mkdir", "-p", "/usr/local/bin"], ["/bin/ln", "-sfn", bundledPath, HelperPolicy.cliLinkPath]])
    }

    /// `sfltool dumpbtm`: silent through the helper, otherwise macOS prompts.
    public static func dumpBackgroundItems() -> ShellResult {
        if usesHelper {
            return HelperClient.shared.call(fallback: ShellResult(status: -1, stdout: "", stderr: "The helper didn’t answer.")) { proxy, done in
                proxy.dumpBackgroundItems { out, err in
                    done(out.map { ShellResult(status: 0, stdout: $0, stderr: "") } ?? ShellResult(status: 1, stdout: "", stderr: err ?? "Failed."))
                }
            }
        }
        return Shell.run("/usr/bin/sfltool", ["dumpbtm"])
    }

    private static func helperCall(_ body: (LDHelperProtocol, @escaping (String?) -> Void) -> Void) throws {
        let error = HelperClient.shared.call(fallback: "The helper didn’t answer." as String?) { proxy, done in
            body(proxy) { done($0) }
        }
        if let error { throw LDError.io(error) }
    }

    private static func admin(_ commands: [[String]]) throws {
        let r = Shell.runAsAdmin(commands)
        if r.succeeded { return }
        throw r.status == 4 ? LDError.authorizationCancelled : LDError.io(r.message.isEmpty ? "The command failed." : r.message)
    }
}
