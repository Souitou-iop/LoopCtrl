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

    private var server: JSONRPCServer?

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

            // Two addresses a client cannot use: link-local (no DHCP — Wi-Fi is
            // associated but the network gave nothing) and the benchmark range a
            // proxy or fake-IP setup parks on an interface. Both look like a
            // usable host and reach nobody; the runner's own list leaves them out
            // the same way (LoopCtrlUITests `allReachableAddresses`).
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard ip & 0xFFFF_0000 != 0xA9FE_0000,       // 169.254.0.0/16
                  ip & 0xFFFE_0000 != 0xC612_0000,       // 198.18.0.0/15
                  ip != 0 else { continue }

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
