import CryptoKit
import Foundation

/// The control page, updatable without reinstalling the app
/// (docs/remote-control.md, "Page updates").
///
/// The page ships inside the app; a newer one can be pushed with the
/// `page_update` RPC. Only a page signed with the project's page key is
/// taken (Ed25519 over `loopctrl-page-v1\n<version>\n<sha256 of the page>`;
/// `Scripts/page-update.swift` signs, the private key never leaves the
/// developer's machine), only a newer one than what is served, and a page
/// pushed before the app was last built gives way to the app's own.
enum PageUpdate {
    /// The page key's public half. Rotating it means a new app build.
    static let publicKeyHex = "b4467b3c5a205d7934fc5296936476625b6bfdc1f722f070598e3164c110570d"

    struct Stored: Codable {
        let html: String
        let version: Int
        let signature: String
    }

    private static let lock = NSLock()
    private static var loaded = false
    private static var stored: Stored?

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("LoopCtrl", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("control-page.json")
    }

    /// The app's own page, as a version: its build time, yyyyMMddHHmm.
    static var builtInVersion: Int {
        Int(BuildStamp.value.filter(\.isNumber)) ?? 0
    }

    static func verify(html: String, version: Int, signature: String) -> Bool {
        guard let keyData = Data(hexString: publicKeyHex), let sig = Data(hexString: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sig, for: message(html: html, version: version))
    }

    static func message(html: String, version: Int) -> Data {
        let digest = Data(SHA256.hash(data: Data(html.utf8))).hexString
        return Data("loopctrl-page-v1\n\(version)\n\(digest)".utf8)
    }

    /// The pushed page, if it is valid and newer than the app's own. Read
    /// once from disk; one older than this build is deleted.
    private static func currentLocked() -> Stored? {
        if !loaded {
            loaded = true
            if let url = fileURL, let data = try? Data(contentsOf: url),
               let s = try? JSONDecoder().decode(Stored.self, from: data),
               verify(html: s.html, version: s.version, signature: s.signature) {
                if s.version > builtInVersion { stored = s } else { try? FileManager.default.removeItem(at: url) }
            }
        }
        return stored
    }

    /// What GET /remote serves.
    static var page: String {
        lock.lock()
        defer { lock.unlock() }
        return currentLocked()?.html ?? RemoteHTML.page
    }

    /// The served page's version (the pushed one's, else the build's).
    static var servedVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentLocked()?.version ?? builtInVersion
    }

    /// `page_update`: `{}` reports, `{html, version, signature}` installs,
    /// `{reset: true}` goes back to the app's own page.
    static func handle(_ params: [String: JSONValue]?) -> ([String: JSONValue]?, JSONRPCError?) {
        lock.lock()
        defer { lock.unlock() }
        let current = currentLocked()
        if params?["reset"]?.boolValue == true {
            stored = nil
            if let url = fileURL { try? FileManager.default.removeItem(at: url) }
            return (status(nil), nil)
        }
        guard let html = params?["html"]?.stringValue else { return (status(current), nil) }
        guard let version = params?["version"]?.doubleValue.map({ Int($0) }),
              let signature = params?["signature"]?.stringValue,
              verify(html: html, version: version, signature: signature) else {
            return (nil, JSONRPCError(code: -32602, message:
                "Not installed: the page isn't signed with this app's page key (or html, version or signature is missing).",
                data: nil))
        }
        let serving = current?.version ?? builtInVersion
        guard version > serving else {
            return (nil, JSONRPCError(code: -32602, message:
                "Not installed: version \(version) isn't newer than the page served now (\(serving)).",
                data: ["served_version": .int(serving)]))
        }
        let s = Stored(html: html, version: version, signature: signature)
        guard let url = fileURL, let data = try? JSONEncoder().encode(s), (try? data.write(to: url, options: .atomic)) != nil else {
            return (nil, .serverError("Could not save the page."))
        }
        stored = s
        return (status(s), nil)
    }

    private static func status(_ s: Stored?) -> [String: JSONValue] {
        [
            "served": .string(s == nil ? "app" : "update"),
            "served_version": .int(s?.version ?? builtInVersion),
            "app_version": .int(builtInVersion),
        ]
    }
}
