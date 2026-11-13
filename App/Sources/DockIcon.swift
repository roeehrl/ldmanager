import AppKit

/// Whether LD Manager shows in the Dock. With "Show in Dock" off it lives in the menu bar
/// only, and the Dock icon appears just while one of its windows is open, so the window
/// still works with ⌘-Tab and Mission Control.
@MainActor
enum DockIcon {
    static let key = "showInDock"
    static let menuBarKey = "showInMenuBar"

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Puts the icon in the Dock or takes it out, for the setting and the windows open now.
    /// `closing` is a window that is about to close and no longer counts.
    static func update(closing: NSWindow? = nil) {
        // Never both hidden (the menu bar item can also be ⌘-dragged away): keep the Dock icon.
        let defaults = UserDefaults.standard
        if !enabled && !(defaults.object(forKey: menuBarKey) as? Bool ?? true) { defaults.set(true, forKey: key) }
        let windowOpen = NSApp.windows.contains {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain && !($0 is NSPanel)
        }
        let policy: NSApplication.ActivationPolicy = enabled || windowOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Turning back into a regular app leaves it inactive; bring the window forward.
        if policy == .regular { NSApp.activate() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    /// Closing the window leaves LD Manager running in the menu bar (or the Dock).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the Dock icon first appears, so a menu-bar-only launch never shows it.
        if !DockIcon.enabled { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockIcon.update() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { DockIcon.update(closing: window) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockIcon.update() }
        })
        DockIcon.update()
    }
}
