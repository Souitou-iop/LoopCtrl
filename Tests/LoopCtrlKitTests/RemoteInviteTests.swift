import XCTest

final class RemoteInviteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let opA = String(repeating: "a1", count: 32)
    private let opB = String(repeating: "b2", count: 32)
    private let pinHex = String(repeating: "0f", count: 32)

    // MARK: - Link

    func testFullLink() throws {
        let link = "loopctrl://connect?v=1&server=relay.example.com&code=7K3M-9QX2&op=\(opA),\(opB.uppercased())&pin=\(pinHex)&exp=1800000600"
        let invite = try RemoteInvite.parse(link, now: now)
        XCTAssertEqual(invite.serverURL.absoluteString, "https://relay.example.com")
        XCTAssertEqual(invite.serverDisplay, "relay.example.com")
        XCTAssertEqual(invite.code, "7K3M9QX2")
        XCTAssertEqual(invite.displayCode, "7K3M-9QX2")
        XCTAssertEqual(invite.operatorKeyIDs, [opA, opB], "lower-cased, order kept")
        XCTAssertEqual(invite.spkiPin, Data(repeating: 0x0f, count: 32))
        XCTAssertEqual(invite.expiresAt, Date(timeIntervalSince1970: 1_800_000_600))
        XCTAssertTrue(invite.isHTTPS)
    }

    func testLinkRoundTrip() throws {
        let invite = try RemoteInvite.parse("loopctrl://connect?v=1&server=relay.example.com:8443&code=7k3m9qx2&op=\(opA)&pin=\(pinHex)", now: now)
        XCTAssertEqual(invite.serverDisplay, "relay.example.com:8443")
        let again = try RemoteInvite.parse(invite.link.absoluteString, now: now)
        XCTAssertEqual(again, invite)
    }

    func testPinAcceptsBase64url() throws {
        let pin = RemoteInvite.base64url(Data(repeating: 0xfb, count: 32))
        XCTAssertTrue(pin.contains("-") || pin.contains("_"))
        let invite = try RemoteInvite.parse("loopctrl://connect?server=r.example&code=7K3M9QX2&pin=\(pin)", now: now)
        XCTAssertEqual(invite.spkiPin, Data(repeating: 0xfb, count: 32))
    }

    func testLinkInsideOtherText() throws {
        let text = "Here is your invite: loopctrl://connect?v=1&server=relay.example.com&code=7K3M-9QX2&op=\(opA) — valid 10 minutes"
        let invite = try RemoteInvite.parse(text, now: now)
        XCTAssertEqual(invite.operatorKeyIDs, [opA])
    }

    func testAppSchemeIsAccepted() throws {
        XCTAssertNoThrow(try RemoteInvite.parse("loopctrl-app://connect?server=relay.example.com&code=7K3M9QX2", now: now))
        XCTAssertTrue(RemoteInvite.isInviteLink(URL(string: "loopctrl://connect?x=1")!))
        XCTAssertFalse(RemoteInvite.isInviteLink(URL(string: "loopctrl://start?port=8300")!))
    }

    func testMissingVersionDefaultsToOne() throws {
        XCTAssertEqual(try RemoteInvite.parse("loopctrl://connect?server=a.example&code=7K3M9QX2", now: now).version, 1)
    }

    func testRejections() {
        assertThrows("loopctrl://connect?v=2&server=a.example&code=7K3M9QX2", .unsupportedVersion(2))
        assertThrows("loopctrl://connect?v=1&code=7K3M9QX2", .missingServer)
        assertThrows("loopctrl://connect?v=1&server=a.example", .missingCode)
        assertThrows("loopctrl://connect?server=a.example&code=7K3M9QX", .invalidCode)
        assertThrows("loopctrl://connect?server=a.example&code=7K3M9QX2Z", .invalidCode)
        assertThrows("loopctrl://connect?server=a.example&code=7K3M9QXU", .invalidCode)
        assertThrows("loopctrl://connect?server=a.example&code=7K3M9QX2&op=a1b2c3d4", .invalidOperator)
        assertThrows("loopctrl://connect?server=a.example&code=7K3M9QX2&op=\(opA),zz", .invalidOperator)
        assertThrows("loopctrl://connect?server=a.example&code=7K3M9QX2&pin=abcd", .invalidPin)
        assertThrows("loopctrl://connect?server=a.example&code=7K3M9QX2&exp=1799999999", .expired)
        assertThrows("loopctrl://connect?server=a.example&code=7K3M9QX2&exp=soon", .expired)
        assertThrows("loopctrl://connect?server=bad_host!&code=7K3M9QX2", .invalidServer)
        assertThrows("loopctrl://connect?server=a.example/path&code=7K3M9QX2", .invalidServer)
        assertThrows("loopctrl://connect?server=user@a.example&code=7K3M9QX2", .invalidServer)
        assertThrows("loopctrl://connect?server=ftp://a.example&code=7K3M9QX2", .insecureServer)
        assertThrows("hello world", .notAnInvite)
        assertThrows("", .notAnInvite)
    }

    func testExpiryInTheFutureIsFine() throws {
        XCTAssertNoThrow(try RemoteInvite.parse("loopctrl://connect?server=a.example&code=7K3M9QX2&exp=1800000001", now: now))
    }

    // MARK: - HTTPS only

    func testHTTPIsRefused() {
        assertThrows("loopctrl://connect?server=http://relay.example.com&code=7K3M9QX2", .insecureServer)
        assertThrows("loopctrl://connect?server=http://relay.example.com&code=7K3M9QX2", .insecureServer,
                     allowLoopback: true)
    }

    func testHTTPLoopbackOnlyWhenAllowed() throws {
        for host in ["http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080"] {
            assertThrows("loopctrl://connect?server=\(host)&code=7K3M9QX2", .insecureServer)
            let invite = try RemoteInvite.parse("loopctrl://connect?server=\(host)&code=7K3M9QX2", now: now,
                                                allowInsecureLoopback: true)
            XCTAssertEqual(invite.serverURL.scheme, "http")
            XCTAssertFalse(invite.isHTTPS)
        }
    }

    func testExplicitHTTPSAndTrailingSlash() throws {
        let invite = try RemoteInvite.parse("loopctrl://connect?server=https://Relay.Example.com/&code=7K3M9QX2", now: now)
        XCTAssertEqual(invite.serverURL.absoluteString, "https://relay.example.com")
    }

    // MARK: - Text form

    func testSimplifiedChineseText() throws {
        let invite = try RemoteInvite.parse("LoopCtrl 连接邀请 · 服务器 relay.example.com · 连接码 7K3M-9QX2 · 10 分钟内有效", now: now)
        XCTAssertEqual(invite.serverDisplay, "relay.example.com")
        XCTAssertEqual(invite.code, "7K3M9QX2")
        XCTAssertTrue(invite.operatorKeyIDs.isEmpty, "the text form carries no op")
    }

    func testTraditionalChineseAndEnglishText() throws {
        let hant = try RemoteInvite.parse("LoopCtrl 連線邀請 · 伺服器 relay.example.com · 連線碼 7K3M-9QX2 · 10 分鐘內有效", now: now)
        XCTAssertEqual(hant.code, "7K3M9QX2")
        let en = try RemoteInvite.parse("LoopCtrl connection invite · Server: relay.example.com:8443 · Code 7k3m 9qx2 · valid for 10 minutes", now: now)
        XCTAssertEqual(en.serverDisplay, "relay.example.com:8443")
        XCTAssertEqual(en.code, "7K3M9QX2")
    }

    func testTextWithOperators() throws {
        let invite = try RemoteInvite.parse("服务器：relay.example.com\n连接码：7K3M-9QX2\n操作员：\(opA)", now: now)
        XCTAssertEqual(invite.operatorKeyIDs, [opA])
    }

    func testTextMissingPieces() {
        assertThrows("LoopCtrl 连接邀请 · 连接码 7K3M-9QX2", .missingServer)
        assertThrows("LoopCtrl 连接邀请 · 服务器 relay.example.com", .missingCode)
        assertThrows("服务器 http://relay.example.com · 连接码 7K3M-9QX2", .insecureServer)
    }

    // MARK: - Manual entry

    func testManual() throws {
        let invite = try RemoteInvite.manual(server: " relay.example.com ", code: "7k3m-9qx2", now: now)
        XCTAssertEqual(invite.code, "7K3M9QX2")
        XCTAssertTrue(invite.operatorKeyIDs.isEmpty)
        XCTAssertThrowsError(try RemoteInvite.manual(server: "", code: "7K3M9QX2")) {
            XCTAssertEqual($0 as? RemoteInvite.ParseError, .missingServer)
        }
        XCTAssertThrowsError(try RemoteInvite.manual(server: "a.example", code: " ")) {
            XCTAssertEqual($0 as? RemoteInvite.ParseError, .missingCode)
        }
    }

    func testCodeNormalization() {
        XCTAssertEqual(RemoteInvite.normalizeCode("o1il-2345"), "01112345")
        XCTAssertEqual(RemoteInvite.normalizeCode("7K3M\u{2013}9QX2"), "7K3M9QX2")
        XCTAssertNil(RemoteInvite.normalizeCode("7K3M-9QX!"))
    }

    // MARK: - Helpers

    private func assertThrows(_ text: String, _ expected: RemoteInvite.ParseError, allowLoopback: Bool = false,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RemoteInvite.parse(text, now: now, allowInsecureLoopback: allowLoopback),
                             file: file, line: line) { error in
            XCTAssertEqual(error as? RemoteInvite.ParseError, expected, text, file: file, line: line)
        }
    }
}

final class OperatorCheckTests: XCTestCase {
    private let a = RemoteOperator(name: "Alice", keyID: String(repeating: "a1", count: 32))
    private let b = RemoteOperator(name: "Bob", keyID: String(repeating: "b2", count: 32))
    private let evil = RemoteOperator(name: "Alice", keyID: String(repeating: "e3", count: 32))

    func testExactMatchIsPreApproved() {
        let check = OperatorCheck.verify(inviteKeyIDs: [a.keyID, b.keyID], serverOperators: [b, a])
        XCTAssertEqual(check, .matched([b, a]))
        XCTAssertEqual(check.preApproved, [b, a])
    }

    func testCaseInsensitive() {
        let check = OperatorCheck.verify(inviteKeyIDs: [a.keyID.uppercased()], serverOperators: [a])
        XCTAssertEqual(check.preApproved, [a])
    }

    func testServerSubstitutesItsOwnKey() {
        // Same name, different key: the name plays no part.
        let check = OperatorCheck.verify(inviteKeyIDs: [a.keyID], serverOperators: [evil])
        XCTAssertEqual(check, .mismatch(unexpected: [evil.keyID], missing: [a.keyID]))
        XCTAssertTrue(check.preApproved.isEmpty)
    }

    func testServerAddsAnOperator() {
        let check = OperatorCheck.verify(inviteKeyIDs: [a.keyID], serverOperators: [a, evil])
        XCTAssertEqual(check, .mismatch(unexpected: [evil.keyID], missing: []))
    }

    func testServerDropsAnOperator() {
        let check = OperatorCheck.verify(inviteKeyIDs: [a.keyID, b.keyID], serverOperators: [a])
        XCTAssertEqual(check, .mismatch(unexpected: [], missing: [b.keyID]))
    }

    func testServerReturnsNoOperators() {
        let check = OperatorCheck.verify(inviteKeyIDs: [a.keyID], serverOperators: [])
        XCTAssertEqual(check, .mismatch(unexpected: [], missing: [a.keyID]))
    }

    func testNoOpInInviteIsUnverifiedAndPreApprovesNothing() {
        let check = OperatorCheck.verify(inviteKeyIDs: [], serverOperators: [a, b])
        XCTAssertEqual(check, .unverified([a, b]))
        XCTAssertTrue(check.preApproved.isEmpty)
        XCTAssertEqual(check.operators, [a, b])
    }

    func testFingerprintAndGrouping() {
        XCTAssertEqual(a.fingerprint, "a1a1a1a1")
        XCTAssertEqual(a.groupedKeyID.split(separator: " ").count, 16)
    }
}

final class RemoteConnectionMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testEnrollToConnectedToOperated() {
        var m = RemoteConnectionMachine()
        XCTAssertFalse(m.isActive)
        XCTAssertTrue(m.handle(.enroll, now: t0))
        XCTAssertEqual(m.phase, .enrolling(.createKey))
        XCTAssertTrue(m.handle(.advance(.redeemCode), now: t0))
        XCTAssertTrue(m.handle(.advance(.openRelay), now: t0))
        XCTAssertFalse(m.handle(.advance(.createKey), now: t0), "steps only go forward")
        XCTAssertTrue(m.handle(.advance(.preApprove), now: t0))
        XCTAssertTrue(m.handle(.established, now: t0 + 1))
        XCTAssertEqual(m.phase, .connected(since: t0 + 1))
        XCTAssertTrue(m.handle(.latency(42), now: t0 + 2))
        XCTAssertEqual(m.latencyMS, 42)
        XCTAssertTrue(m.handle(.operatorStarted("Alice"), now: t0 + 10))
        XCTAssertEqual(m.phase, .operated(by: "Alice", since: t0 + 10, connectedSince: t0 + 1))
        XCTAssertEqual(m.connectedSince, t0 + 1)
        XCTAssertTrue(m.handle(.operatorEnded, now: t0 + 20))
        XCTAssertEqual(m.phase, .connected(since: t0 + 1), "connected time carries over")
    }

    func testEnrollmentFailures() {
        for error in RemoteServiceError.allCases {
            var m = RemoteConnectionMachine()
            m.handle(.enroll, now: t0)
            XCTAssertTrue(m.handle(.fail(error), now: t0))
            XCTAssertEqual(m.phase, .failed(error))
            XCTAssertFalse(m.isActive)
            XCTAssertTrue(m.handle(.enroll, now: t0), "can try again after a failure")
        }
    }

    func testDropAndReconnectCounts() {
        var m = RemoteConnectionMachine()
        m.handle(.open, now: t0)
        m.handle(.established, now: t0)
        m.handle(.latency(30), now: t0)
        XCTAssertTrue(m.handle(.lost, now: t0 + 100))
        XCTAssertEqual(m.phase, .reconnecting(attempt: 1, connectedSince: t0))
        XCTAssertNil(m.latencyMS)
        XCTAssertTrue(m.handle(.lost, now: t0 + 101))
        XCTAssertEqual(m.phase, .reconnecting(attempt: 2, connectedSince: t0))
        XCTAssertTrue(m.handle(.established, now: t0 + 105))
        XCTAssertEqual(m.phase, .connected(since: t0), "the connection's age survives a reconnect")
        XCTAssertEqual(m.reconnectCount(now: t0 + 106), 1)
        XCTAssertEqual(m.reconnectCount(now: t0 + 105 + 24 * 3600), 0, "only the last 24 h count")
    }

    func testGivesUpAfterMaxAttempts() {
        var m = RemoteConnectionMachine()
        m.handle(.open, now: t0)
        m.handle(.established, now: t0)
        for _ in 0..<RemoteConnectionMachine.maxReconnectAttempts { m.handle(.lost, now: t0) }
        XCTAssertEqual(m.phase, .reconnecting(attempt: RemoteConnectionMachine.maxReconnectAttempts, connectedSince: t0))
        m.handle(.lost, now: t0)
        XCTAssertEqual(m.phase, .failed(.serverUnreachable))
    }

    func testServerClosesWhileOperated() {
        var m = RemoteConnectionMachine()
        m.handle(.open, now: t0)
        m.handle(.established, now: t0)
        m.handle(.operatorStarted("Alice"), now: t0)
        XCTAssertTrue(m.handle(.fail(.disconnectedByServer), now: t0))
        XCTAssertEqual(m.phase, .failed(.disconnectedByServer))
    }

    func testUserDisconnectFromAnywhere() {
        var m = RemoteConnectionMachine()
        m.handle(.open, now: t0)
        m.handle(.established, now: t0)
        m.handle(.operatorStarted("Alice"), now: t0)
        XCTAssertTrue(m.handle(.disconnect, now: t0))
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.handle(.open, now: t0))
        XCTAssertEqual(m.phase, .connecting)
    }

    func testNonsenseEventsAreIgnored() {
        var m = RemoteConnectionMachine()
        XCTAssertFalse(m.handle(.established, now: t0))
        XCTAssertFalse(m.handle(.operatorStarted("x"), now: t0))
        XCTAssertFalse(m.handle(.lost, now: t0))
        XCTAssertFalse(m.handle(.latency(1), now: t0))
        XCTAssertEqual(m.phase, .idle)
        m.handle(.open, now: t0)
        XCTAssertFalse(m.handle(.enroll, now: t0), "no new enrolment while one is running")
        XCTAssertFalse(m.handle(.operatorEnded, now: t0))
    }
}

final class PreApprovalLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let keyA = PairRequestLedger.keyID(forPublicKey: Data(repeating: 0xA1, count: 32))
    private let keyB = PairRequestLedger.keyID(forPublicKey: Data(repeating: 0xB2, count: 32))

    private func admit(_ l: inout PairRequestLedger, _ keyID: String, source: String = "relay",
                       id: String = "auth-1") -> PairRequestLedger.PreApproval? {
        l.admitPreApproved(keyID: keyID, source: source, id: id, clientName: "op", address: nil,
                           fingerprint: String(keyID.prefix(8)), now: t0)
    }

    func testPreApprovedKeyIsAdmittedThroughRelayOnly() {
        var l = PairRequestLedger()
        l.setPreApprovals(connectionID: "c1", operators: [("Alice", keyA)])
        XCTAssertNil(admit(&l, keyA, source: "lan"), "the same key on the LAN is still asked about")
        XCTAssertNil(admit(&l, keyA, source: "tailnet"))
        XCTAssertNil(admit(&l, keyB), "any other key needs approval")
        let hit = admit(&l, keyA)
        XCTAssertEqual(hit?.connectionID, "c1")
        XCTAssertEqual(hit?.operatorName, "Alice")
        XCTAssertEqual(l.recent.first?.outcome, .allowed)
        XCTAssertEqual(l.recent.first?.autoApproved, true)
        XCTAssertNotNil(admit(&l, keyA, id: "auth-2"), "standing, not one-shot")
    }

    func testShortFingerprintsAreNeverBindings() {
        var l = PairRequestLedger()
        l.setPreApprovals(connectionID: "c1", operators: [("Alice", String(keyA.prefix(8))), ("Bob", "zz")])
        XCTAssertTrue(l.preApprovals.isEmpty)
    }

    func testReplaceAndRevokePerConnection() {
        var l = PairRequestLedger()
        l.setPreApprovals(connectionID: "c1", operators: [("Alice", keyA.uppercased())])
        l.setPreApprovals(connectionID: "c2", operators: [("Bob", keyB)])
        XCTAssertEqual(l.preApprovals.map(\.keyID), [keyA, keyB])
        l.setPreApprovals(connectionID: "c1", operators: [("Bob", keyB)])
        XCTAssertNil(admit(&l, keyA), "replaced")
        XCTAssertEqual(l.revokePreApprovals(connectionID: "c2"), 1)
        XCTAssertEqual(l.preApprovals.map(\.connectionID), ["c1"])
        XCTAssertEqual(l.revokePreApprovals(connectionID: "c1"), 1)
        XCTAssertNil(admit(&l, keyB))
    }
}
