import Foundation

/// One entry of a domain's "services" table in `launchctl print <domain>`.
public struct ServiceListing: Equatable, Sendable {
    public let label: String
    public let pid: Int?
    public let lastExit: Int?
}

/// Selected fields of `launchctl print <domain>/<label>`.
public struct ServiceDetail: Equatable, Sendable {
    public var state: String?
    public var pid: Int?
    public var runs: Int?
    public var lastExitCode: Int?
    public var lastExitText: String?
    public var raw: String = ""
}

/// Thin wrapper over launchctl. `launchctl print` output is explicitly not an
/// API, so every parser here is defensive: unknown lines are ignored.
public enum Launchctl {
    static let path = "/bin/launchctl"

    // MARK: Reading

    public static func services(in domain: String) -> [String: ServiceListing] {
        let r = Shell.run(path, ["print", domain])
        return parseServices(r.stdout)
    }

    public static func parseServices(_ text: String) -> [String: ServiceListing] {
        var result: [String: ServiceListing] = [:]
        var inBlock = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if trimmed == "services = {" { inBlock = true }
                continue
            }
            if trimmed == "}" { break }
            let cols = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 3, let pid = Int(cols[0]) else { continue }
            let label = cols[2...].joined(separator: " ")
            result[label] = ServiceListing(label: label, pid: pid > 0 ? pid : nil, lastExit: Int(cols[1]))
        }
        return result
    }

    /// label → disabled?
    public static func disabledOverrides(in domain: String) -> [String: Bool] {
        parseDisabled(Shell.run(path, ["print-disabled", domain]).stdout)
    }

    public static func parseDisabled(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let arrow = t.range(of: "\" => ") else { continue }
            let label = String(t[t.index(after: t.startIndex)..<arrow.lowerBound])
            let value = t[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            result[label] = (value == "disabled" || value == "true")
        }
        return result
    }

    public static func detail(target: String) -> ServiceDetail? {
        let r = Shell.run(path, ["print", target])
        guard r.succeeded else { return nil }
        return parseDetail(r.stdout)
    }

    public static func parseDetail(_ text: String) -> ServiceDetail {
        var d = ServiceDetail(raw: text)
        // Only top-level fields (one tab deep) belong to the service itself.
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let eq = t.range(of: " = ") else { continue }
            let key = String(t[..<eq.lowerBound])
            let value = String(t[eq.upperBound...])
            switch key {
            case "state": d.state = value
            case "pid": d.pid = Int(value)
            case "runs": d.runs = Int(value)
            case "last exit code":
                // "78: EX_CONFIG", "1", "(never exited)", or "(signal) 15: Terminated: 15"
                let head = value.split(separator: ":").first.map(String.init) ?? value
                if let n = Int(head.trimmingCharacters(in: .whitespaces)) {
                    d.lastExitCode = n
                } else if value.hasPrefix("(signal)") {
                    let rest = value.dropFirst("(signal)".count).trimmingCharacters(in: .whitespaces)
                    if let n = Int(rest.split(separator: ":").first ?? "") { d.lastExitCode = -n }
                }
                d.lastExitText = value
            case "last terminating signal":
                // "Terminated: 15"
                if let n = Int(value.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") {
                    d.lastExitCode = -n
                }
                d.lastExitText = value
            default: break
            }
        }
        return d
    }

    // MARK: Changing

    public enum Action: String, CaseIterable, Sendable {
        case start, stop, restart, load, unload, enable, disable
    }

    /// The exact launchctl invocations for an action, in order.
    public static func commands(for action: Action, job: Job) -> [[String]] {
        let domain = job.scope.domain
        let target = "\(domain)/\(job.label)"
        let plist = job.definition.url.path
        switch action {
        case .start:
            return (job.isLoaded ? [] : [[path, "bootstrap", domain, plist]]) + [[path, "kickstart", target]]
        case .restart:
            return (job.isLoaded ? [] : [[path, "bootstrap", domain, plist]]) + [[path, "kickstart", "-k", target]]
        case .stop:
            return [[path, "kill", "SIGTERM", target]]
        case .load:
            return [[path, "bootstrap", domain, plist]]
        case .unload:
            return [[path, "bootout", target]]
        case .enable:
            return [[path, "enable", target]] + (job.isLoaded ? [] : [[path, "bootstrap", domain, plist]])
        case .disable:
            return (job.isLoaded ? [[path, "bootout", target]] : []) + [[path, "disable", target]]
        }
    }

    @discardableResult
    public static func perform(_ action: Action, on job: Job) throws -> [[String]] {
        if job.scope.isReadOnly && action != .start && action != .stop && action != .restart {
            throw LDError.readOnly(job.label)
        }
        let cmds = commands(for: action, job: job)
        guard !cmds.isEmpty else { return cmds }
        let result: ShellResult
        if job.scope.launchctlNeedsAdmin {
            result = Privileged.launchctl(cmds)
        } else {
            var last = ShellResult(status: 0, stdout: "", stderr: "")
            for argv in cmds {
                last = Shell.run(argv[0], Array(argv.dropFirst()))
                if !last.succeeded { break }
            }
            result = last
        }
        if result.status == 4 && result.message.contains("cancelled") { throw LDError.authorizationCancelled }
        if !result.succeeded { throw LDError.launchd(explain(launchctlError: result.message)) }
        return cmds
    }

    /// Rewrites launchctl's terse errors in plain language.
    public static func explain(launchctlError message: String) -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.contains("Bootstrap failed: 5") {
            return "launchd refused to load the job. It is usually already loaded, disabled, or the plist is invalid. (\(m))"
        }
        if m.contains("Bootstrap failed: 37") || m.contains("Operation already in progress") {
            return "The job is already loaded. (\(m))"
        }
        if m.contains("Could not find service") || m.contains("No such process") {
            return "The job isn’t loaded in launchd. (\(m))"
        }
        if m.contains("Operation not permitted") || m.contains("Not privileged") {
            return "This needs administrator rights. (\(m))"
        }
        return m.isEmpty ? "launchctl failed without a message." : m
    }
}

public enum LDError: LocalizedError, Equatable {
    case readOnly(String)
    case authorizationCancelled
    case launchd(String)
    case notFound(String)
    case ambiguous(String, [String])
    case invalid(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .readOnly(let l): "\(l) is an Apple job on the read-only system volume."
        case .authorizationCancelled: "Administrator authorization was cancelled."
        case .launchd(let m): m
        case .notFound(let q): "No job matches “\(q)”."
        case .ambiguous(let q, let c): "“\(q)” matches \(c.count) jobs: \(c.prefix(6).joined(separator: ", "))\(c.count > 6 ? ", …" : "")"
        case .invalid(let m): m
        case .io(let m): m
        }
    }
}
