import SwiftUI
import UIKit

/// Small building blocks shared by the Settings sheet and the setup flow, in
/// the same visual language as the home screen (see Style.swift).

/// A capsule with a coloured dot (or a spinner) and a short state, e.g.
/// "Running · 127.0.0.1:8300" or "Not connected".
struct StateChip: View {
    enum Tone { case good, warning, idle, busy, bad }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            if tone == .busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(tone == .idle || tone == .busy ? .secondary : color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        case .idle, .busy: return .secondary
        }
    }
}

/// A circular progress track, filled clockwise from the top.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 4
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.35), value: fraction)
    }
}

/// A list row: symbol, title, and a right-aligned value.
struct ValueRow: View {
    let title: String
    let systemImage: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// An address clients connect to, with a copy button; nil when there is none.
struct CopyRow: View {
    let title: String
    let systemImage: String
    let value: String?
    var placeholder: String = ""
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 8)
            if let value {
                Text(verbatim: value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 20)
                }
                // .borderless keeps the tap on the button, not the whole row.
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? L10n.ui(.copied) : value)
            } else {
                Text(placeholder).foregroundColor(.secondary)
            }
        }
    }
}

/// An app worth having alongside LoopCtrl: name, why, and a button opening it.
struct AppLinkRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let actionTitle: String
    let url: URL
    /// Opened when `url` uses a custom scheme and the app isn't installed.
    var fallbackURL: URL? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(actionTitle) {
                UIApplication.shared.open(url) { ok in
                    // A custom-scheme open fails when that app isn't installed;
                    // its download page turns a dead tap into a way forward.
                    guard !ok, let fallbackURL else { return }
                    UIApplication.shared.open(fallbackURL)
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
    }
}

/// A warning or error line: orange, with a triangle.
struct NoticeLabel: View {
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote)
        .foregroundColor(.orange)
    }
}
