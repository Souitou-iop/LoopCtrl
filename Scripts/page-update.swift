// Sign the control page for page_update, so a phone takes it without the app
// being reinstalled (docs/remote-control.md, "Page updates").
//
//   swift Scripts/page-update.swift <out.json>
//
// Reads the page from LoopCtrlKit/RemoteHTML.swift, versions it with the
// current time (yyyyMMddHHmm, the form of the app's BuildStamp) and signs it
// with the key in ~/.loopctrl-keys/page-update.key (64 hex characters, the
// Ed25519 private key whose public half is PageUpdate.publicKeyHex). The key
// never goes into the repository. Then: make page-push HOST=<phone or relay URL>.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift Scripts/page-update.swift <out.json>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appendingPathComponent("LoopCtrlKit/RemoteHTML.swift"), encoding: .utf8)
let open = "static let page: String = #\"\"\"\n"
guard let start = source.range(of: open), let end = source.range(of: "\n\"\"\"#", range: start.upperBound..<source.endIndex) else {
    FileHandle.standardError.write(Data("could not find the page in RemoteHTML.swift\n".utf8))
    exit(1)
}
let html = String(source[start.upperBound..<end.lowerBound])

let keyPath = NSString(string: "~/.loopctrl-keys/page-update.key").expandingTildeInPath
guard let hex = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      hex.count == 64 else {
    FileHandle.standardError.write(Data("no signing key at \(keyPath)\n".utf8))
    exit(1)
}
var raw = Data()
var i = hex.startIndex
while i < hex.endIndex {
    let j = hex.index(i, offsetBy: 2)
    raw.append(UInt8(hex[i..<j], radix: 16)!)
    i = j
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)

let stamp = DateFormatter()
stamp.dateFormat = "yyyyMMddHHmm"
stamp.locale = Locale(identifier: "en_US_POSIX")
let version = Int(stamp.string(from: Date()))!
let digest = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
let signature = try key.signature(for: Data("loopctrl-page-v1\n\(version)\n\(digest)".utf8))

let out = try JSONSerialization.data(withJSONObject: [
    "html": html, "version": version,
    "signature": signature.map { String(format: "%02x", $0) }.joined(),
])
try out.write(to: URL(fileURLWithPath: args[1]))
print("signed page \(version): \(html.utf8.count) bytes → \(args[1])")
