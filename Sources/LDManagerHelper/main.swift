// LD Manager's privileged helper. launchd starts it on demand as root (it is
// registered by the app with SMAppService and approved by the user once). It
// accepts XPC connections only from LD Manager and its ldm CLI signed by the
// same team, and does only what HelperPolicy allows.
import Foundation
import LDCore
import Security

final class Helper: NSObject, NSXPCListenerDelegate, LDHelperProtocol {
    private let lock = NSLock()
    private var openConnections = 0
    private var lastActivity = Date()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LDHelperProtocol.self)
        connection.exportedObject = self
        touch(+1)
        connection.invalidationHandler = { [weak self] in self?.touch(-1) }
        connection.resume()
        return true
    }

    private func touch(_ delta: Int) {
        lock.lock(); openConnections += delta; lastActivity = Date(); lock.unlock()
    }

    /// launchd starts the helper on demand, so it exits when idle; the next
    /// request relaunches it from the current app bundle, which also picks up updates.
    func exitWhenIdle(after seconds: TimeInterval) {
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let idle = self.openConnections <= 0 && Date().timeIntervalSince(self.lastActivity) > seconds
            self.lock.unlock()
            if idle { exit(0) }
        }
    }

    func version(reply: @escaping (String) -> Void) {
        reply(HelperPolicy.version)
    }

    func launchctl(_ arguments: [String], reply: @escaping (Int32, String, String) -> Void) {
        if let error = HelperPolicy.validateLaunchctl(arguments) { return reply(64, "", error) }
        if arguments[0] == "bootstrap", let error = checkRegularFile(arguments[2]) { return reply(64, "", error) }
        let r = Shell.run("/bin/launchctl", arguments)
        reply(r.status, r.stdout, r.stderr)
    }

    func installPlist(_ data: Data, at path: String, reply: @escaping (String?) -> Void) {
        if let error = HelperPolicy.validateJobPath(path) { return reply(error) }
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any], dict["Label"] is String else {
            return reply("That isn’t a launchd job plist.")
        }
        if isSymlink(path) { return reply("Refusing to replace a symbolic link.") }
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = "\(dir)/.ldm-\(UUID().uuidString).plist"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o644]) else {
            return reply("Couldn’t write \(tmp).")
        }
        guard chown(tmp, 0, 0) == 0, chmod(tmp, 0o644) == 0, rename(tmp, path) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(tmp)
            return reply("Couldn’t install the plist: \(message)")
        }
        reply(nil)
    }

    func trashPlist(at path: String, reply: @escaping (String?) -> Void) {
        if let error = HelperPolicy.validateJobPath(path) { return reply(error) }
        if let error = checkRegularFile(path) { return reply(error) }
        guard let uid = NSXPCConnection.current()?.effectiveUserIdentifier, let pw = getpwuid(uid) else {
            return reply("Couldn’t identify the calling user.")
        }
        let trash = String(cString: pw.pointee.pw_dir) + "/.Trash"
        var dest = "\(trash)/\((path as NSString).lastPathComponent)"
        if FileManager.default.fileExists(atPath: dest) {
            dest = "\(trash)/\(UUID().uuidString.prefix(8))-\((path as NSString).lastPathComponent)"
        }
        guard rename(path, dest) == 0 || (copyThenRemove(path, dest)) else {
            return reply("Couldn’t move it to the Trash: \(String(cString: strerror(errno)))")
        }
        _ = chown(dest, uid, pw.pointee.pw_gid)
        reply(nil)
    }

    func fixPlistPermissions(at path: String, reply: @escaping (String?) -> Void) {
        if let error = HelperPolicy.validateJobPath(path) { return reply(error) }
        if let error = checkRegularFile(path) { return reply(error) }
        guard chown(path, 0, 0) == 0, chmod(path, 0o644) == 0 else {
            return reply(String(cString: strerror(errno)))
        }
        reply(nil)
    }

    func createDirectory(at path: String, reply: @escaping (String?) -> Void) {
        if let error = HelperPolicy.validateDirectory(path) { return reply(error) }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    func removeQuarantine(at path: String, reply: @escaping (String?) -> Void) {
        guard path.hasPrefix("/"), !path.contains("/../") else { return reply("Path must be absolute.") }
        if removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 || errno == ENOATTR { return reply(nil) }
        reply(String(cString: strerror(errno)))
    }

    func dumpBackgroundItems(reply: @escaping (String?, String?) -> Void) {
        let r = Shell.run("/usr/bin/sfltool", ["dumpbtm"])
        r.succeeded ? reply(r.stdout, nil) : reply(nil, r.message)
    }

    func linkCommandLineTool(_ bundledPath: String, reply: @escaping (String?) -> Void) {
        if let error = HelperPolicy.validateBundledCLI(bundledPath) { return reply(error) }
        if let error = checkRegularFile(bundledPath) { return reply(error) }
        // Only link a binary signed as our ldm by our own team.
        guard let team = HelperPolicy.currentTeamIdentifier() else { return reply("The helper isn’t signed.") }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundledPath) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(HelperPolicy.cliRequirement(team: team) as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            return reply("That ldm isn’t signed by LD Manager’s developer.")
        }
        let link = HelperPolicy.cliLinkPath
        let dir = (link as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        } catch {
            return reply(error.localizedDescription)
        }
        var st = stat()
        if lstat(link, &st) == 0 && (st.st_mode & S_IFMT) != S_IFLNK {
            return reply("\(link) already exists and isn’t a link LD Manager made. Remove it first.")
        }
        let tmp = "\(dir)/.ldm-link-\(UUID().uuidString)"
        guard symlink(bundledPath, tmp) == 0 else { return reply(String(cString: strerror(errno))) }
        guard rename(tmp, link) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(tmp)
            return reply(message)
        }
        reply(nil)
    }

    // MARK: Helpers

    private func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    private func checkRegularFile(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return "\(path) doesn’t exist." }
        return (st.st_mode & S_IFMT) == S_IFREG ? nil : "\(path) isn’t a regular file."
    }

    private func copyThenRemove(_ src: String, _ dest: String) -> Bool {
        do {
            try FileManager.default.copyItem(atPath: src, toPath: dest)
            try FileManager.default.removeItem(atPath: src)
            return true
        } catch {
            return false
        }
    }
}

guard let team = HelperPolicy.currentTeamIdentifier() else {
    FileHandle.standardError.write(Data("LD Manager helper: not signed with a team identifier; refusing to run.\n".utf8))
    exit(78)
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: HelperPolicy.machService)
listener.setConnectionCodeSigningRequirement(HelperPolicy.clientRequirement(team: team))
listener.delegate = helper
listener.resume()
helper.exitWhenIdle(after: 30)
RunLoop.main.run()
