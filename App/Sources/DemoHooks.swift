import AppKit
import LDCore
import SwiftUI

/// Launch arguments that put the app into one state without clicks, for the scripted
/// screenshots and videos in `demo/`. They do nothing unless passed, e.g.
///
///     open -a "LD Manager" --args -demoSidebar problems -demoSelect com.example.report
///
/// - `-demoAppearance light|dark`
/// - `-demoSidebar user|allUsers|system|apple|problems|recent`
/// - `-demoSelect <label>`: the job (or problem) to select
/// - `-demoInspector NO`: hide the inspector
/// - `-demoEdit <label>`: open the editor on that job, with optional unsaved changes:
///   `-demoEditProgram <path>`, `-demoEditEvery <minutes>`, `-demoEditMode Form|Keys|XML`
/// - `-demoWindow <width>x<height>`: size of the main window in points, centred; its frame is
///   written to `/tmp/ldm-demo-frame`
enum DemoHooks {
    private static let d = UserDefaults.standard
    private static var applied = false

    @MainActor static func apply(to model: AppModel) {
        guard !applied, model.hasLoaded else { return }
        applied = true
        switch d.string(forKey: "demoAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let s = d.string(forKey: "demoSidebar") {
            switch s {
            case "problems": model.sidebar = .problems
            case "recent": model.sidebar = .recent
            case "apple": model.sidebar = .apple
            default: if let scope = JobScope(rawValue: s) { model.sidebar = .scope(scope) }
            }
        }
        if d.object(forKey: "demoInspector") != nil { model.showInspector = d.bool(forKey: "demoInspector") }
        if let label = d.string(forKey: "demoSelect"), let job = model.jobs.first(where: { $0.label == label }) {
            if model.sidebar == .problems { model.selectedProblemID = job.id } else { model.selectedJobID = job.id }
        }
        if let label = d.string(forKey: "demoEdit"), let job = model.jobs.first(where: { $0.label == label }) {
            model.editorTarget = .edit(job)
        }
        if let size = d.string(forKey: "demoWindow")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "LD Manager" || $0.isMainWindow }),
                      let screen = window.screen?.visibleFrame else { return }
                let frame = NSRect(x: screen.midX - size[0] / 2, y: screen.midY - size[1] / 2, width: size[0], height: size[1])
                window.setFrame(frame, display: true)
                // Where the window is, top-left origin in points, for demo/capture.sh to crop.
                let top = (NSScreen.screens.first?.frame.height ?? 0) - frame.maxY
                try? "\(Int(frame.minX)) \(Int(top)) \(Int(frame.width)) \(Int(frame.height))\n"
                    .write(toFile: "/tmp/ldm-demo-frame", atomically: true, encoding: .utf8)
            }
        }
    }

    /// Unsaved changes for the editor opened by `-demoEdit`.
    @MainActor static func prepare(_ draft: EditorDraft) {
        guard let label = d.string(forKey: "demoEdit"), draft.job?.label == label else { return }
        if let p = d.string(forKey: "demoEditProgram") { draft.program = p }
        let every = d.integer(forKey: "demoEditEvery")
        if every > 0 {
            draft.trigger = .every
            if every % 60 == 0 { draft.intervalValue = every / 60; draft.intervalUnit = .hours } else { draft.intervalValue = every; draft.intervalUnit = .minutes }
        }
        if let m = d.string(forKey: "demoEditMode"), let mode = EditorMode(rawValue: m) { draft.mode = mode }
    }
}
