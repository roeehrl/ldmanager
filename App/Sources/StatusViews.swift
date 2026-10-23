import LDCore
import SwiftUI

/// Status is always shape plus color, never color alone.
struct StatusGlyph: View {
    let status: JobStatus
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size + 6)
            .help(status.title)
            .accessibilityLabel(status.title)
    }

    var symbol: String {
        switch status {
        case .running: "circle.fill"
        case .idle: "circle"
        case .failed: "exclamationmark.triangle.fill"
        case .disabled: "pause.circle"
        case .notLoaded: "circle.dashed"
        case .invalid: "questionmark.diamond.fill"
        }
    }

    var color: Color {
        switch status {
        case .running: .green
        case .idle, .disabled, .notLoaded: .secondary
        case .failed: .orange
        case .invalid: .purple
        }
    }
}

struct CheckMark: View {
    let passed: Bool?

    var body: some View {
        Image(systemName: passed == true ? "checkmark.circle.fill" : passed == false ? "xmark.circle.fill" : "minus.circle")
            .foregroundStyle(passed == true ? .green : passed == false ? .orange : .secondary)
            .accessibilityLabel(passed == true ? "Pass" : passed == false ? "Fail" : "Skipped")
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct Chip: View {
    let text: String
    var mono = false
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(mono ? .caption.monospaced() : .caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(tint == .secondary ? Color.primary.opacity(0.75) : tint)
    }
}

extension Job {
    var resultColor: Color {
        switch status {
        case .failed: .orange
        case .invalid: .purple
        default: .secondary
        }
    }
}
