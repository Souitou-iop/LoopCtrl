import Foundation
import Network
import UIKit

/// The app that makes this device's debug service routable at 10.7.0.1, so
/// the DDI mount can reach it.
///
/// Either works, because the mount only cares that 10.7.0.1:49152 answers:
///  * LocalDevVPN — a VPN that does only this. Registers `localdevvpn://` with
///    a callback scheme, so we can send the user into "connect" and get them back.
///  * Shadowrocket — with Settings › Other › "Include Route 10.7.0.1/32" on, its
///    own tunnel loops 10.7.0.1 back to this device, so the user keeps their
///    proxy instead of swapping VPNs. `shadowrocket://connect` starts it, but it
///    does not return here on its own.
enum TunnelApp: String, CaseIterable, Identifiable {
    case localDevVPN
    case shadowrocket

    var id: String { rawValue }

    private static let defaultsKey = "ddi.tunnelApp"

    static var selected: TunnelApp {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(TunnelApp.init) ?? .localDevVPN }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var displayName: String {
        switch self {
        case .localDevVPN: return "LocalDevVPN"
        case .shadowrocket: return "Shadowrocket"
        }
    }

    /// Bare scheme, used only as a `canOpenURL:` probe; neither app acts on it.
    /// Each scheme must be in `LSApplicationQueriesSchemes`, or iOS answers
    /// `false` whatever is installed and every user is sent to the App Store.
    private var probeURL: URL {
        switch self {
        case .localDevVPN: return URL(string: "localdevvpn://")!
        case .shadowrocket: return URL(string: "shadowrocket://")!
        }
    }

    /// Starts the tunnel. LocalDevVPN then returns to `ictrl-app://`.
    var connectURL: URL {
        switch self {
        case .localDevVPN: return URL(string: "localdevvpn://enable?scheme=ictrl-app")!
        case .shadowrocket: return URL(string: "shadowrocket://connect")!
        }
    }

    var appStoreURL: URL {
        switch self {
        case .localDevVPN: return URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!
        case .shadowrocket: return URL(string: "https://apps.apple.com/app/shadowrocket/id932747118")!
        }
    }

    @MainActor
    var isInstalled: Bool {
        UIApplication.shared.canOpenURL(probeURL)
    }
}

enum LocalDevVPN {

    enum TunnelProbe: Equatable {
        /// The device's own service answered through the tunnel.
        case reachable
        /// iOS refused the connection: Local Network access is off for iCTRL.
        case localNetworkDenied
        /// Something accepted the connection but never spoke RemotePairing — a
        /// proxy's tunnel answering for an address it doesn't route back here
        /// (Shadowrocket without "Include Route 10.7.0.1/32", in global mode).
        case notDevice
        /// Nothing answered (tunnel down, or set to other addresses).
        case unreachable(String)
    }

    /// The opening of an RPPairing handshake: the `RPPairing` magic, a
    /// big-endian length, then the JSON envelope idevice sends first. `remoted`
    /// answers it with a frame starting with the same magic, without any
    /// pairing keys involved; the connection is then dropped unfinished.
    private static let handshake: Data = {
        let json = #"{"message":{"plain":{"_0":{"request":{"_0":{"handshake":{"_0":{"hostOptions":{"attemptPairVerify":true},"wireProtocolVersion":19}}}}}}},"originatedBy":"host","sequenceNumber":0}"#
        let body = Data(json.utf8)
        var frame = Data("RPPairing".utf8)
        frame.append(UInt8(body.count >> 8))
        frame.append(UInt8(body.count & 0xff))
        frame.append(body)
        return frame
    }()

    /// Whether the tunnel actually works: a connection to the service the mount
    /// talks to, that answers like that service.
    ///
    /// Not "is there a 10.7.0.x address": LocalDevVPN's addresses are
    /// user-configurable, another VPN can use the same range, and another
    /// app's tunnel interface is not always listed. And not a bare TCP connect
    /// either: a proxy's tunnel (Shadowrocket's, for one) completes the TCP
    /// handshake itself for any address it captures, whether or not it can
    /// reach it. So the probe starts an RPPairing handshake and wants the
    /// `RPPairing` magic back.
    static func probeTunnel(timeout: TimeInterval = 2.5) async -> TunnelProbe {
        let host = NWEndpoint.Host(DDIMounter.tunnelAddress)
        guard let port = NWEndpoint.Port(rawValue: DDIMounter.tunnelPort) else { return .unreachable("bad port") }
        let conn = NWConnection(host: host, port: port, using: .tcp)
        let queue = DispatchQueue(label: "ictrl.tunnel.probe")
        let magic = Data("RPPairing".utf8)
        let result: TunnelProbe = await withCheckedContinuation { cont in
            var done = false
            func finish(_ r: TunnelProbe) {
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: handshake, completion: .contentProcessed { error in
                        if error != nil { finish(.notDevice) }
                    })
                    conn.receive(minimumIncompleteLength: magic.count, maximumLength: 4096) { data, _, _, _ in
                        finish(data?.prefix(magic.count) == magic ? .reachable : .notDevice)
                    }
                case .waiting(let err), .failed(let err):
                    if #available(iOS 14.2, *), conn.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        finish(.localNetworkDenied)
                    } else if case .waiting = state {
                        // Keep waiting: a refused connect retries until the timeout.
                        _ = err
                    } else {
                        finish(.unreachable(err.localizedDescription))
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if #available(iOS 14.2, *), conn.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    finish(.localNetworkDenied)
                } else if conn.state == .ready {
                    // Connected, but no RemotePairing reply in time.
                    finish(.notDevice)
                } else {
                    finish(.unreachable("no answer in \(timeout)s"))
                }
            }
        }
        ictrlLog("Tunnel probe \(DDIMounter.tunnelAddress):\(DDIMounter.tunnelPort) → \(result); interfaces: \(interfaceSummary())")
        return result
    }

    /// Every IPv4 address on an up interface, as "name address" — for the log
    /// and the screen when the tunnel can't be found.
    static func interfaceSummary() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "unavailable" }
        defer { freeifaddrs(head) }
        var out: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            if name == "lo0" { continue }
            out.append("\(name) \(String(cString: host))")
        }
        return out.isEmpty ? "none" : out.joined(separator: ", ")
    }
}
