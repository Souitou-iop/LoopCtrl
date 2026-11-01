import CryptoKit
import XCTest

final class RemoteSessionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func people(_ s: RemoteSession, _ now: Date) -> [[String: JSONValue]] {
        guard case .array(let list)? = s.state(now: now)["people"] else { return [] }
        return list.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    /// Several operate at once; each is listed while operating or watching.
    func testSeveralOperateAtOnce() {
        let s = RemoteSession()
        s.begin(tok: "a", name: "Agent", kind: .agent, method: "tap", detail: "(1, 2)", now: t0)
        s.begin(tok: "b", name: "Browser", kind: .person, method: "tap", detail: "(3, 4)", now: t0 + 1)
        let now = people(s, t0 + 2)
        XCTAssertEqual(now.map { $0["tok"] }, [.string("a"), .string("b")])
        XCTAssertEqual(now.map { $0["operating"] }, [.bool(true), .bool(true)])
        // Agents lapse after 30 s, people after 60 s.
        XCTAssertEqual(people(s, t0 + 40).map { $0["tok"] }, [.string("b")])
        XCTAssertTrue(people(s, t0 + 62).isEmpty)
    }

    func testWatchersArePresentWithoutActing() {
        let s = RemoteSession()
        s.watch(tok: "b", name: "Browser", now: t0)
        s.watch(tok: "b", name: "Browser", now: t0)
        s.unwatch(tok: "b", now: t0 + 1)
        XCTAssertEqual(people(s, t0 + 100).first?["watching"], .bool(true))
        XCTAssertEqual(people(s, t0 + 100).first?["operating"], .bool(false))
        s.unwatch(tok: "b", now: t0 + 101)
        XCTAssertTrue(people(s, t0 + 101).isEmpty)
    }

    /// Each participant's log is their own, with every action's outcome.
    func testLogsAreKeptPerParticipant() {
        let s = RemoteSession()
        var lines: [String] = []
        s.onLog = { lines.append($0) }
        let a = s.begin(tok: "a", name: "Agent", kind: .agent, method: "tap", detail: "(1, 2)", now: t0)
        let b = s.begin(tok: "b", name: "Browser", kind: .person, method: "type", detail: "3 characters", now: t0)
        s.finish(tok: "a", id: a, outcome: "applied")
        s.finish(tok: "b", id: b, outcome: "unknown")
        let only = s.logs(tok: "b")
        XCTAssertEqual(only.count, 1)
        guard case .object(let entry)? = only.first, case .array(let actions)? = entry["actions"],
              case .object(let action)? = actions.first else { return XCTFail("no log") }
        XCTAssertEqual(action["method"], .string("type"))
        XCTAssertEqual(action["outcome"], .string("unknown"))
        XCTAssertEqual(s.logs().count, 2)
        XCTAssertEqual(lines, ["👤 agent Agent: tap (1, 2) → applied", "👤 Browser: type 3 characters → unknown"])
    }

    /// Typing is logged by length, never by content.
    func testDescribeNeverLogsText() {
        XCTAssertEqual(RemoteSession.describe("type", ["text": .string("hunter2")]), "7 characters")
        XCTAssertEqual(RemoteSession.describe("tap", ["x": .double(10.4), "y": .double(20.6)]), "(10, 21)")
    }

    func testChangesFireOnlyWhenWhoChanges() {
        let s = RemoteSession()
        var changes = 0
        s.onChange = { changes += 1 }
        s.begin(tok: "a", name: "Agent", kind: .agent, method: "tap", detail: "", now: t0)
        s.begin(tok: "a", name: "Agent", kind: .agent, method: "tap", detail: "", now: t0 + 1)
        XCTAssertEqual(changes, 1)
        s.sweep(now: t0 + 40)            // the agent lapsed
        XCTAssertEqual(changes, 2)
        s.setPaused(true, now: t0 + 41)
        XCTAssertEqual(s.state(now: t0 + 41)["paused"], .bool(true))
        s.setPaused(false, now: t0 + 42)
        XCTAssertEqual(changes, 4)
    }

    func testStateMessageSeals() throws {
        let sealer = ScreenStreamSealer(pairingKey: nil)
        let raw = try XCTUnwrap(sealer.state(["paused": .bool(true), "people": .array([]), "hidden": .bool(false)]))
        XCTAssertEqual(raw[4], 3)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw.subdata(in: 5..<raw.count)) as? [String: Any])
        XCTAssertEqual(json["paused"] as? Bool, true)
    }

    /// Someone's touch, for pages to draw: type 4, sealed like the rest, so
    /// a page that predates it still keeps its counter in step.
    func testActionMessageSeals() throws {
        let fields: [String: JSONValue] = [
            "tok": .string("a1"), "kind": .string("agent"), "phase": .string("touch"), "touch": .string("tap"),
            "fingers": .array([.array([.array([.double(10), .double(20), .double(0)])])]),
        ]
        let raw = try XCTUnwrap(ScreenStreamSealer(pairingKey: nil).action(fields))
        XCTAssertEqual(raw[4], 4)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw.subdata(in: 5..<raw.count)) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "agent")
        XCTAssertEqual((json["fingers"] as? [[[Double]]])?.first?.first, [10, 20, 0])

        let key = Data(repeating: 7, count: 32), salt = Data(repeating: 1, count: 16)
        let sealer = ScreenStreamSealer(pairingKey: key, salt: salt)
        _ = sealer.state(["paused": .bool(false)])
        let sealed = try XCTUnwrap(sealer.action(fields))
        XCTAssertEqual(sealed[4], 4)
        let derived = SymmetricKey(data: SecureEnvelope.hmac(key, Data("loopctrl-stream-v1".utf8) + salt))
        var iv = Data(count: 4)
        iv.append(SecureEnvelope.be64(1))
        let body = sealed.subdata(in: 5..<sealed.count)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: body.dropLast(16), tag: body.suffix(16))
        let plain = try AES.GCM.open(box, using: derived, authenticating: Data([4]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: plain) as? [String: Any])?["tok"] as? String, "a1")
    }
}
