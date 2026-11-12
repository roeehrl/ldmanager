import AppKit
import Sparkle
import SwiftUI

/// Keeps LD Manager up to date with Sparkle. Checks once a day; a found update is
/// downloaded in the background, verified (EdDSA signature on a signed feed, plus the
/// Developer ID signature) and installed when the app quits, or straight away when
/// the app is idle in the menu bar. See docs/auto-update.md.
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    /// Asked before a silent install: is anything open or running?
    @ObservationIgnored weak var model: AppModel?

    var canCheck = false
    var automaticallyChecks = true
    var automaticallyInstalls = true
    var lastCheck: Date?
    /// A newer version found by a scheduled check, not downloaded (automatic installs are off).
    var availableVersion: String?
    /// A downloaded, verified update that installs when the app quits (or when idle).
    var stagedVersion: String?
    /// Either of the above, for the menu bar badge.
    var pendingVersion: String? { stagedVersion ?? availableVersion }
    /// Sparkle's handler that installs the staged update now and relaunches.
    @ObservationIgnored private var installStaged: (() -> Void)?
    /// True once we asked Sparkle to install without a window (idle in the menu bar).
    @ObservationIgnored private var silentInstall = false

    /// The time of a silent relaunch, so the app comes back to the menu bar without opening its window.
    static let relaunchedKey = "LDMRelaunchedForUpdate"

    /// Whether this launch is the relaunch after a silent update (within the last 2 minutes).
    static func consumeRelaunchFlag() -> Bool {
        let at = UserDefaults.standard.object(forKey: relaunchedKey) as? Date
        UserDefaults.standard.removeObject(forKey: relaunchedKey)
        return at.map { Date().timeIntervalSince($0) < 120 } ?? false
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        let u = controller.updater
        observers = [
            u.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
                let v = u.canCheckForUpdates
                Task { @MainActor in self?.canCheck = v }
            },
            u.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] u, _ in
                let v = u.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheck = v }
            },
            u.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] u, _ in
                let v = u.automaticallyChecksForUpdates
                Task { @MainActor in self?.automaticallyChecks = v }
            },
            u.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] u, _ in
                let v = u.automaticallyDownloadsUpdates
                Task { @MainActor in self?.automaticallyInstalls = v }
            },
        ]
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// The menu bar button: install a staged update now, or show an available one.
    func installOrShowUpdate() {
        guard let install = installStaged else { return checkForUpdates() }
        installStaged = nil
        Task { @MainActor in
            await model?.prepareHelperForUpdate()
            install()
        }
    }

    func setAutomaticallyChecks(_ on: Bool) { updater.automaticallyChecksForUpdates = on }
    func setAutomaticallyInstalls(_ on: Bool) { updater.automaticallyDownloadsUpdates = on }

    /// An administrator (configuration profile) has fixed these settings.
    var isManaged: Bool {
        ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate"].contains { UserDefaults.standard.objectIsForced(forKey: $0) }
            || UserDefaults.standard.bool(forKey: "UpdatesDisabled")
    }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: SPUUpdaterDelegate

    /// Never send a system profile, whatever the defaults say.
    nonisolated func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    /// `defaults write io.github.roeehrl.ldmanager UpdatesDisabled -bool true` (or a
    /// configuration profile) turns off every check, manual ones too.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if UserDefaults.standard.bool(forKey: "UpdatesDisabled") {
            throw NSError(domain: "io.github.roeehrl.ldmanager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Updates are turned off on this Mac by your administrator."])
        }
    }

    /// For end-to-end tests only: a staging feed. It must still be signed with the release key.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "LDMStagingFeedURL")
    }

    /// LD Manager lives in the menu bar and rarely quits: install now if nothing is
    /// open or running, otherwise when it quits.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            self.stagedVersion = version
            self.availableVersion = nil
            self.installStaged = immediateInstallHandler
            self.installWhenIdle()
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            self.stagedVersion = nil
            self.installStaged = nil
            self.silentInstall = false
        }
    }

    /// Only a relaunch we started silently comes back without a window.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Task { @MainActor in
            if self.silentInstall { UserDefaults.standard.set(Date(), forKey: Self.relaunchedKey) }
        }
    }

    /// Wait for a quiet moment (checked every minute) rather than interrupting the user.
    private func installWhenIdle() {
        Task { @MainActor [weak self] in
            while let self, let install = self.installStaged {
                if self.model?.isIdleForUpdate == true {
                    self.installStaged = nil
                    await self.model?.prepareHelperForUpdate()
                    self.silentInstall = true
                    // Written here too: the relaunch callback may not get a turn on the main actor before exit.
                    UserDefaults.standard.set(Date(), forKey: Self.relaunchedKey)
                    install()
                    return
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Scheduled update alerts appear without stealing focus; the menu bar shows a badge.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        Task { @MainActor in if !userInitiated && self.stagedVersion == nil { self.availableVersion = version } }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}
