import CryptoKit
import XCTest

final class TunnelFrameTests: XCTestCase {
    func testRoundTrip() throws {
        let frame = TunnelFrame(.data, stream: 0x01020304, payload: Data([9, 8, 7]))
        XCTAssertEqual(frame.encoded, Data([2, 1, 2, 3, 4, 9, 8, 7]))
        XCTAssertEqual(TunnelFrame(decoding: frame.encoded), frame)
    }

    func testWindow() {
        let frame = TunnelFrame.window(7, 65_536)
        XCTAssertEqual(TunnelFrame(decoding: frame.encoded)?.windowCredit, 65_536)
        XCTAssertNil(TunnelFrame(.data, stream: 7, payload: Data([0, 1, 0, 0])).windowCredit)
    }

    func testRejectsShortAndUnknown() {
        XCTAssertNil(TunnelFrame(decoding: Data([2, 0, 0])))
        XCTAssertNil(TunnelFrame(decoding: Data([9, 0, 0, 0, 1])))
        XCTAssertEqual(TunnelFrame(decoding: Data([3, 0, 0, 0, 1]))?.payload, Data())
    }
}

final class TunnelRequestTests: XCTestCase {
    private func open(_ json: String) throws -> TunnelRequest.Open {
        try JSONDecoder().decode(TunnelRequest.Open.self, from: Data(json.utf8))
    }

    private func head(_ json: String) throws -> String? {
        try TunnelRequest.head(open(json), connectionID: "conn-1", server: "relay.example.com").map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    func testBuildsRequestWithRelayHeaders() throws {
        let text = try XCTUnwrap(head(#"""
        {"method":"POST","path":"/rpc?x=1","peer":"203.0.113.9",
         "headers":[["Content-Type","application/json"],["Content-Length","7"],["Connection","keep-alive"],["Host","evil"]]}
        """#))
        XCTAssertTrue(text.hasPrefix("POST /rpc?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 7\r\n"))
        XCTAssertTrue(text.contains("X-LoopCtrl-Relay-Connection: conn-1\r\n"))
        XCTAssertTrue(text.contains("X-LoopCtrl-Relay-Server: relay.example.com\r\n"))
        XCTAssertTrue(text.contains("X-LoopCtrl-Relay-Peer: 203.0.113.9\r\n"))
        XCTAssertTrue(text.hasSuffix("Connection: close\r\n\r\n"))
        XCTAssertFalse(text.contains("keep-alive"))
        XCTAssertFalse(text.contains("evil"))
    }

    /// The relay can't claim to be the phone's own relay headers.
    func testDropsForgedRelayHeaders() throws {
        let text = try XCTUnwrap(head(#"{"method":"GET","path":"/remote","peer":"","headers":[["x-loopctrl-relay-connection","other"]]}"#))
        XCTAssertFalse(text.contains("other"))
        XCTAssertEqual(text.components(separatedBy: "X-LoopCtrl-Relay-Connection").count, 2)
    }

    /// Nothing may break out of a header line.
    func testRefusesInjection() throws {
        XCTAssertNil(try head(#"{"method":"GET","path":"/a\r\nX-LoopCtrl-Relay-Connection: x","peer":"","headers":[]}"#))
        XCTAssertNil(try head(#"{"method":"GET","path":"/a","peer":"","headers":[["A","b\r\nX-LoopCtrl-Relay-Connection: x"]]}"#))
        XCTAssertNil(try head(#"{"method":"GET","path":"/a","peer":"","headers":[["A B","c"]]}"#))
        XCTAssertNil(try head(#"{"method":"G T","path":"/a","peer":"","headers":[]}"#))
        XCTAssertNil(try head(#"{"method":"GET","path":"a","peer":"","headers":[]}"#))
        XCTAssertNil(try head(#"{"method":"GET","path":"/a b","peer":"","headers":[]}"#))
        let peer = try XCTUnwrap(head(#"{"method":"GET","path":"/a","peer":"1.2.3.4\r\nX: y","headers":[]}"#))
        XCTAssertFalse(peer.contains("X: y"))
    }
}

final class ScreenStreamSealerTests: XCTestCase {
    private func messages(_ data: Data) -> [(UInt8, Data)] {
        var out: [(UInt8, Data)] = []
        var rest = data
        while rest.count >= 5 {
            let b = [UInt8](rest.prefix(5))
            let length = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            out.append((b[4], rest.subdata(in: rest.startIndex + 5..<rest.startIndex + 4 + length)))
            rest = rest.subdata(in: rest.startIndex + 4 + length..<rest.endIndex)
        }
        return out
    }

    func testPlaintext() throws {
        let sealer = ScreenStreamSealer(pairingKey: nil)
        let hello = try XCTUnwrap(messages(sealer.hello(viewer: "v1")).first)
        XCTAssertEqual(hello.0, 0)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: hello.1) as? [String: Any])
        XCTAssertEqual(info["enc"] as? String, "none")
        let frame = try XCTUnwrap(messages(XCTUnwrap(sealer.frame(keyframe: true, timestampMicros: 258, accessUnit: Data([0xAA])))).first)
        XCTAssertEqual(frame.0, 2)
        XCTAssertEqual(frame.1, Data([1, 0, 0, 0, 0, 0, 0, 1, 2, 0xAA]))
    }

    /// What the page does: derive the key from K and the salt, then open
    /// each message with the counter as the IV and the type as AAD.
    func testSealedMessagesOpenWithDerivedKey() throws {
        let pairingKey = Data(repeating: 7, count: 32)
        let salt = Data(repeating: 1, count: 16)
        let sealer = ScreenStreamSealer(pairingKey: pairingKey, salt: salt)
        let hello = try XCTUnwrap(JSONSerialization.jsonObject(with: messages(sealer.hello(viewer: "v1"))[0].1) as? [String: Any])
        XCTAssertEqual(hello["enc"] as? String, "aes-256-gcm")
        XCTAssertEqual(hello["salt"] as? String, salt.hexString)

        let key = SymmetricKey(data: SecureEnvelope.hmac(pairingKey, Data("loopctrl-stream-v1".utf8) + salt))
        let config = try XCTUnwrap(sealer.config(["codec": "avc1.64002a"]))
        let frame = try XCTUnwrap(sealer.frame(keyframe: false, timestampMicros: 5, accessUnit: Data([1, 2, 3])))
        for (counter, (raw, kind)) in [(config, UInt8(1)), (frame, UInt8(2))].enumerated() {
            let (type, sealed) = try XCTUnwrap(messages(raw).first)
            XCTAssertEqual(type, kind)
            var iv = Data(count: 4)
            iv.append(SecureEnvelope.be64(UInt64(counter)))
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                            ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            let plain = try AES.GCM.open(box, using: key, authenticating: Data([type]))
            if type == 2 { XCTAssertEqual(plain, Data([0, 0, 0, 0, 0, 0, 0, 0, 5, 1, 2, 3])) }
            // The type is authenticated: relabelling a message breaks it.
            XCTAssertThrowsError(try AES.GCM.open(box, using: key, authenticating: Data([type ^ 3])))
        }
    }

    func testCodecString() {
        XCTAssertEqual(ScreenStreamSealer.codecString(sps: Data([0x67, 0x64, 0x00, 0x2a, 0xac])), "avc1.64002a")
    }

    /// Main profile, Main tier, level 4.0 (120), compatibility flag 1 and 2
    /// set (0x60000000 reversed is 6), progressive-source constraint 0xB0.
    func testHEVCCodecString() {
        var hvcC = Data([0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0xB0, 0, 0, 0, 0, 0, 120])
        XCTAssertEqual(ScreenStreamSealer.codecString(hvcC: hvcC), "hvc1.1.6.L120.B0")
        hvcC[1] = 0x22   // high tier, Main 10
        hvcC[2] = 0x20
        XCTAssertEqual(ScreenStreamSealer.codecString(hvcC: hvcC), "hvc1.2.4.H120.B0")
    }

    func testHelloNamesTheViewer() throws {
        let hello = try XCTUnwrap(messages(ScreenStreamSealer(pairingKey: nil).hello(viewer: "abc")).first)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: hello.1) as? [String: Any])
        XCTAssertEqual(info["viewer"] as? String, "abc")
    }
}
