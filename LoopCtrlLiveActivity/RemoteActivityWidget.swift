import ActivityKit
import SwiftUI
import WidgetKit

/// The extension targets iOS 16.2, the first with this Live Activity API; on
/// older systems the runner keeps using notifications.
@main
struct LoopCtrlWidgets: WidgetBundle {
    var body: some Widget {
        RemoteActivityWidget()
    }
}

/// The phone's language, as the runner's own string tables choose it.
private let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
private func tr(_ en: String, _ zhs: String) -> String { zh ? zhs : en }

@available(iOS 16.2, *)
private extension RemoteActivityAttributes.ContentState {
    var nobody: Bool { operatorCount == 0 && watchers == 0 }

    var names: String {
        let shown = operators.map { ($0.agent ? "🤖 " : "") + $0.name }.joined(separator: tr(", ", "、"))
        let more = operatorCount - operators.count
        return more > 0 ? shown + tr(" and \(more) more", " 等 \(operatorCount) 人") : shown
    }

    var title: String {
        if paused { return tr("Remote control paused", "远程控制已暂停") }
        if operatorCount > 0 { return tr("\(names) operating", "\(names) 正在操控") }
        if watchers > 0 { return tr("Being viewed remotely", "正在被远程查看") }
        return tr("Remote control is on", "远程控制已开启")
    }

    var detail: String {
        if paused { return tr("No one can see or touch the screen remotely.", "远程看不到画面，也不能操作。") }
        if nobody { return tr("No one is watching", "没有人在查看") }
        return tr("\(watchers) watching", "\(watchers) 人在查看")
    }

    var symbol: String {
        paused ? "pause.circle.fill" : operatorCount > 0 ? "hand.tap.fill" : watchers > 0 ? "eye.fill" : "antenna.radiowaves.left.and.right"
    }

    var tint: Color {
        paused ? .orange : operatorCount > 0 ? .red : watchers > 0 ? .blue : .secondary
    }
}

@available(iOS 16.2, *)
struct RemoteActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol)
                        .font(.title2)
                        .foregroundStyle(state.tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let since = state.since {
                        Text(since, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 64)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        PauseButton(paused: state.paused, hidden: state.nobody && !state.paused)
                    }
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            } compactTrailing: {
                if state.paused {
                    Image(systemName: "pause.fill").foregroundStyle(.orange)
                } else if !state.nobody {
                    Text("\(max(state.operatorCount, state.watchers))").monospacedDigit()
                }
            } minimal: {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
            }
        }
    }
}

@available(iOS 16.2, *)
private struct LockScreenView: View {
    let state: RemoteActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbol)
                .font(.title2)
                .foregroundStyle(state.tint)
                .frame(width: 44, height: 44)
                .background(state.tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    Text(state.detail)
                    if let since = state.since, !state.paused {
                        Text("·")
                        Text(since, style: .timer).monospacedDigit()
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            PauseButton(paused: state.paused, hidden: state.nobody && !state.paused)
        }
    }
}

/// Pause while anyone is there, Resume once paused. The buttons need iOS 17;
/// before that the notification's own buttons do the same.
@available(iOS 16.2, *)
private struct PauseButton: View {
    let paused: Bool
    let hidden: Bool

    var body: some View {
        if #available(iOS 17.0, *), !hidden {
            if paused {
                Button(intent: ResumeRemoteIntent()) {
                    Label(tr("Resume", "继续"), systemImage: "play.fill")
                }
                .tint(.green)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            } else {
                Button(intent: PauseRemoteIntent()) {
                    Label(tr("Pause", "暂停"), systemImage: "pause.fill")
                }
                .tint(.orange)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
        }
    }
}
