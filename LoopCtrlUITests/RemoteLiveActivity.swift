import ActivityKit
import Foundation

/// The Live Activity for remote viewing and control: who is operating, how
/// many watch, and Pause / Resume, on the Lock Screen and in the Dynamic
/// Island (docs/remote-control.md, "Control").
///
/// iOS starts a Live Activity only for an app in the foreground, and remote
/// use begins while the phone is in someone else's hands, so it starts with
/// the service (or when LoopCtrl next comes to the front) and waits idle.
/// Where it can't show (turned off in Settings, iOS before 16.2, the 8-hour
/// limit passed), the runner's notification says the same. Main thread.
final class RemoteLiveActivity {
    static let shared = RemoteLiveActivity()
    var onLog: ((String) -> Void)?

    /// An `Activity<RemoteActivityAttributes>`, kept untyped so the class
    /// itself needs no availability check.
    private var activity: Any?
    private var shown: Any?

    /// Whether the activity is up, so the notification isn't needed as well.
    var isShowing: Bool {
        guard #available(iOS 16.2, *), let a = activity as? Activity<RemoteActivityAttributes> else { return false }
        return a.activityState == .active
    }

    /// Show it, if it isn't already and iOS lets us now.
    func start() {
        guard #available(iOS 16.2, *), !isShowing else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            onLog?("🏝 Live Activities are off for LoopCtrl: the notification shows remote use")
            return
        }
        // One at a time: end any left from an earlier run of the app.
        for old in Activity<RemoteActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        do {
            let state = RemoteActivityAttributes.ContentState.idle
            activity = try Activity.request(attributes: RemoteActivityAttributes(),
                                            content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            shown = state
            onLog?("🏝 Live Activity started")
        } catch {
            onLog?("🏝 Live Activity not started (\(error.localizedDescription)): the notification shows remote use")
        }
    }

    /// Show who is there now. `alert`: light it up with this line (the start
    /// of a spell of remote use), as a notification's banner would. False
    /// when the activity isn't up, so the caller notifies instead.
    @discardableResult
    func show(_ present: [(participant: RemoteSession.Participant, operating: Bool)], paused: Bool,
              since: Date?, alert: String?) -> Bool {
        guard #available(iOS 16.2, *), isShowing, let a = activity as? Activity<RemoteActivityAttributes> else { return false }
        let operators = present.filter(\.operating).map(\.participant)
        let state = RemoteActivityAttributes.ContentState(
            paused: paused,
            operators: operators.prefix(3).map { .init(name: $0.name, agent: $0.kind == .agent) },
            operatorCount: operators.count,
            watchers: present.filter { $0.participant.watching > 0 }.count,
            since: present.isEmpty && !paused ? nil : since)
        if state == shown as? RemoteActivityAttributes.ContentState, alert == nil { return true }
        shown = state
        let alerting = alert.map {
            AlertConfiguration(title: "LoopCtrl", body: LocalizedStringResource(stringLiteral: $0), sound: .default)
        }
        Task { await a.update(ActivityContent(state: state, staleDate: nil), alertConfiguration: alerting) }
        return true
    }

    /// The service stopped.
    func end() {
        guard #available(iOS 16.2, *), let a = activity as? Activity<RemoteActivityAttributes> else { return }
        activity = nil
        shown = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
        onLog?("🏝 Live Activity ended")
    }
}
