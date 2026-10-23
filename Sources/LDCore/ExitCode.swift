import Foundation

/// Explains launchd's "last exit code": program exit statuses, sysexits(3)
/// conventions and the signals that killed a job (negative values).
public enum ExitCode {
    static let signals: [Int: (String, String)] = [
        1: ("SIGHUP", "hang-up"), 2: ("SIGINT", "interrupted"), 3: ("SIGQUIT", "quit"),
        4: ("SIGILL", "illegal instruction (crash)"), 5: ("SIGTRAP", "trace trap (crash)"),
        6: ("SIGABRT", "aborted (crash)"), 9: ("SIGKILL", "killed"), 10: ("SIGBUS", "bus error (crash)"),
        11: ("SIGSEGV", "segmentation fault (crash)"), 13: ("SIGPIPE", "broken pipe"),
        14: ("SIGALRM", "alarm"), 15: ("SIGTERM", "asked to terminate"), 24: ("SIGXCPU", "CPU limit"),
        25: ("SIGXFSZ", "file size limit"), 30: ("SIGUSR1", "user signal 1"), 31: ("SIGUSR2", "user signal 2"),
    ]

    static let sysexits: [Int: (String, String)] = [
        64: ("EX_USAGE", "the program was called with the wrong arguments"),
        65: ("EX_DATAERR", "the input data was incorrect"),
        66: ("EX_NOINPUT", "an input file didn’t exist or wasn’t readable"),
        67: ("EX_NOUSER", "the user doesn’t exist"),
        68: ("EX_NOHOST", "the host doesn’t exist"),
        69: ("EX_UNAVAILABLE", "a service is unavailable"),
        70: ("EX_SOFTWARE", "internal software error"),
        71: ("EX_OSERR", "an operating system error"),
        72: ("EX_OSFILE", "a system file is missing"),
        73: ("EX_CANTCREAT", "an output file couldn’t be created"),
        74: ("EX_IOERR", "an input/output error"),
        75: ("EX_TEMPFAIL", "a temporary failure; retrying may work"),
        76: ("EX_PROTOCOL", "a remote protocol error"),
        77: ("EX_NOPERM", "permission denied"),
        78: ("EX_CONFIG", "configuration error — for launchd jobs usually a missing or non-executable program"),
    ]

    /// "Exit 78 · config error", "SIGTERM"
    public static func short(_ code: Int) -> String {
        if code == 0 { return "OK" }
        if code < 0, let s = signals[-code] { return s.0 }
        if code < 0 { return "Signal \(-code)" }
        switch code {
        case 78: return "Exit 78 · config error"
        case 126: return "Exit 126 · not executable"
        case 127: return "Exit 127 · not found"
        case 77: return "Exit 77 · no permission"
        default:
            if code > 128, code < 160, let s = signals[code - 128] { return "Exit \(code) · \(s.0)" }
            return "Exit \(code)"
        }
    }

    /// A sentence explaining the code.
    public static func explain(_ code: Int) -> String {
        if code == 0 { return "Exited successfully." }
        if code < 0 {
            let n = -code
            if let s = signals[n] { return "Killed by \(s.0) (signal \(n)): \(s.1)." }
            return "Killed by signal \(n)."
        }
        if let s = sysexits[code] { return "Exit \(code) (\(s.0)): \(s.1)." }
        switch code {
        case 1: return "Exit 1: a general failure reported by the program. Its log usually says why."
        case 2: return "Exit 2: usually wrong command-line usage."
        case 126: return "Exit 126: the program exists but couldn’t be executed (permissions or not a binary)."
        case 127: return "Exit 127: the shell couldn’t find the command."
        default:
            if code > 128, code < 160 {
                let n = code - 128
                let name = signals[n].map { "\($0.0): \($0.1)" } ?? "signal \(n)"
                return "Exit \(code): a shell reported its child was killed by \(name)."
            }
            return "Exit \(code): a failure code defined by the program."
        }
    }
}
