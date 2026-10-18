import SwiftUI
import Network

class AppState: ObservableObject {
    @Published var isServerRunning = false
    @Published var sessions: [AuthSession] = []
    @Published var pendingAuthRequest: PendingAuth?
    @Published var serverAddress: String = "—"
    @Published var serverError: String?

    @AppStorage("autoStartServer") var autoStartServer = false
    @AppStorage(ServerPort.defaultsKey) var serverPort = Int(ServerPort.defaultPort)
    @AppStorage("allowRemoteAccess") var allowRemoteAccess = false
    /// Phase 0 relay enrollment. The base URL and optional expected device id
    /// are non-secret settings; the enrollment token is Debug-only and local.
    @AppStorage("relayBaseURL") var relayBaseURL = ""
    @AppStorage("relayExpectedDeviceID") var relayExpectedDeviceID = ""
    #if DEBUG
    @AppStorage("relayEnrollmentToken") var relayEnrollmentToken = ""
    #endif

    private var server: JSONRPCServer?
    private var relay: RelayRPCClient?
    /// The all-in-one runner owns the real /rpc implementation in this process.
    /// In the two-app build AppState's own server is only a local endpoint, so
    /// a relay session must not advertise it as a working LoopCtrl.
    private var relayEligible: Bool {
        #if LOOPCTRL_ALL_IN_ONE
        return true
        #else
        return false
        #endif
    }

    struct PendingAuth: Identifiable {
        let id = UUID()
        let clientName: String
        let completion: (Bool) -> Void
    }

    init() {
        AuthManager.shared.delegate = self
        updateServerAddress()

        if autoStartServer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startServer()
            }
        }
        // In the all-in-one build the in-process runner, not AppState's own
        // server, answers /rpc on the server port, and the runner's Start
        // button never goes through startServer(). The relay only forwards to
        // 127.0.0.1, so it can run on its own from launch; a call that arrives
        // before Start answers a generic 502.
        if relayEligible { startRelayIfConfigured() }
    }

    func startServer() {
        guard !isServerRunning else { return }

        let s = JSONRPCServer(port: UInt16(serverPort), localOnly: !allowRemoteAccess)
        server = s

        s.onStateChange = { [weak self] running in
            DispatchQueue.main.async {
                self?.isServerRunning = running
                if running {
                    self?.serverError = nil
                    self?.updateServerAddress()
                }
            }
        }

        s.onRPCRequest = { method, params, completion in
            completion(nil, .serverError("RPC not available in app mode. Use the UITest runner for automation."))
        }

        do {
            try s.start()
            serverError = nil
        } catch {
            print("🔴 Failed to start server: \(error)")
            serverError = error.localizedDescription
            isServerRunning = false
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        isServerRunning = false
    }

    /// Phase 0 is deliberately opt-in: the relay starts only when the base URL,
    /// enrollment token, and (implicitly) the fixed server port are present.
    /// The token is an ad-hoc Debug value, never a Release build setting.
    private func startRelayIfConfigured() {
        relay?.stop()
        relay = nil
        #if DEBUG
        let token = relayEnrollmentToken
        #else
        let token = ""
        #endif
        guard let enrollment = Self.relayEnrollment(
            baseURL: relayBaseURL,
            token: token,
            expectedDeviceID: relayExpectedDeviceID
        ) else {
            return
        }
        let client = RelayRPCClient(configuration: .init(
            enrollment: enrollment,
            rpcPort: UInt16(serverPort)
        ))
        client.onLog = { message in loopctrlLog("Relay: \(message)") }
        client.onState = { state in
            loopctrlLog("Relay state: \(state)")
        }
        relay = client
        client.start()
    }

    #if DEBUG
    /// Debug-only enrollment for device tests, so a relay URL and a single-use
    /// enrollment token can be set without UI:
    ///
    ///     loopctrl-app://relay-debug?url=https://relay.example&token=<enrollment>
    ///     loopctrl-app://relay-debug?clear=1
    ///
    /// Release builds compile none of this and never read a token. The token
    /// is never logged.
    func handleRelayDebugURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "loopctrl-app",
              url.host?.lowercased() == "relay-debug",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if value("clear") != nil {
            relay?.stop()
            relay = nil
            relayBaseURL = ""
            relayEnrollmentToken = ""
            relayExpectedDeviceID = ""
            loopctrlLog("Relay debug: enrollment cleared")
            return true
        }
        if let base = value("url") { relayBaseURL = base }
        if let token = value("token") { relayEnrollmentToken = token }
        relayExpectedDeviceID = value("device") ?? ""
        guard relayEligible else {
            loopctrlLog("Relay debug: saved, but only the all-in-one build runs the relay")
            return true
        }
        if Self.relayEnrollment(baseURL: relayBaseURL, token: relayEnrollmentToken,
                                expectedDeviceID: relayExpectedDeviceID) == nil {
            loopctrlLog("Relay debug: enrollment rejected (https origin and a well-formed token are required)")
            return true
        }
        loopctrlLog("Relay debug: enrollment set for \(relayBaseURL); starting relay")
        startRelayIfConfigured()
        return true
    }
    #endif

    static func relayEnrollment(
        baseURL rawBaseURL: String,
        token: String,
        expectedDeviceID: String
    ) -> RelayEnrollment? {
        guard let url = URL(string: rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let expected = expectedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? RelayEnrollment(
            baseURL: url,
            token: token,
            expectedDeviceID: expected.isEmpty ? nil : expected
        )
    }

    func refreshSessions() {
        sessions = AuthManager.shared.activeSessions
    }

    func revokeSession(id: String) {
        AuthManager.shared.revokeSession(id: id)
        refreshSessions()
    }

    func revokeAllSessions() {
        AuthManager.shared.revokeAll()
        refreshSessions()
    }

    func updateServerAddress() {
        let ip = allowRemoteAccess ? (Self.wifiAddress() ?? "127.0.0.1") : "127.0.0.1"
        serverAddress = "\(ip):\(serverPort)"
    }

    /// This device's Wi-Fi (en0) IPv4 address; nil off Wi-Fi.
    static func wifiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            // ifa_addr may be NULL for an interface without an address.
            guard let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            address = String(cString: hostname)
        }

        return address
    }
}

extension AppState: AuthManagerDelegate {
    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String, requestID: String,
                     nearby: Bool, fingerprint: String?, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.pendingAuthRequest = PendingAuth(clientName: clientName, completion: completion)
        }
    }

    func authManager(_ manager: AuthManager, didExpireAuthRequest clientName: String, requestID: String) {
        DispatchQueue.main.async {
            if self.pendingAuthRequest?.clientName == clientName { self.pendingAuthRequest = nil }
        }
    }
}
