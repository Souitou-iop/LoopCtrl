import XCTest

final class PairRequestLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let keyA = PairRequestLedger.keyID(forPublicKey: Data(repeating: 0xA1, count: 32))
    private let keyB = PairRequestLedger.keyID(forPublicKey: Data(repeating: 0xB2, count: 32))

    private func ledger(timedOut keyID: String?, id: String = "auth-1", name: String = "laptop") -> PairRequestLedger {
        var l = PairRequestLedger()
        l.begin(id: id, clientName: name, source: "lan", address: "192.168.1.20",
                fingerprint: keyID.map { String($0.prefix(8)) }, keyID: keyID, now: t0, timeout: 60)
        XCTAssertTrue(l.finish(id: id, outcome: .timedOut, now: t0 + 60))
        return l
    }

    private func consume(_ l: inout PairRequestLedger, _ keyID: String, at time: Date, id: String = "auth-2",
                         name: String = "laptop") -> Bool {
        l.consumeGrant(keyID: keyID, id: id, clientName: name, source: "lan", address: "192.168.1.20",
                       fingerprint: String(keyID.prefix(8)), now: time)
    }

    func testKeyIDIsFullHashAndFingerprintItsPrefix() {
        let pub = Data((0..<32).map { UInt8($0) })
        let id = PairRequestLedger.keyID(forPublicKey: pub)
        XCTAssertEqual(id.count, 64)
        XCTAssertEqual(PairRequestLedger.fingerprint(forPublicKey: pub), String(id.prefix(8)))
    }

    func testPendingMovesToRecentWithOutcome() {
        var l = PairRequestLedger()
        l.begin(id: "a", clientName: "x", source: "lan", address: nil, fingerprint: nil, keyID: keyA,
                now: t0, timeout: 60)
        XCTAssertEqual(l.pending.count, 1)
        XCTAssertEqual(l.pending[0].deadline, t0 + 60)
        XCTAssertTrue(l.finish(id: "a", outcome: .denied, now: t0 + 5))
        XCTAssertFalse(l.finish(id: "a", outcome: .allowed, now: t0 + 6), "settled once only")
        XCTAssertTrue(l.pending.isEmpty)
        XCTAssertEqual(l.recent.first?.outcome, .denied)
        XCTAssertEqual(l.recent.first?.resolvedAt, t0 + 5)
    }

    func testAllowAfterTheFactAdmitsTheSameKeyOnce() {
        var l = ledger(timedOut: keyA)
        XCTAssertTrue(l.recent[0].canAllow(now: t0 + 120))
        XCTAssertTrue(l.allowAfterTheFact(id: "auth-1", now: t0 + 120))
        XCTAssertFalse(l.recent[0].canAllow(now: t0 + 121), "already allowed")
        XCTAssertTrue(consume(&l, keyA, at: t0 + 180))
        // The retry is recorded as allowed; the source entry is spent.
        XCTAssertEqual(l.recent.first?.id, "auth-2")
        XCTAssertEqual(l.recent.first?.outcome, .allowed)
        XCTAssertEqual(l.recent.first?.autoApproved, true)
        XCTAssertEqual(l.recent.first { $0.id == "auth-1" }?.grant, .used)
        XCTAssertFalse(consume(&l, keyA, at: t0 + 181, id: "auth-3"), "single use")
    }

    func testDifferentKeyNeverMatches() {
        var l = ledger(timedOut: keyA)
        XCTAssertTrue(l.allowAfterTheFact(id: "auth-1", now: t0 + 61))
        XCTAssertFalse(consume(&l, keyB, at: t0 + 62))
        // Same 8-hex prefix, different key: still no match.
        let lookalike = String(keyA.prefix(8)) + String(repeating: "0", count: 56)
        XCTAssertFalse(consume(&l, lookalike, at: t0 + 63))
        // The real key is still admitted afterwards.
        XCTAssertTrue(consume(&l, keyA, at: t0 + 64))
    }

    func testClientNameIsIgnored() {
        var l = ledger(timedOut: keyA, name: "laptop")
        XCTAssertTrue(l.allowAfterTheFact(id: "auth-1", now: t0 + 61))
        XCTAssertFalse(consume(&l, keyB, at: t0 + 62, name: "laptop"), "same name, other key")
        XCTAssertTrue(consume(&l, keyA, at: t0 + 63, name: "renamed"), "same key, other name")
    }

    func testNoGrantWithoutApproval() {
        var l = ledger(timedOut: keyA)
        XCTAssertFalse(consume(&l, keyA, at: t0 + 70), "timing out arms nothing")
    }

    func testGrantExpires() {
        var l = ledger(timedOut: keyA)
        let tap = t0 + 300
        XCTAssertTrue(l.allowAfterTheFact(id: "auth-1", now: tap))
        XCTAssertFalse(consume(&l, keyA, at: tap + PairRequestLedger.recentWindow))
    }

    func testGrantStillValidJustBeforeExpiry() {
        var l = ledger(timedOut: keyA)
        let tap = t0 + 300
        XCTAssertTrue(l.allowAfterTheFact(id: "auth-1", now: tap))
        XCTAssertTrue(consume(&l, keyA, at: tap + PairRequestLedger.recentWindow - 1))
    }

    func testCannotAllowAfterWindow() {
        var l = ledger(timedOut: keyA)
        let late = t0 + 60 + PairRequestLedger.recentWindow
        XCTAssertFalse(l.allowAfterTheFact(id: "auth-1", now: late))
        XCTAssertTrue(l.recent.isEmpty, "pruned once past the window")
    }

    func testArmedEntryStaysListedUntilGrantEnds() {
        var l = ledger(timedOut: keyA)
        let tap = t0 + 60 + PairRequestLedger.recentWindow - 10
        XCTAssertTrue(l.allowAfterTheFact(id: "auth-1", now: tap))
        l.prune(now: tap + 60)
        XCTAssertEqual(l.recent.count, 1, "kept while the grant runs")
        l.prune(now: tap + PairRequestLedger.recentWindow)
        XCTAssertTrue(l.recent.isEmpty)
    }

    func testPlainRequestWithoutKeyCanNeverBeAllowed() {
        var l = ledger(timedOut: nil)
        XCTAssertFalse(l.recent[0].canAllow(now: t0 + 61))
        XCTAssertFalse(l.allowAfterTheFact(id: "auth-1", now: t0 + 61))
    }

    func testAllowedOrPendingRequestsAreNotAllowable() {
        var l = PairRequestLedger()
        l.begin(id: "p", clientName: "x", source: "lan", address: nil, fingerprint: nil, keyID: keyA,
                now: t0, timeout: 60)
        XCTAssertFalse(l.allowAfterTheFact(id: "p", now: t0 + 1), "still pending")
        l.finish(id: "p", outcome: .allowed, now: t0 + 2)
        XCTAssertFalse(l.allowAfterTheFact(id: "p", now: t0 + 3), "already allowed")
    }

    func testDeniedRequestCanBeAllowed() {
        var l = PairRequestLedger()
        l.begin(id: "d", clientName: "x", source: "lan", address: nil, fingerprint: nil, keyID: keyA,
                now: t0, timeout: 60)
        l.finish(id: "d", outcome: .denied, now: t0 + 2)
        XCTAssertTrue(l.allowAfterTheFact(id: "d", now: t0 + 3))
        XCTAssertTrue(consume(&l, keyA, at: t0 + 4))
    }

    func testRecentIsCapped() {
        var l = PairRequestLedger()
        for i in 0..<(PairRequestLedger.maxRecent + 5) {
            l.begin(id: "r\(i)", clientName: "x", source: "lan", address: nil, fingerprint: nil, keyID: nil,
                    now: t0, timeout: 60)
            l.finish(id: "r\(i)", outcome: .timedOut, now: t0 + 1)
        }
        XCTAssertEqual(l.recent.count, PairRequestLedger.maxRecent)
        XCTAssertEqual(l.recent.first?.id, "r\(PairRequestLedger.maxRecent + 4)", "newest first")
    }
}
