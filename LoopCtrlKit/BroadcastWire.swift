import Foundation

/// The line between the ReplayKit broadcast extension (LoopCtrlBroadcast) and
/// the runner's screen stream (docs/remote-control.md, "System broadcast").
///
/// The extension gets the screen from iOS as it is drawn, encodes it, and
/// hands the encoded frames to the runner over loopback TCP; the runner sends
/// them to viewers exactly as it sends its own. What to encode — one encoder
/// per lane, each with its size, codec and bitrate, whether to hold back and
/// when to make a keyframe — comes the other way.
///
///     message = len u32 (type + payload) | type u8 | payload
///
/// No App Group: the extension and the app are signed apart (sign-ipa.sh
/// gives extensions no entitlements), so the port is fixed rather than shared
/// through a container, and the runner takes a connection only while iOS says
/// the screen is being captured.
enum BroadcastWire {
    /// The runner's loopback port for the extension.
    static let port: UInt16 = 48300

    enum Kind: UInt8 {
        // Extension → runner
        /// JSON `Hello`.
        case hello = 1
        /// JSON `Config`: an encoder's (re)start.
        case config = 2
        /// `lane u32 | flags u8 (bit 0 keyframe) | micros u64 | access unit`;
        /// micros on the system clock (`CACurrentMediaTime`), which both
        /// processes share.
        case frame = 3
        /// JSON `{"hidden": Bool}`: the screen went (or stopped being) black.
        case hidden = 4
        // Runner → extension
        /// JSON `[Lane]`: every lane, whenever any of them changes.
        case lanes = 10
        /// Empty: the switch was turned off; end the broadcast.
        case stop = 11
    }

    struct Hello: Codable {
        var v = 1
    }

    /// One encoder the runner wants, as `Lane` in ScreenStream sees it.
    struct Lane: Codable, Equatable {
        let id: UInt32
        /// The encoded frame's longer side, never more than the screen's.
        let longSide: Int
        let fps: Double
        /// "h264" or "hevc".
        let codec: String
        let bitrate: Int
        /// Encode nothing for now: frames are queueing on the way to a viewer.
        let hold: Bool
        /// Make a keyframe now, from the newest picture even if it is unchanged.
        let key: Bool
    }

    struct Config: Codable {
        let lane: UInt32
        /// "avc" or "hvc".
        let kind: String
        /// avcC or hvcC.
        let description: Data
        /// The H.264 sequence parameter set, for the codec string.
        let sps: Data?
        let width: Int
        let height: Int
        let pointWidth: Double
        let pointHeight: Double
    }

    struct Hidden: Codable {
        let hidden: Bool
    }

    static func message(_ kind: Kind, _ payload: Data = Data()) -> Data {
        var out = Data(capacity: 5 + payload.count)
        var length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(kind.rawValue)
        out.append(payload)
        return out
    }

    static func message<T: Encodable>(_ kind: Kind, json value: T) -> Data? {
        (try? JSONEncoder().encode(value)).map { message(kind, $0) }
    }

    static func frame(lane: UInt32, keyframe: Bool, micros: UInt64, accessUnit: Data) -> Data {
        var payload = Data(capacity: 13 + accessUnit.count)
        var id = lane.bigEndian
        withUnsafeBytes(of: &id) { payload.append(contentsOf: $0) }
        payload.append(keyframe ? 1 : 0)
        var ts = micros.bigEndian
        withUnsafeBytes(of: &ts) { payload.append(contentsOf: $0) }
        payload.append(accessUnit)
        return message(.frame, payload)
    }

    /// (lane, keyframe, micros, access unit) from a `frame` payload.
    static func parseFrame(_ payload: Data) -> (UInt32, Bool, UInt64, Data)? {
        guard payload.count > 13 else { return nil }
        let b = [UInt8](payload.prefix(13))
        let lane = b[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let micros = b[5..<13].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (lane, b[4] & 1 == 1, micros, payload.dropFirst(13))
    }

    /// Splits whole messages off the front of `buffer`.
    struct Reader {
        private var buffer = Data()

        mutating func feed(_ data: Data) -> [(Kind, Data)] {
            buffer.append(data)
            var out: [(Kind, Data)] = []
            while buffer.count >= 5 {
                let b = buffer.startIndex
                let length = Int(buffer[b]) << 24 | Int(buffer[b + 1]) << 16 | Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
                guard length >= 1, length <= 16 << 20 else { buffer.removeAll(); break }
                guard buffer.count >= 4 + length else { break }
                let type = buffer[b + 4]
                let payload = Data(buffer[(b + 5)..<(b + 4 + length)])
                buffer.removeSubrange(b..<(b + 4 + length))
                if let kind = Kind(rawValue: type) { out.append((kind, payload)) }
            }
            return out
        }
    }
}
