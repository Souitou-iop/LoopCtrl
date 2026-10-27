import Foundation

/// One message of the relay tunnel (docs/remote-control.md, "Tunnel protocol"):
/// `type u8 | stream u32 (big-endian) | payload`.
struct TunnelFrame: Equatable {
    enum Kind: UInt8 {
        case open = 1, data = 2, end = 3, reset = 4, window = 5
    }

    static let maxData = 32 * 1024
    static let initialWindow = 256 * 1024

    let kind: Kind
    let stream: UInt32
    let payload: Data

    init(_ kind: Kind, stream: UInt32, payload: Data = Data()) {
        self.kind = kind
        self.stream = stream
        self.payload = payload
    }

    static func window(_ stream: UInt32, _ bytes: Int) -> TunnelFrame {
        var be = UInt32(clamping: bytes).bigEndian
        return TunnelFrame(.window, stream: stream, payload: Data(bytes: &be, count: 4))
    }

    var encoded: Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(kind.rawValue)
        var be = stream.bigEndian
        out.append(Data(bytes: &be, count: 4))
        out.append(payload)
        return out
    }

    /// nil for a message too short or of a type this side doesn't know.
    init?(decoding data: Data) {
        let b = [UInt8](data.prefix(5))
        guard b.count == 5, let kind = Kind(rawValue: b[0]) else { return nil }
        self.kind = kind
        self.stream = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
        self.payload = data.count > 5 ? data.subdata(in: data.startIndex + 5..<data.endIndex) : Data()
    }

    /// The credit a WINDOW message grants, or nil.
    var windowCredit: Int? {
        guard kind == .window, payload.count == 4 else { return nil }
        let b = [UInt8](payload)
        return Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }
}

/// Turns the relay's OPEN into the HTTP/1.1 request the runner's relay
/// ingress gets. The relay is untrusted: anything that could break out of a
/// header (CR, LF, NUL) or claim to be one of the phone's own relay headers
/// is refused or dropped here.
enum TunnelRequest {
    struct Open: Decodable {
        let method: String
        let path: String
        let headers: [[String]]
        let peer: String?
    }

    /// Headers that describe the relay's hop, not the request.
    private static let dropped: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "host",
    ]

    private static let tokenCharacters = CharacterSet(charactersIn:
        "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func head(_ open: Open, connectionID: String, server: String) -> Data? {
        guard !open.method.isEmpty, open.method.unicodeScalars.allSatisfy(tokenCharacters.contains),
              open.path.hasPrefix("/"), isClean(open.path), !open.path.contains(" ") else { return nil }
        var lines = ["\(open.method) \(open.path) HTTP/1.1", "Host: 127.0.0.1"]
        for pair in open.headers {
            guard pair.count == 2 else { return nil }
            let name = pair[0], value = pair[1]
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(tokenCharacters.contains), isClean(value) else {
                return nil
            }
            let lower = name.lowercased()
            if dropped.contains(lower) || lower.hasPrefix("x-loopctrl-relay") { continue }
            lines.append("\(name): \(value)")
        }
        let peer = open.peer.flatMap { isClean($0) ? $0 : nil } ?? ""
        guard isClean(connectionID), isClean(server) else { return nil }
        lines.append("X-LoopCtrl-Relay-Connection: \(connectionID)")
        lines.append("X-LoopCtrl-Relay-Server: \(server)")
        lines.append("X-LoopCtrl-Relay-Peer: \(peer)")
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private static func isClean(_ s: String) -> Bool {
        !s.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
    }
}
