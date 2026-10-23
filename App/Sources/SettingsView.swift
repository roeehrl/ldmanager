import LDCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("refreshInterval") private var refreshInterval = 5.0
    @State private var cliStatus = CLIInstaller.status
    @State private var confirmRemoveHelper = false
    @State private var cliError: String?

    var body: some View {
        Form {
            Section("Updates") {
                Picker("Refresh job state every", selection: $refreshInterval) {
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("15 seconds").tag(15.0)
                    Text("1 minute").tag(60.0)
                }
            }
            Section("Privileged helper") {
                HelperFooter()
                if model.helperState == .enabled {
                    Button("Remove Helper…", role: .destructive) { confirmRemoveHelper = true }
                        .confirmationDialog("Remove the privileged helper?", isPresented: $confirmRemoveHelper) {
                            Button("Remove Helper", role: .destructive) { model.uninstallHelper() }
                        } message: {
                            Text("System changes will ask for your password again. You can install it again later, which needs approval in System Settings.")
                        }
                }
                if model.helperDeclined && model.helperState != .enabled {
                    Toggle("Offer the helper when an action needs a password", isOn: Binding(get: { !model.helperDeclined }, set: { model.helperDeclined = !$0 }))
                }
                Text("The helper runs as root and only accepts LD Manager and its ldm tool. It manages system daemons, writes plists in /Library, and reads Login Items without asking for your password each time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Command-line tool") {
                LabeledContent("ldm") {
                    Text(cliStatus.description).foregroundStyle(.secondary)
                }
                HStack {
                    Button(cliStatus.isInstalled ? "Reinstall" : "Install ldm in /usr/local/bin") {
                        model.withPrivilege(true, reason: "Installing ldm in /usr/local/bin needs administrator rights.") {
                            Task {
                                cliError = await Task.detached { CLIInstaller.install() }.value
                                cliStatus = CLIInstaller.status
                            }
                        }
                    }
                    .disabled(CLIInstaller.bundledPath == nil)
                    if CLIInstaller.bundledPath == nil {
                        Text("Not bundled in this build — use `swift build -c release`.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let cliError {
                    Label(cliError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                Text("Links to the copy inside the app, so it updates with the app." + (model.helperState == .enabled ? "" : " Asks for your password."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backups") {
                Button("Show Backups in Finder") {
                    try? FileManager.default.createDirectory(at: PlistEditor.backupRoot, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(PlistEditor.backupRoot)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum CLIInstaller {
    static let linkPath = "/usr/local/bin/ldm"

    static var bundledPath: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ldm").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    enum Status {
        case notInstalled, linked, other(String)
        var isInstalled: Bool { if case .notInstalled = self { false } else { true } }
        var description: String {
            switch self {
            case .notInstalled: "Not installed"
            case .linked: "Installed at \(CLIInstaller.linkPath)"
            case .other(let p): "Another ldm is at \(p)"
            }
        }
    }

    static var status: Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: linkPath) || (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil else { return .notInstalled }
        if let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath), dest == bundledPath { return .linked }
        return .other(linkPath)
    }

    /// nil on success, otherwise what went wrong.
    static func install() -> String? {
        guard let src = bundledPath else { return "This build doesn’t include ldm." }
        do {
            try Privileged.linkCommandLineTool(src)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
