import Foundation

/// The automation server's TCP port, as chosen in the LoopCtrl app.
///
/// Stored in UserDefaults under one key that the app and the runner both read.
/// In the all-in-one build they are one process, so this is the same setting;
/// in the two-IPA build the runner has its own container, so the app also
/// passes the port on `loopctrl://start?port=…` and the runner stores it.
///
/// The default stays off 8200, which other XCUITest-based runners commonly use:
/// two runners on one port collide, and the one still holding it keeps iOS's
/// "Automation Running" overlay up after LoopCtrl's own server has stopped.
enum ServerPort {
    static let defaultPort: UInt16 = 8300
    static let defaultsKey = "serverPort"
    /// Ports a user may pick. Above 1023 (no privileged ports), and two short
    /// of 65535: nearby discovery listens on the port above this one, and
    /// relayed requests arrive on loopback two above it.
    static let allowed: ClosedRange<Int> = 1024...65533

    /// The loopback port relayed requests arrive on (docs/remote-control.md).
    static func relayIngress(for port: UInt16) -> UInt16 { port &+ 2 }

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
    /// An admin call (`rpcMethods` only) answered by the runner without a key:
    /// the app and the runner are one process, so pairing the app with its own
    /// runner proved nothing and only stalled on an approval nobody saw.
    /// userInfo: "method": String, "params": Data (JSON object), and
    /// "reply": (Data?, String?) -> Void — the JSON result, or an error message
    /// (`notRunningError` when no server is up).
    static let rpc = Notification.Name("LoopCtrlInProcessRPC")
    static let rpcMethods: Set<String> = ["config", "logs"]
    static let notRunningError = "not-running"
    /// The runner's own UserDefaults keys, which this process shares with it.
    static let remoteAccessKey = "allowRemoteAccess"
    static let nearbyKey = "nearbyDiscovery"
}
