import AppKit
import LDCore
import ServiceManagement
import SwiftUI

/// The section name in System Settings → General → Login Items, which changed across releases.
enum LoginItemsWording {
    static var section: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "App Background Activity" : "Allow in the Background"
    }
}

/// A privileged action waiting on the user's choice: install the helper, or use a password this time.
struct PrivilegeRequest: Identifiable {
    let id = UUID()
    let reason: String
    let action: () -> Void
}

/// Asked in context, the first time the user does something that needs root.
struct HelperPromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PrivilegeRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install the privileged helper?").font(.title3.weight(.semibold))
                    Text(request.reason).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("LD Manager’s helper makes these changes for you, so you aren’t asked for your password each time.")
                Label("Loads, starts and stops system daemons", systemImage: "server.rack")
                Label("Saves plists in /Library", systemImage: "doc.badge.gearshape")
                Label("Reads \(LoginItemsWording.section) without a password", systemImage: "person.badge.key")
                Text("An administrator approves it once in System Settings. It only accepts LD Manager and its ldm tool, and you can remove it any time in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Password Instead") {
                    dismiss()
                    model.declineHelper(andRun: request.action)
                }
                Button("Continue") {
                    dismiss()
                    model.setUpHelper(then: request.action)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

/// Step-by-step guide shown in a small floating panel beside System Settings
/// while the user turns the helper on. Status updates live.
struct HelperGuideView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn on LD Manager").font(.headline)
                    Text("One switch in System Settings").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                step(1, "System Settings is open at General › Login Items.")
                step(2, "Scroll to \(LoginItemsWording.section) and find LD Manager.")
                step(3, "Turn its switch on. macOS may ask for your password or Touch ID.")
            }
            Text("You may also see a “Background Items Added” notification. That’s this helper.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            statusRow
            HStack {
                Button("Not Now") { model.cancelHelperSetup() }
                Spacer()
                Button("Reopen System Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 300)
    }

    func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder var statusRow: some View {
        switch model.helperSetupPhase {
        case .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to turn it on…").font(.callout)
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Approved. Checking the helper…").font(.callout)
            }
        case .done:
            Label("Helper approved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notRunning:
            Label("Approved, but the helper didn’t start. Log out and back in, then try again.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        case .idle:
            EmptyView()
        }
    }
}

/// Owns the floating guide panel and keeps it next to the System Settings window.
@MainActor
final class HelperGuidePanel {
    private var panel: NSPanel?

    func show(model: AppModel) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "LD Manager Helper"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: HelperGuideView().environment(model))
            panel = p
        }
        panel?.orderFrontRegardless()
        // System Settings takes a moment to open; place the panel beside it once it has.
        for delay in [0.1, 0.8, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.position() }
        }
    }

    func close() {
        panel?.close()
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        let size = panel.frame.size
        var origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.maxY - size.height - 24)
        if let settings = Self.systemSettingsFrame() {
            // CoreGraphics window bounds are top-left based; AppKit's are bottom-left.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let top = primaryHeight - settings.minY
            let x = settings.maxX + 12 + size.width <= screen.visibleFrame.maxX ? settings.maxX + 12 : settings.minX - size.width - 12
            origin = NSPoint(x: max(screen.visibleFrame.minX, x), y: top - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    /// Bounds of the frontmost System Settings window (owner name and bounds need no permission).
    private static func systemSettingsFrame() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowOwnerName as String] as? String) == "System Settings" && (info[kCGWindowLayer as String] as? Int) == 0 {
            if let b = info[kCGWindowBounds as String] as? [String: CGFloat],
               let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 200 {
                return CGRect(x: x, y: y, width: w, height: h)
            }
        }
        return nil
    }
}

/// Non-modal reminder: shown after the user chose passwords, or turned the helper off.
struct HelperBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.helperRevoked ? "exclamationmark.shield" : "lock.shield")
                .foregroundStyle(model.helperRevoked ? .orange : .secondary)
            Text(model.helperRevoked
                 ? "The helper is switched off, so system changes ask for your password again."
                 : "System changes ask for your password each time.")
                .font(.callout)
            Spacer()
            Button(model.helperRevoked ? "Turn It Back On…" : "Install Helper…") { model.setUpHelper(then: nil) }
                .controlSize(.small)
            Button { model.dismissHelperBanner() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
