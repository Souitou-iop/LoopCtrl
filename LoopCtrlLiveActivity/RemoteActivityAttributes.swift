import ActivityKit
import Foundation

/// The Live Activity that shows who is watching and operating the phone
/// remotely (docs/remote-control.md, "Control"). Shared by the runner, which
/// starts and updates it, and the widget extension, which draws it.
@available(iOS 16.2, *)
struct RemoteActivityAttributes: ActivityAttributes {
    struct Person: Codable, Hashable {
        var name: String
        var agent: Bool
    }

    struct ContentState: Codable, Hashable {
        var paused: Bool
        /// The first few operating, in the order they came.
        var operators: [Person]
        var operatorCount: Int
        var watchers: Int
        /// When this spell of remote use began; nil while nobody is there.
        var since: Date?

        static let idle = ContentState(paused: false, operators: [], operatorCount: 0, watchers: 0, since: nil)
    }
}

/// What the Live Activity's Pause and Resume buttons post. Their intents run
/// in the app's process, where the in-process runner listens; the app and
/// the runner's test bundle each compile their own copy of LoopCtrlKit, so a
/// notification is how one reaches the other's RemoteSession. The name is
/// repeated in LoopCtrlApp/LiveActivity/RemoteActivityIntents.swift.
enum RemoteActivityRequest {
    static let pause = Notification.Name("LoopCtrlRemotePauseRequest")
}
