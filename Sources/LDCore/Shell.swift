import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
    /// stderr if present, otherwise stdout, trimmed. Used for error messages.
    public var message: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : e
    }
}

public enum Shell {
    /// Runs an executable and captures its output. Output is decoded leniently:
    /// invalid UTF-8 (common in job logs) is replaced, never fatal.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Drain both pipes concurrently so a chatty child can't fill one and block.
        var outData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Quotes one argument for /bin/sh.
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func commandLine(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }

    /// Runs several commands as root behind one macOS administrator prompt.
    /// Used for system-domain jobs and files under /Library when we are not root.
    public static func runAsAdmin(_ commands: [[String]]) -> ShellResult {
        if getuid() == 0 {
            var last = ShellResult(status: 0, stdout: "", stderr: "")
            for argv in commands {
                last = run(argv[0], Array(argv.dropFirst()))
                if !last.succeeded { return last }
            }
            return last
        }
        let script = commands.map(commandLine).joined(separator: " && ")
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        if result.stderr.contains("User canceled") || result.stderr.contains("(-128)") {
            return ShellResult(status: 4, stdout: "", stderr: "Administrator authorization was cancelled.")
        }
        return result
    }
}
