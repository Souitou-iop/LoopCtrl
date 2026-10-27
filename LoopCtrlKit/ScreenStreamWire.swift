import CryptoKit
import Foundation

/// What a `GET /stream` asked for (docs/remote-control.md, "Stream").
struct ScreenStreamRequest {
    enum Quality: String {
        case low, medium, high

        /// The encoded frame's longer side, in pixels; never upscaled.
        var longSide: Int {
            switch self {
            case .low: return 960
            case .medium: return 1280
            case .high: return 1920
            }
        }

        var bitsPerSecond: Int {
            switch self {
            case .low: return 1_000_000
            case .medium: return 3_000_000
            case .high: return 8_000_000
            }
        }

        var fps: Double {
            switch self {
            case .low: return 30
            case .medium, .high: return 60
            }
        }

        /// The quality the capture side compresses each screenshot at.
        var jpegQuality: Double {
            switch self {
            case .low: return 0.35
            case .medium: return 0.5
            case .high: return 0.7
            }
        }
    }

    enum Codec: String {
        case h264, hevc
    }

    let quality: Quality
    /// What the viewer can decode; the encoder falls back to H.264 when it
    /// can't make HEVC.
    var codec: Codec = .h264
    /// The viewer acknowledges frames (`stream_ack`), so the stream can hold
    /// its queue short and follow the bandwidth that actually gets through.
    var acks: Bool = false
    /// How many captures may overlap (1–3); nil keeps the current setting.
    var workers: Int? = nil
    /// The pairing key the ticket was minted for, when frames are to be
    /// sealed; nil for a plaintext stream.
    let key: Data?
    /// The paired client (token id) watching, so the phone can say who.
    var client: String? = nil
}

/// Frames the messages of one stream and, for an encrypted one, seals them.
///
///     message = len u32 (type + payload) | type u8 | payload
///
/// HELLO is always in the clear. With a key, every later payload is
/// AES-256-GCM under HMAC-SHA256(K, "loopctrl-stream-v1" || salt), with
/// iv = 0x00000000 || be64(counter) and the type byte as associated data.
final class ScreenStreamSealer {
    enum Kind: UInt8 {
        case hello = 0, config = 1, frame = 2, state = 3
    }

    static let keyLabel = "loopctrl-stream-v1"

    private let key: SymmetricKey?
    private let salt: Data
    private var counter: UInt64 = 0

    init(pairingKey: Data?, salt: Data? = nil) {
        let salt = salt ?? SecureEnvelope.randomBytes(16) ?? Data(count: 16)
        self.salt = salt
        self.key = pairingKey.map {
            SymmetricKey(data: SecureEnvelope.hmac($0, Data(Self.keyLabel.utf8) + salt))
        }
    }

    var encrypted: Bool { key != nil }

    func hello(viewer: String) -> Data {
        let body: [String: Any] = ["v": 1, "enc": key == nil ? "none" : "aes-256-gcm", "salt": salt.hexString,
                                   "viewer": viewer]
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return Self.frame(.hello, json)
    }

    func config(_ fields: [String: Any]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
        return message(.config, json)
    }

    /// Who holds control, whether the owner paused, whether the screen is
    /// hidden from capture: `{paused, owner, hidden}`.
    func state(_ fields: [String: JSONValue]) -> Data? {
        guard let json = try? JSONEncoder().encode(JSONValue.object(fields)) else { return nil }
        return message(.state, json)
    }

    /// flags u8 (bit 0: keyframe) | ts u64 (microseconds) | AVCC access unit
    func frame(keyframe: Bool, timestampMicros: UInt64, accessUnit: Data) -> Data? {
        var payload = Data(capacity: 9 + accessUnit.count)
        payload.append(keyframe ? 1 : 0)
        payload.append(SecureEnvelope.be64(timestampMicros))
        payload.append(accessUnit)
        return message(.frame, payload)
    }

    func message(_ kind: Kind, _ payload: Data) -> Data? {
        guard let key else { return Self.frame(kind, payload) }
        var iv = Data(count: 4)
        iv.append(SecureEnvelope.be64(counter))
        counter += 1
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: Data([kind.rawValue])) else {
            return nil
        }
        return Self.frame(kind, box.ciphertext + box.tag)
    }

    static func frame(_ kind: Kind, _ payload: Data) -> Data {
        var length = UInt32(payload.count + 1).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(kind.rawValue)
        out.append(payload)
        return out
    }

    /// The RFC 6381 codec string ("avc1.PPCCLL") of an H.264 SPS NAL unit.
    static func codecString(sps: Data) -> String {
        let b = [UInt8](sps)
        guard b.count >= 4 else { return "avc1.42e01f" }
        return String(format: "avc1.%02x%02x%02x", b[1], b[2], b[3])
    }

    /// The codec string ("hvc1.1.6.L93.B0") of an HEVC decoder configuration
    /// record (hvcC), as ISO/IEC 14496-15 annex E spells it.
    static func codecString(hvcC: Data) -> String {
        let b = [UInt8](hvcC)
        guard b.count >= 13 else { return "hvc1.1.6.L93.B0" }
        let space = ["", "A", "B", "C"][Int(b[1] >> 6)]
        let tier = (b[1] & 0x20) != 0 ? "H" : "L"
        let profile = Int(b[1] & 0x1f)
        // The compatibility flags, written with their bits in reverse order.
        let flags = UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
        var reversed: UInt32 = 0
        for i in 0..<32 where flags & (1 << i) != 0 { reversed |= 1 << (31 - i) }
        // Constraint bytes, trailing zero bytes left out.
        var constraints = Array(b[6..<12])
        while let last = constraints.last, last == 0 { constraints.removeLast() }
        var out = "hvc1.\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(b[12])"
        for c in constraints { out += "." + String(c, radix: 16, uppercase: true) }
        return out
    }
}
