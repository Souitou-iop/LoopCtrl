import AppIntents
import Foundation

/// Pause and Resume on the remote-control Live Activity. A LiveActivityIntent
/// runs in the app's process, where the in-process runner keeps the remote
/// session; it reaches it by an in-process notification (see
/// RemoteActivityRequest in LoopCtrlLiveActivity/RemoteActivityAttributes.swift,
/// which this file can't see: the app target doesn't build ActivityKit types).
private let pauseRequest = Notification.Name("LoopCtrlRemotePauseRequest")

@available(iOS 17.0, *)
struct PauseRemoteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause Remote Control"
    static var description = IntentDescription("Stops remote viewing and control until you resume it.")
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: pauseRequest, object: nil, userInfo: ["paused": true])
        return .result()
    }
}

/// Resuming lets people see and touch the phone again: only for whoever can
/// unlock it, as with the notification's Resume.
@available(iOS 17.0, *)
struct ResumeRemoteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume Remote Control"
    static var description = IntentDescription("Lets remote viewing and control go on.")
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: pauseRequest, object: nil, userInfo: ["paused": false])
        return .result()
    }
}
