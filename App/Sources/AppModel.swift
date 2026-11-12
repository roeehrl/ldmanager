import AppKit
import LDCore
import Observation
import ServiceManagement
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
    /// Problems that need attention: not dismissed by the user.
    var diagnoses: [Diagnosis] = []
    /// Problems the user dismissed; shown in a collapsed section, restorable.
    var dismissedDiagnoses: [Diagnosis] = []
    var dismissals: [Dismissal] = Dismissals.load()
    var backups: [PlistEditor.Backup] = []

    var sidebar: SidebarItem = .scope(.user) {
        didSet {
            selectedJobID = nil
            if sidebar == .apple && appleJobs.isEmpty { Task { await loadApple() } }
            if sidebar == .recent { backups = PlistEditor.backups() }
        }
    }
    /// Last "App Background Activity" read. Reading it again prompts for a password,
    /// so it only happens when the user clicks Check Login Items.
    var background: BackgroundItems.Snapshot? = BackgroundItems.cached()
    var isCheckingBackground = false
    /// The action running on each job; at most one per job.
    var operations: [Job.ID: JobOperation] = [:]
    /// How each job's last action ended, shown until the next action on it.
    var outcomes: [Job.ID: ActionOutcome] = [:]
    /// KeepAlive jobs the user stopped (unloaded until Start or the next login). Not persisted.
    var stoppedByRequest: [Job.ID: Date] = [:]
    var forceQuitAt: [Job.ID: Date] = [:]
    /// Operations ended by the 90 s cap whose real result may still arrive.
    @ObservationIgnored var lateTokens: Set<UUID> = []
    @ObservationIgnored private var refreshQueued = false
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
        updateHelperState()
        Task { [weak self] in await self?.checkHelperResponds() }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.refreshBackgroundIfSilent()
                let interval = UserDefaults.standard.double(forKey: "refreshInterval")
                try? await Task.sleep(for: .seconds(interval > 0 ? interval : 5))
            }
        }
    }

    // MARK: Data

    /// `force`: if a refresh is already running, run another one after it (its
    /// snapshot may predate the change the caller just made).
    func refresh(force: Bool = false) async {
        guard !isRefreshing else {
            if force { refreshQueued = true }
            return
        }
        isRefreshing = true
        defer {
            if refreshQueued {
                refreshQueued = false
                Task { await refresh() }
            }
        }
        let began = Date()
        let snapshot = background
        let loaded = await Task.detached(priority: .userInitiated) { Inventory.load(.init(background: snapshot)) }.value
        jobs = loaded
        // A stopped KeepAlive job reads "Stopped" until it is loaded or disabled again.
        for (id, at) in stoppedByRequest where at < began {
            if let j = loaded.first(where: { $0.id == id }), !j.isLoaded && !j.isDisabled { continue }
            stoppedByRequest[id] = nil
        }
        let stopped = Set(stoppedByRequest.keys)
        let triage = await Task.detached { () -> (active: [Diagnosis], dismissed: [Diagnosis], all: [Dismissal]) in
            let all = Doctor.problems(in: loaded)
            // Forget dismissals of problems that are gone, so a fixed problem that comes back shows again.
            Dismissals.prune(current: all, jobs: loaded)
            let d = Dismissals.load()
            // "It isn't loaded" is expected right after the user stopped it.
            let stoppedOK = { (diagnoses: [Diagnosis]) in
                diagnoses.compactMap { dg -> Diagnosis? in
                    guard stopped.contains(dg.id) else { return dg }
                    let kept = Diagnosis(job: dg.job, checks: dg.checks, findings: dg.findings.filter { $0.id != "loaded" })
                    return kept.isProblem ? kept : nil
                }
            }
            let t = Doctor.triage(loaded, dismissals: d)
            return (stoppedOK(t.active), stoppedOK(t.dismissed), d)
        }.value
        diagnoses = triage.active
        dismissedDiagnoses = triage.dismissed
        dismissals = triage.all
        let visible = diagnoses + dismissedDiagnoses
        if selectedProblemID == nil || !visible.contains(where: { $0.id == selectedProblemID }) {
            selectedProblemID = diagnoses.first?.id ?? dismissedDiagnoses.first?.id
        }
        if sidebar == .recent { backups = PlistEditor.backups() }
        hasLoaded = true
        isRefreshing = false
    }

    /// Reads Background Task Management: silently through the helper, otherwise macOS prompts.
    func checkLoginItems() {
        withPrivilege(true, reason: "Checking \(LoginItemsWording.section) needs administrator rights.") { [weak self] in
            self?.readLoginItems()
        }
    }

    private func readLoginItems() {
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

    /// With the helper approved, reading Login Items is silent, so keep it fresh.
    func refreshBackgroundIfSilent() async {
        guard helperState == .enabled, !isCheckingBackground else { return }
        if let b = background, Date().timeIntervalSince(b.date) < 60 { return }
        isCheckingBackground = true
        // Nobody asked for this read, so it must never fall back to the password prompt.
        if let fresh = await Task.detached(priority: .utility, operation: { BackgroundItems.refresh(allowPrompt: false) }).value {
            background = fresh
            await refresh()
        }
        isCheckingBackground = false
    }

    // MARK: Privileged helper

    enum HelperState: Equatable {
        /// `broken`: macOS reports it approved, but it doesn't answer — typically
        /// because the app moved since it was registered.
        case notInstalled, needsApproval, enabled, notBundled, unsigned, broken
    }

    var helperState: HelperState = .notInstalled
    @ObservationIgnored let helperService = SMAppService.daemon(plistName: "\(HelperPolicy.machService).plist")

    enum SetupPhase: Equatable { case idle, waiting, verifying, done, notRunning }

    var helperSetupPhase: SetupPhase = .idle
    var privilegeRequest: PrivilegeRequest?
    /// The user chose passwords over the helper; don't ask again with a modal.
    var helperDeclined = UserDefaults.standard.bool(forKey: "helperDeclined") {
        didSet { UserDefaults.standard.set(helperDeclined, forKey: "helperDeclined") }
    }
    var helperRevoked = false
    var helperBannerVisible = false
    @ObservationIgnored private var pendingPrivileged: (() -> Void)?
    @ObservationIgnored private var pendingPrivilegedCancel: (() -> Void)?
    @ObservationIgnored private var approvalPoll: Task<Void, Never>?
    @ObservationIgnored let guidePanel = HelperGuidePanel()

    func updateHelperState() {
        let previous = helperState
        if HelperPolicy.currentTeamIdentifier() == nil { helperState = .unsigned; return }
        switch helperService.status {
        case .enabled: helperState = previous == .broken ? .broken : .enabled
        case .requiresApproval: helperState = .needsApproval
        case .notFound: helperState = .notBundled
        default: helperState = .notInstalled
        }
        if previous != helperState { HelperClient.shared.resetProbe() }
        // Switched off in System Settings after being approved: say so quietly, no modal.
        if previous == .enabled && helperState != .enabled && helperSetupPhase == .idle {
            helperRevoked = true
            helperBannerVisible = true
        }
        if helperState == .enabled { helperRevoked = false }
    }

    @ObservationIgnored private var repairAttempted = false

    /// macOS's "enabled" isn't proof the helper runs: after the app moves, the
    /// registration still points at the old copy. Check that it answers, and if
    /// not, register it again from this copy, once automatically per launch.
    func checkHelperResponds() async {
        guard helperService.status == .enabled, HelperPolicy.currentTeamIdentifier() != nil else { return }
        HelperClient.shared.resetProbe()
        if await Task.detached(operation: { HelperClient.shared.isAvailable }).value {
            helperState = .enabled
            await replaceOutdatedHelper()
            return
        }
        helperState = .broken
        guard !repairAttempted else { return }
        repairAttempted = true
        await repairHelper()
    }

    /// After an update, launchd may still be running the previous helper. Ask it to
    /// quit so the next request starts the copy in this bundle. A helper from before
    /// 0.1.4 doesn't know that request (and every check would keep it from idling
    /// out), so have launchd restart it instead. Re-register only if the new build
    /// still doesn't answer.
    func replaceOutdatedHelper() async {
        guard let mine = HelperPolicy.bundleBuild() else { return }
        func running() async -> String?? { await Task.detached { HelperClient.shared.runningBuild() }.value }
        guard let reply = await running(), reply != mine else { return }
        if reply == nil {
            // Before 0.1.4: no exit request. The connection drops as launchd restarts it; that's expected.
            _ = await Task.detached {
                Privileged.launchctl([["/bin/launchctl", "kickstart", "-k", "system/\(HelperPolicy.machService)"]])
            }.value
        } else {
            // It declines while another client (ldm, an operation) is connected; try again shortly.
            for _ in 0..<10 {
                if await Task.detached(operation: { HelperClient.shared.exitForUpdate() }).value { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        for _ in 0..<15 {
            try? await Task.sleep(for: .seconds(1))
            if let now = await running(), now == mine { return }
        }
        guard !repairAttempted else { return }
        repairAttempted = true
        await repairHelper()
    }

    /// Before installing an update: let the helper quit, so it isn't running from the old bundle.
    func prepareHelperForUpdate() async {
        guard helperState == .enabled else { return }
        _ = await Task.detached { HelperClient.shared.exitForUpdate() }.value
    }

    /// Nothing the user would lose by a silent relaunch: no window, sheet or running action.
    var isIdleForUpdate: Bool {
        operations.isEmpty && !isSheetOpen && editorTarget == nil && !NSApp.isHidden
            && !NSApp.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Unregisters and registers the helper again from this copy of the app.
    func repairHelper() async {
        try? await helperService.unregister()
        // Registering right after unregistering can fail; macOS needs a moment.
        try? await Task.sleep(for: .seconds(2))
        try? helperService.register()
        helperState = .notInstalled
        updateHelperState()
        HelperClient.shared.resetProbe()
        switch helperState {
        case .enabled:
            let ok = await Task.detached(operation: { HelperClient.shared.isAvailable }).value
            helperState = ok ? .enabled : .broken
        case .needsApproval:
            setUpHelper(then: nil)
        default:
            break
        }
    }

    /// Runs `action`, first offering the helper when it needs root and the helper isn't on.
    /// `onCancel` runs instead of `action` if the user backs out, so callers never wait forever.
    func withPrivilege(_ needed: Bool, reason: String, onCancel: (() -> Void)? = nil, _ action: @escaping () -> Void) {
        guard needed, helperState != .enabled, helperState != .unsigned else { return action() }
        if helperDeclined || helperSetupPhase != .idle {
            helperBannerVisible = true
            return action()
        }
        privilegeRequest = PrivilegeRequest(reason: reason, action: action, onCancel: onCancel)
    }

    /// Registers the helper, guides the user through approval, then runs `action`.
    func setUpHelper(then action: (() -> Void)?, orCancel cancel: (() -> Void)? = nil) {
        pendingPrivileged = action
        pendingPrivilegedCancel = cancel
        helperBannerVisible = false
        // register() reports "needs approval" as an error; the status is what counts.
        try? helperService.register()
        updateHelperState()
        switch helperState {
        case .enabled:
            verifyHelper()
        case .needsApproval:
            helperSetupPhase = .waiting
            SMAppService.openSystemSettingsLoginItems()
            guidePanel.show(model: self)
            startApprovalPolling()
        case .notBundled:
            dropPendingPrivileged()
            errorMessage = "macOS couldn’t find LD Manager’s helper in this copy of the app. Build it with scripts/build-app.sh, or move the app to Applications and try again."
        case .unsigned:
            dropPendingPrivileged()
            errorMessage = "The helper needs LD Manager signed with a Developer ID or Apple Development certificate."
        case .notInstalled:
            dropPendingPrivileged()
            errorMessage = "macOS didn’t register the helper. Try again, or remove LD Manager from \(LoginItemsWording.section) and retry."
        case .broken:
            let action = pendingPrivileged
            pendingPrivileged = nil
            pendingPrivilegedCancel = nil
            Task {
                await repairHelper()
                if let action {
                    if helperState != .enabled { helperBannerVisible = true }
                    action()
                }
            }
        }
    }

    func cancelHelperSetup() {
        approvalPoll?.cancel()
        guidePanel.close()
        helperSetupPhase = .idle
        if let action = pendingPrivileged {
            // They started something; finish it the old way rather than dropping it.
            pendingPrivileged = nil
            pendingPrivilegedCancel = nil
            helperBannerVisible = true
            action()
        }
    }

    /// The privileged action won't run after all: tell whoever is waiting on it.
    private func dropPendingPrivileged() {
        pendingPrivileged = nil
        let cancel = pendingPrivilegedCancel
        pendingPrivilegedCancel = nil
        cancel?()
    }

    func declineHelper(andRun action: @escaping () -> Void) {
        helperDeclined = true
        helperBannerVisible = true
        action()
    }

    func dismissHelperBanner() {
        helperBannerVisible = false
        helperRevoked = false
    }

    /// No notification exists for approval, so poll while the guide is open.
    private func startApprovalPolling() {
        approvalPoll?.cancel()
        approvalPoll = Task { [weak self] in
            for _ in 0..<900 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.updateHelperState()
                if self.helperState == .enabled {
                    self.verifyHelper()
                    return
                }
            }
            self?.dropPendingPrivileged()
        }
    }

    /// Enabled isn't proof it runs: ping it before declaring success.
    private func verifyHelper() {
        helperSetupPhase = .verifying
        HelperClient.shared.resetProbe()
        Task {
            var ok = false
            for _ in 0..<5 where !ok {
                ok = await Task.detached { HelperClient.shared.isAvailable }.value
                if !ok {
                    HelperClient.shared.resetProbe()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            if ok {
                helperSetupPhase = .done
                helperDeclined = false
                helperBannerVisible = false
                try? await Task.sleep(for: .seconds(1.2))
                guidePanel.close()
                helperSetupPhase = .idle
                NSApp.activate()
                if let action = pendingPrivileged {
                    pendingPrivileged = nil
                    pendingPrivilegedCancel = nil
                    action()
                }
                await refreshBackgroundIfSilent()
            } else {
                helperSetupPhase = .notRunning
            }
        }
    }

    func uninstallHelper() {
        Task {
            do { try await helperService.unregister() } catch { errorMessage = "Couldn’t remove the helper: \(error.localizedDescription)" }
            helperSetupPhase = .idle
            updateHelperState()
            helperRevoked = false
            helperBannerVisible = false
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

    func apply(_ fix: Fix, to job: Job) {
        switch fix {
        case .disable: perform(.turnOff, on: job)
        case .load: perform(.load, on: job)
        case .restart: perform(.restart, on: job)
        case .trash: confirmTrash = job
        case .chooseProgram, .editPlist: editorTarget = .edit(job)
        case .openLoginItems: openLoginItemsSettings()
        case .revealPlist: reveal(job)
        case .openTerminal(let dir):
            NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        case .removeQuarantine(let path):
            if job.scope == .user { run(["/usr/bin/xattr", "-d", "com.apple.quarantine", path]) } else { privileged { try Privileged.removeQuarantine(path) } }
        case .createDirectory(let path):
            if job.scope == .user { run(["/bin/mkdir", "-p", path]) } else { privileged { try Privileged.createDirectory(path) } }
        case .fixPermissions:
            let p = job.definition.url.path
            if job.scope == .user { run(["/bin/chmod", "644", p]) } else { privileged { try Privileged.fixPlistPermissions(p) } }
        }
    }

    /// Runs a root operation off the main thread (helper, or an admin prompt without it).
    private func privileged(_ body: @escaping @Sendable () throws -> Void) {
        withPrivilege(true, reason: "This fix needs administrator rights.") { [weak self] in
            self?.privilegedNow(body)
        }
    }

    private func privilegedNow(_ body: @escaping @Sendable () throws -> Void) {
        Task {
            do { try await Task.detached { try body() }.value } catch { errorMessage = error.localizedDescription }
            await refresh()
        }
    }

    /// Runs one command as the current user.
    private func run(_ argv: [String]) {
        Task {
            let r = await Task.detached { Shell.run(argv[0], Array(argv.dropFirst())) }.value
            if !r.succeeded { errorMessage = r.message.isEmpty ? "The command failed." : r.message }
            await refresh()
        }
    }

    // MARK: Dismissing problems

    func dismiss(_ diagnosis: Diagnosis) {
        do { try Dismissals.dismiss(diagnosis) } catch { errorMessage = "Couldn’t dismiss it: \(error.localizedDescription)" }
        Task { await refresh() }
    }

    func restore(_ diagnosis: Diagnosis) {
        do { try Dismissals.restore(label: diagnosis.job.label) } catch { errorMessage = "Couldn’t restore it: \(error.localizedDescription)" }
        Task { await refresh() }
    }

    func isDismissed(_ diagnosis: Diagnosis) -> Bool {
        dismissedDiagnoses.contains { $0.id == diagnosis.id }
    }

    func reveal(_ job: Job) {
        NSWorkspace.shared.activateFileViewerSelecting([job.definition.url])
    }

    func copyLabel(_ job: Job) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(job.label, forType: .string)
    }

    func trash(_ job: Job) {
        withPrivilege(job.scope.fileNeedsAdmin, reason: "Removing “\(job.title)” from /Library needs administrator rights.") { [weak self] in
            self?.trashNow(job)
        }
    }

    private func trashNow(_ job: Job) {
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
        withPrivilege(scope.fileNeedsAdmin, reason: "Restoring a job in /Library needs administrator rights.") { [weak self] in
            self?.restoreNow(backup, to: url, scope: scope)
        }
    }

    private func restoreNow(_ backup: PlistEditor.Backup, to url: URL, scope: JobScope) {
        if let job = jobs.first(where: { $0.definition.url == url }), let op = operations[job.id] {
            errorMessage = "Wait for \(op.kind.verb) to finish, then restore “\(job.title)”."
            return
        }
        Task {
            do {
                let def = JobDefinition.load(url: backup.url, scope: scope)
                if let err = def.parseError { throw LDError.invalid(err) }
                _ = try await Task.detached { try PlistEditor.write(def.raw, to: url, scope: scope) }.value
                if let job = jobs.first(where: { $0.definition.url == url }), job.isLoaded {
                    reload(job, verb: "Restored")
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
