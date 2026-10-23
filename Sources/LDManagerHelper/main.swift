// LD Manager's privileged helper. launchd starts it on demand as root (it is
// registered by the app with SMAppService and approved by the user once). It
// accepts XPC connections only from LD Manager and its ldm CLI signed by the
// same team, and does only what HelperPolicy allows.
import Foundation
import LDCore

final class Helper: NSObject, NSXPCListenerDelegate, LDHelperProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LDHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
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
RunLoop.main.run()
