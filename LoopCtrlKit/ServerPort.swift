import Foundation

/// The automation server's TCP port, as chosen in the LoopCtrl app.
///
/// Stored in UserDefaults under one key that the app and the runner both read.
/// In the all-in-one build they are one process, so this is the same setting;
/// in the two-IPA build the runner has its own container, so the app also
/// passes the port on `loopctrl://start?port=…` and the runner stores it.
///
/// The default is not iCTRL's 8200: with both installed, two runners on one
/// port collide, and the one still holding it keeps iOS's "Automation Running"
/// overlay up after LoopCtrl's own server has stopped.
enum ServerPort {
    static let defaultPort: UInt16 = 8300
    static let defaultsKey = "serverPort"
    /// Ports a user may pick. Above 1023 (no privileged ports), and one short
    /// of 65535 because nearby discovery listens on the port above this one.
    static let allowed: ClosedRange<Int> = 1024...65534

    static var stored: UInt16 {
        get {
            let value = UserDefaults.standard.integer(forKey: defaultsKey)
            return allowed.contains(value) ? UInt16(value) : defaultPort
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: defaultsKey) }
    }
}

/// The all-in-one build's direct line from the LoopCtrl screen to the runner
/// in the same process. Notifications on `NotificationCenter.default` can't be
/// posted from another app, unlike `loopctrl://` URLs, so this is safe for
/// settings that widen access; it also needs no pairing, which /rpc does.
enum InProcessRunnerControl {
    /// userInfo["on"]: Bool. Turns remote access on or off.
    static let setRemoteAccess = Notification.Name("LoopCtrlInProcessSetRemoteAccess")
    /// userInfo["on"]: Bool. Turns nearby discovery on or off; on also turns
    /// remote access on, which nearby needs.
    static let setNearby = Notification.Name("LoopCtrlInProcessSetNearby")
    /// The runner's own UserDefaults keys, which this process shares with it.
    static let remoteAccessKey = "allowRemoteAccess"
    static let nearbyKey = "nearbyDiscovery"
}
