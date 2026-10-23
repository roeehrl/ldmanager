import AppKit
import LDCore
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case problems
    case recent
    case scope(JobScope)
    case apple
    case group(String)
}

@MainActor
@Observable
final class AppModel {
    var jobs: [Job] = []
    var appleJobs: [Job] = []
    var diagnoses: [Diagnosis] = []
    var backups: [PlistEditor.Backup] = []

    var sidebar: SidebarItem = .scope(.user) {
        didSet {
            selectedJobID = nil
            if sidebar == .apple && appleJobs.isEmpty { Task { await loadApple() } }
            if sidebar == .recent { backups = PlistEditor.backups() }
        }
    }
    /// Last "Allow in the Background" read. Reading it again prompts for a password,
    /// so it only happens when the user clicks Check Login Items.
    var background: BackgroundItems.Snapshot? = BackgroundItems.cached()
    var isCheckingBackground = false
    var selectedJobID: Job.ID?
    var selectedProblemID: Diagnosis.ID?
    var search = ""
    var showInspector = true
    var isRefreshing = false
    var hasLoaded = false
    var errorMessage: String?
    var editorTarget: EditorTarget?
    var confirmTrash: Job?

    var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? []) {
        didSet { UserDefaults.standard.set(Array(pinned).sorted(), forKey: "pinned") }
    }

    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    init() {
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = UserDefaults.standard.double(forKey: "refreshInterval")
                try? await Task.sleep(for: .seconds(interval > 0 ? interval : 5))
            }
        }
    }

    // MARK: Data

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let snapshot = background
        let loaded = await Task.detached(priority: .userInitiated) { Inventory.load(.init(background: snapshot)) }.value
        jobs = loaded
        diagnoses = await Task.detached { Doctor.problems(in: loaded) }.value
        if selectedProblemID == nil || !diagnoses.contains(where: { $0.id == selectedProblemID }) {
            selectedProblemID = diagnoses.first?.id
        }
        if sidebar == .recent { backups = PlistEditor.backups() }
        hasLoaded = true
        isRefreshing = false
    }

    /// Reads Background Task Management. macOS shows its administrator prompt.
    func checkLoginItems() {
        guard !isCheckingBackground else { return }
        isCheckingBackground = true
        Task {
            if let fresh = await Task.detached(priority: .userInitiated, operation: { BackgroundItems.refresh() }).value {
                background = fresh
            }
            isCheckingBackground = false
            await refresh()
        }
    }

    func openLoginItemsSettings() {
        NSWorkspace.shared.open(BackgroundItems.settingsURL)
    }

    func loadApple() async {
        appleJobs = await Task.detached { Inventory.load(.init(scopes: [.appleAgent, .appleDaemon], details: false)) }.value
    }

    var allJobs: [Job] { jobs + appleJobs }

    func job(_ id: Job.ID?) -> Job? {
        guard let id else { return nil }
        return allJobs.first { $0.id == id }
    }

    var selectedJob: Job? { job(selectedJobID) }

    func count(_ scope: JobScope) -> Int { jobs.filter { $0.scope == scope }.count }

    /// Vendor groups with at least two jobs, largest first.
    var groups: [(name: String, count: Int)] {
        let counts = Dictionary(grouping: jobs, by: \.group).mapValues(\.count)
        return counts.filter { $0.value >= 2 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) }
    }

    var title: String {
        switch sidebar {
        case .problems: "Problems"
        case .recent: "Recent Changes"
        case .scope(let s): s.title
        case .apple: "Apple"
        case .group(let g): g.prefix(1).uppercased() + g.dropFirst()
        }
    }

    var visibleJobs: [Job] {
        var list: [Job]
        switch sidebar {
        case .scope(let s): list = jobs.filter { $0.scope == s }
        case .apple: list = appleJobs
        case .group(let g): list = jobs.filter { $0.group == g }
        case .problems, .recent: list = []
        }
        return filter(list, by: search)
    }

    /// Plain words match label, title or program; `status:failed`, `key:WatchPaths`
    /// and `scope:system` narrow further.
    func filter(_ list: [Job], by query: String) -> [Job] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return list }
        return list.filter { job in
            words.allSatisfy { w in
                if w.hasPrefix("status:") { return job.status.rawValue.lowercased().hasPrefix(String(w.dropFirst(7))) }
                if w.hasPrefix("key:") { return job.definition.raw.keys.contains { $0.lowercased() == w.dropFirst(4) } }
                if w.hasPrefix("scope:") { return job.scope.rawValue.lowercased().hasPrefix(String(w.dropFirst(6))) }
                return job.label.lowercased().contains(w) || job.title.lowercased().contains(w)
                    || (job.definition.program?.lowercased().contains(w) ?? false)
            }
        }
    }

    var subtitle: String {
        switch sidebar {
        case .problems: return diagnoses.isEmpty ? "Everything looks fine" : "\(diagnoses.count) job\(diagnoses.count == 1 ? "" : "s") need attention"
        case .recent: return "\(backups.count) backup\(backups.count == 1 ? "" : "s")"
        default:
            let list = visibleJobs
            let problemIDs = Set(diagnoses.map(\.id))
            let attention = list.filter { problemIDs.contains($0.id) }.count
            return "\(list.count) job\(list.count == 1 ? "" : "s")" + (attention > 0 ? " · \(attention) need\(attention == 1 ? "s" : "") attention" : "")
        }
    }

    func diagnosis(for job: Job) -> Diagnosis { Doctor.diagnose(job) }

    // MARK: Actions

    func perform(_ action: Launchctl.Action, on job: Job) {
        Task {
            do {
                _ = try await Task.detached { try Launchctl.perform(action, on: job) }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    func setActive(_ active: Bool, _ job: Job) {
        perform(active ? .enable : .disable, on: job)
    }

    func apply(_ fix: Fix, to job: Job) {
        switch fix {
        case .disable: perform(.disable, on: job)
        case .load: perform(.load, on: job)
        case .chooseProgram, .editPlist: editorTarget = .edit(job)
        case .openLoginItems: openLoginItemsSettings()
        case .revealPlist: reveal(job)
        case .openTerminal(let dir):
            NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        case .removeQuarantine(let path):
            run(job.scope == .user ? nil : "", ["/usr/bin/xattr", "-d", "com.apple.quarantine", path])
        case .createDirectory(let path):
            run(job.scope == .user ? nil : "", ["/bin/mkdir", "-p", path])
        case .fixPermissions:
            let p = job.definition.url.path
            if job.scope == .user { run(nil, ["/bin/chmod", "644", p]) } else {
                Task {
                    let r = await Task.detached { Shell.runAsAdmin([["/usr/sbin/chown", "root:wheel", p], ["/bin/chmod", "644", p]]) }.value
                    if !r.succeeded { errorMessage = r.message }
                    await refresh()
                }
            }
        }
    }

    /// Runs one command, as admin when `admin` is non-nil.
    private func run(_ admin: String?, _ argv: [String]) {
        Task {
            let r = await Task.detached { admin == nil ? Shell.run(argv[0], Array(argv.dropFirst())) : Shell.runAsAdmin([argv]) }.value
            if !r.succeeded { errorMessage = r.message.isEmpty ? "The command failed." : r.message }
            await refresh()
        }
    }

    func reveal(_ job: Job) {
        NSWorkspace.shared.activateFileViewerSelecting([job.definition.url])
    }

    func copyLabel(_ job: Job) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(job.label, forType: .string)
    }

    func trash(_ job: Job) {
        Task {
            do { try await Task.detached { try PlistEditor.trash(job) }.value } catch { errorMessage = error.localizedDescription }
            selectedJobID = nil
            await refresh()
        }
    }

    func togglePin(_ job: Job) {
        if pinned.contains(job.label) { pinned.remove(job.label) } else { pinned.insert(job.label) }
    }

    var pinnedJobs: [Job] { jobs.filter { pinned.contains($0.label) }.sorted { $0.title < $1.title } }

    func restore(_ backup: PlistEditor.Backup) {
        guard let path = backup.originalPath else { errorMessage = "This backup doesn’t record where it came from."; return }
        let url = URL(fileURLWithPath: path)
        let scope = JobScope.editable.first { url.deletingLastPathComponent().path == $0.directory.path } ?? .user
        Task {
            do {
                let def = JobDefinition.load(url: backup.url, scope: scope)
                if let err = def.parseError { throw LDError.invalid(err) }
                _ = try await Task.detached { try PlistEditor.write(def.raw, to: url, scope: scope) }.value
                if let job = jobs.first(where: { $0.definition.url == url }), job.isLoaded {
                    try await Task.detached {
                        try Launchctl.perform(.unload, on: job)
                        try Launchctl.perform(.load, on: Inventory.reload(job))
                    }.value
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }
}

enum EditorTarget: Identifiable {
    case edit(Job)
    case new

    var id: String {
        switch self {
        case .edit(let j): j.id
        case .new: "new"
        }
    }
}
