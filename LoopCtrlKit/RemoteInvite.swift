import Foundation

/// A connection invite for a remote service (docs/relay-enrollment.md): which
/// relay to enrol with, the one-time code that pays for it, and — when the
/// invite came as a link or QR code — the operators allowed to control this
/// phone through it.
///
/// Two forms are recognised:
///
/// - the link, `loopctrl://connect?v=1&server=<host[/path]>&code=<8 chars>&op=<keyID,…>&pin=<spki>&exp=<unix>`;
/// - the text a person pastes, e.g.
///   「LoopCtrl 连接邀请 · 服务器 relay.example.com · 连接码 7K3M-9QX2 · 10 分钟内有效」,
///   which carries no `op` (the operators then have to be checked by eye and
///   approved on first use, nothing is pre-approved).
///
/// No server is built in: `server` is whatever the invite names, our hosted
/// service or a customer's own relay, and both go through the same checks.
struct RemoteInvite: Equatable {
    static let scheme = "loopctrl"
    static let host = "connect"
    static let currentVersion = 1
    /// Crockford base32: no I, L, O or U, so a code read aloud or retyped
    /// survives. `normalizeCode` maps the look-alikes back.
    static let codeAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let codeLength = 8

    let version: Int
    /// `https://host[:port][/path]`. `http` only for loopback in a debug
    /// build. A path is a relay mounted under a reverse-proxy location.
    let serverURL: URL
    /// Eight characters of `codeAlphabet`, no separator.
    let code: String
    /// Full SHA-256 of each operator's X25519 public key, lower-case hex —
    /// the `keyID` the runner binds approvals to (`PairRequestLedger`). Empty
    /// when the invite did not say (the text form).
    let operatorKeyIDs: [String]
    /// SHA-256 of the relay certificate's SubjectPublicKeyInfo, if the invite
    /// pins one.
    let spkiPin: Data?
    /// When the code stops working, if the invite says.
    let expiresAt: Date?

    /// "relay.example.com", "relay.example.com:8443" or "example.com/relay".
    var serverDisplay: String { Self.serverName(serverURL) }

    /// How a relay is named on screen, in invites and in the signatures the
    /// phone makes for it (docs/relay-enrollment.md): `host[:port][/path]`,
    /// no scheme, lower-case host, no trailing slash.
    static func serverName(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        let shown = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let path = url.path == "/" ? "" : url.path
        return (url.port.map { "\(shown):\($0)" } ?? shown) + path
    }

    /// "7K3M-9QX2".
    var displayCode: String { Self.displayCode(code) }

    var isHTTPS: Bool { serverURL.scheme == "https" }

    static func displayCode(_ code: String) -> String {
        guard code.count == codeLength else { return code }
        return "\(code.prefix(4))-\(code.suffix(4))"
    }

    /// The link form of this invite.
    var link: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = Self.host
        var items = [URLQueryItem(name: "v", value: String(version)),
                     URLQueryItem(name: "server", value: isHTTPS ? serverDisplay : serverURL.absoluteString),
                     URLQueryItem(name: "code", value: code)]
        if !operatorKeyIDs.isEmpty {
            items.append(URLQueryItem(name: "op", value: operatorKeyIDs.joined(separator: ",")))
        }
        if let spkiPin { items.append(URLQueryItem(name: "pin", value: Self.base64url(spkiPin))) }
        if let expiresAt { items.append(URLQueryItem(name: "exp", value: String(Int(expiresAt.timeIntervalSince1970)))) }
        c.queryItems = items
        return c.url!
    }

    enum ParseError: Error, Equatable {
        /// Nothing in the text looks like an invite.
        case notAnInvite
        case unsupportedVersion(Int)
        case missingServer
        case invalidServer
        /// `http://` to anything but loopback in a debug build.
        case insecureServer
        case missingCode
        case invalidCode
        /// An `op` entry is not 64 hex characters (the 8-hex fingerprint shown
        /// on screen is too short to bind anything to).
        case invalidOperator
        case invalidPin
        case expired
    }

    // MARK: - Parsing

    /// Parse whatever the user pasted, scanned or typed: a link, a link inside
    /// other text, or the human-readable form.
    /// `allowInsecureLoopback`: accept `http://localhost`/`127.0.0.1`/`[::1]`
    /// (the app passes true in DEBUG builds only).
    static func parse(_ text: String, now: Date = Date(), allowInsecureLoopback: Bool = false) throws -> RemoteInvite {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = firstLink(in: trimmed) {
            return try parseLink(link, now: now, allowInsecureLoopback: allowInsecureLoopback)
        }
        return try parseText(trimmed, now: now, allowInsecureLoopback: allowInsecureLoopback)
    }

    /// The server address and code a person typed in.
    static func manual(server: String, code: String, now: Date = Date(),
                       allowInsecureLoopback: Bool = false) throws -> RemoteInvite {
        guard !server.trimmingCharacters(in: .whitespaces).isEmpty else { throw ParseError.missingServer }
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { throw ParseError.missingCode }
        return try make(version: currentVersion, server: server, code: code, op: nil, pin: nil, exp: nil,
                        now: now, allowInsecureLoopback: allowInsecureLoopback)
    }

    private static func firstLink(in text: String) -> URLComponents? {
        let pattern = #"(?i)loopctrl(?:-app)?://connect\?[^\s「」<>"']+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URLComponents(string: String(text[range]))
    }

    static func parseLink(_ url: URL, now: Date = Date(), allowInsecureLoopback: Bool = false) throws -> RemoteInvite {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ParseError.notAnInvite }
        return try parseLink(c, now: now, allowInsecureLoopback: allowInsecureLoopback)
    }

    /// Whether `url` is an invite link at all (so the app can route it).
    static func isInviteLink(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == Self.scheme || scheme == "loopctrl-app") && url.host?.lowercased() == Self.host
    }

    private static func parseLink(_ c: URLComponents, now: Date, allowInsecureLoopback: Bool) throws -> RemoteInvite {
        let scheme = c.scheme?.lowercased()
        guard scheme == Self.scheme || scheme == "loopctrl-app", c.host?.lowercased() == Self.host else {
            throw ParseError.notAnInvite
        }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] where q[item.name] == nil {
            q[item.name] = item.value ?? ""
        }
        let version = q["v"].flatMap { Int($0) } ?? currentVersion
        guard version == currentVersion else { throw ParseError.unsupportedVersion(version) }
        guard let server = q["server"], !server.isEmpty else { throw ParseError.missingServer }
        guard let code = q["code"], !code.isEmpty else { throw ParseError.missingCode }
        return try make(version: version, server: server, code: code, op: q["op"], pin: q["pin"],
                        exp: q["exp"], now: now, allowInsecureLoopback: allowInsecureLoopback)
    }

    /// 「… 服务器 relay.example.com · 连接码 7K3M-9QX2 …」 and its English and
    /// Traditional Chinese twins.
    private static func parseText(_ text: String, now: Date, allowInsecureLoopback: Bool) throws -> RemoteInvite {
        let serverPattern = #"(?i)(?:服务器|伺服器|server)\s*[:：]?\s*([^\s·•|,，;；]+)"#
        let codePattern = #"(?i)(?:连接码|連線碼|連接碼|code)\s*[:：]?\s*([0-9A-Za-z]{4}[-\s]?[0-9A-Za-z]{4})(?![0-9A-Za-z])"#
        let opPattern = #"(?i)(?:操作员|操作員|operators?)\s*[:：]?\s*([0-9a-f,\s]{64,})"#
        let server = firstCapture(serverPattern, in: text)
        let code = firstCapture(codePattern, in: text)
        guard server != nil || code != nil else { throw ParseError.notAnInvite }
        guard let server else { throw ParseError.missingServer }
        guard let code else { throw ParseError.missingCode }
        let op = firstCapture(opPattern, in: text)?.replacingOccurrences(of: " ", with: "")
        return try make(version: currentVersion, server: server, code: code, op: op, pin: nil, exp: nil,
                        now: now, allowInsecureLoopback: allowInsecureLoopback)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func make(version: Int, server: String, code: String, op: String?, pin: String?,
                             exp: String?, now: Date, allowInsecureLoopback: Bool) throws -> RemoteInvite {
        let url = try serverURL(server, allowInsecureLoopback: allowInsecureLoopback)
        guard let code = normalizeCode(code) else { throw ParseError.invalidCode }
        let ops = try parseOperators(op)
        var pinData: Data?
        if let pin, !pin.isEmpty {
            guard let d = decodeDigest(pin) else { throw ParseError.invalidPin }
            pinData = d
        }
        var expiresAt: Date?
        if let exp, !exp.isEmpty {
            guard let seconds = TimeInterval(exp) else { throw ParseError.expired }
            expiresAt = Date(timeIntervalSince1970: seconds)
            if expiresAt! <= now { throw ParseError.expired }
        }
        return RemoteInvite(version: version, serverURL: url, code: code, operatorKeyIDs: ops,
                            spkiPin: pinData, expiresAt: expiresAt)
    }

    /// Upper-case, drop separators, map the Crockford look-alikes (O→0, I/L→1).
    /// Nil unless exactly `codeLength` characters of the alphabet remain.
    static func normalizeCode(_ raw: String) -> String? {
        var out = ""
        for ch in raw.uppercased() {
            switch ch {
            case "-", " ", "\u{2010}", "\u{2011}", "\u{2013}", "\u{2014}": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard codeAlphabet.contains(ch) else { return nil }
                out.append(ch)
            }
        }
        return out.count == codeLength ? out : nil
    }

    /// `relay.example.com`, `relay.example.com:8443`, `https://example.com/relay/`
    /// → `https://host[:port][/path]`. Query, fragment, user info, dot or
    /// percent-encoded path segments, and a scheme other than https (http for
    /// loopback in debug) are refused.
    static func serverURL(_ raw: String, allowInsecureLoopback: Bool) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        var scheme = "https"
        if lower.hasPrefix("https://") {
            s = String(s.dropFirst(8))
        } else if lower.hasPrefix("http://") {
            scheme = "http"
            s = String(s.dropFirst(7))
        } else if lower.contains("://") {
            throw ParseError.insecureServer
        }
        while s.hasSuffix("/") { s.removeLast() }
        var path = ""
        if let slash = s.firstIndex(of: "/") {
            path = String(s[slash...])
            s = String(s[..<slash])
            guard isValidPath(path) else { throw ParseError.invalidServer }
        }
        guard !s.isEmpty, !s.contains("@"), !s.contains("?"), !s.contains("#") else {
            throw ParseError.invalidServer
        }
        guard let c = URLComponents(string: "\(scheme)://\(s)"), let host = c.host, !host.isEmpty,
              isValidHost(host) else { throw ParseError.invalidServer }
        if let port = c.port, !(1...65535).contains(port) { throw ParseError.invalidServer }
        if scheme == "http" && !(allowInsecureLoopback && isLoopback(host)) {
            throw ParseError.insecureServer
        }
        var out = URLComponents()
        out.scheme = scheme
        out.host = host.lowercased()
        out.port = c.port
        out.path = path
        guard let url = out.url else { throw ParseError.invalidServer }
        return url
    }

    /// `/a/b`: segments of unreserved characters only, none `.` or `..`.
    private static func isValidPath(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.count <= 200, !segments.isEmpty else { return false }
        return segments.allSatisfy { seg in
            !seg.isEmpty && seg != "." && seg != ".."
                && seg.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }
        }
    }

    private static func isValidHost(_ host: String) -> Bool {
        if host.contains(":") {   // IPv6; URLComponents may or may not keep the brackets
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return !bare.isEmpty && bare.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    private static func parseOperators(_ raw: String?) throws -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for part in raw.split(separator: ",") {
            let id = part.trimmingCharacters(in: .whitespaces).lowercased()
            guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw ParseError.invalidOperator }
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// 32 bytes as 64 hex, or base64 / base64url (padding optional).
    static func decodeDigest(_ raw: String) -> Data? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.count == 64, s.allSatisfy({ $0.isHexDigit }) {
            var bytes = [UInt8]()
            var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
                bytes.append(b)
                i = j
            }
            return Data(bytes)
        }
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let d = Data(base64Encoded: b64), d.count == 32 else { return nil }
        return d
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
