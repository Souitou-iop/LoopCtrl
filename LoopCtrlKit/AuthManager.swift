import CryptoKit
import Foundation

protocol AuthManagerDelegate: AnyObject {
    /// Ask the user to approve a pairing. `nearby` is true when the request
    /// arrived over peer-to-peer Wi-Fi, so the prompt can say so. Call
    /// `completion` exactly once; a request left unanswered is refused after
    /// `AuthManager.approvalTimeout` regardless.
    ///
    /// `requestID` names this request; a later expiry carries the same id.
    /// `fingerprint`: 8 hex characters the client also prints (SHA-256 of its
    /// X25519 public key, first 4 bytes), so the user can tell that the prompt
    /// belongs to their computer; nil for a plain loopback grant.
    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String,
                     requestID: String, nearby: Bool, fingerprint: String?,
                     completion: @escaping (Bool) -> Void)
    /// The same, also saying whether the request came over loopback (this
    /// device, or a computer over USB), so the prompt can name where it came
    /// from. This is the one AuthManager calls; by default it forwards to the
    /// variant above, so a delegate that has no use for `local` need not
    /// implement it.
    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String,
                     requestID: String, nearby: Bool, local: Bool, fingerprint: String?,
                     completion: @escaping (Bool) -> Void)
    /// The request timed out before the user answered; withdraw its prompt.
    func authManager(_ manager: AuthManager, didExpireAuthRequest clientName: String, requestID: String)
    /// The request was answered somewhere other than the prompt (the pending
    /// card in the LoopCtrl app); withdraw the prompt. Its `completion` will
    /// not be honoured any more.
    func authManager(_ manager: AuthManager, didWithdrawAuthRequest clientName: String, requestID: String)
}

extension AuthManagerDelegate {
    func authManager(_ manager: AuthManager, didWithdrawAuthRequest clientName: String, requestID: String) {}

    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String,
                     requestID: String, nearby: Bool, local: Bool, fingerprint: String?,
                     completion: @escaping (Bool) -> Void) {
        authManager(manager, didReceiveAuthRequest: clientName, requestID: requestID,
                    nearby: nearby, fingerprint: fingerprint, completion: completion)
    }
}

/// Outcome of a pairing request.
enum PairOutcome {
    case approved(AuthSession)
    /// The user declined, or did not answer in time.
    case denied
    /// Another request is already waiting for the user.
    case busy(retryAfter: Int)
    /// A request was just refused; new ones are held off for a while.
    case coolingDown(retryAfter: Int)
}

/// Pairing + encrypted-envelope authentication (protocol v1).
///
/// Wire-compatible with MinisApp's debug server. There is no plaintext token
/// path: every `/rpc` and `/logs*` request must arrive as a sealed envelope, and
/// the only secret a client holds is the 32-byte key K handed out at pairing.
///
/// Streaming is the one exception — `<video>` can't sign its own requests — so
/// `/stream` is authorized by a short-lived single-use ticket that the client
/// obtains over the encrypted channel. See `issueStreamTicket`.
class AuthManager {
    static let shared = AuthManager()

    /// A session expires only after this long with no successful use. Every
    /// authenticated request slides the window forward.
    static let inactivityWindow: TimeInterval = 30 * 24 * 60 * 60  // 30 days
    /// Max sessions to keep; beyond this the least-recently-active are dropped.
    static let maxSessions = 100
    /// Hard cap on remembered nonces PER SESSION — a backstop against a client
    /// that floods, not the expiry mechanism. Replay protection is time-based
    /// (see `seenNonces`), so this only needs to exceed the number of requests
    /// one client can make inside the timestamp window.
    private static let nonceCapacityPerSession = 20_000
    /// How long a pairing request waits for the user before it is refused.
    static let approvalTimeout: TimeInterval = 60
    /// After a request is refused or times out, new requests are turned away
    /// for this long, so a client cannot keep the approval prompt on screen.
    static let pairCooldown: TimeInterval = 15
    /// How often a sliding `lastActiveAt` is flushed to disk.
    private static let persistUseInterval: TimeInterval = 3600
    /// Stream tickets are single-use and die quickly.
    private static let streamTicketTTL: TimeInterval = 60

    weak var delegate: AuthManagerDelegate?

    private var sessions: [String: AuthSession] = [:]
    private let lock = NSLock()
    /// One-shot pairing bypass (see `armSingleAutoApproval`). Never persisted.
    private var autoApproveOnce = false
    /// Pairing state: at most one request waits for the user at a time.
    /// Pairing slots, one for requests from this device (loopback: the
    /// LoopCtrl app, USB) and one for everyone else, so a remote caller holding
    /// or exhausting its slot cannot lock out pairing from the device itself.
    private struct PairSlot {
        var pending = false
        var cooldownUntil = Date.distantPast
    }
    private var pairSlots: [Bool: PairSlot] = [:]   // key: local
    /// Pending and recently finished requests, for the LoopCtrl app's card
    /// and list (see `PairRequestLedger`). Guarded by `lock`.
    private var ledger = PairRequestLedger()
    /// requestID -> how to settle it. Every answer (the notification, the
    /// app's card, the timeout) goes through here, so exactly one wins.
    private var resolvers: [String: (PairRequestLedger.Outcome) -> Void] = [:]

    /// Posted (on `NotificationCenter.default`, any thread) when the pending
    /// or recent requests change, so an in-process screen can re-read them.
    static let pairingRequestsDidChange = Notification.Name("LoopCtrlPairingRequestsDidChange")

    /// Replay cache, per session: nonce -> the request timestamp it arrived with.
    ///
    /// Time-based rather than a fixed-size LRU, and scoped per token so one
    /// client can never evict another's entries. A nonce only has to be
    /// remembered as long as a replay of it could still pass the ±120s
    /// timestamp check; past that the timestamp itself rejects the replay, so
    /// the entry is dropped. This is also what upholds the nonce-uniqueness
    /// invariant the stream cipher depends on: reusing a nonce inside the
    /// window is refused rather than silently XORing two plaintexts under one
    /// keystream.
    private var seenNonces: [String: [String: Int]] = [:]
    private var lastPersistedUse: [String: Date] = [:]
    /// ticket -> (session id, expiry). Consumed on first use.
    private var streamTickets: [String: (sessionId: String, expires: Date)] = [:]

    private init() {
        loadFromKeychain()
        pruneExpired()
    }

    var activeSessions: [AuthSession] {
        pruneExpired()
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values).sorted { $0.grantedAt > $1.grantedAt }
    }

    /// Arm a ONE-SHOT auto-approval for the next pairing request.
    ///
    /// Enabled by launching the runner with `LOOPCTRL_ALLOW_AUTH_ONCE=1` (e.g. from
    /// an Xcode scheme's environment variables). It exists so a dev run can
    /// re-pair headlessly after the key store is wiped, without someone having
    /// to tap Allow on the device.
    ///
    /// Deliberately single-use and process-scoped: it is consumed by the first
    /// pairing and never rearms, so a forgotten flag degrades to "one free pair
    /// per cold start" rather than a standing bypass. It is NOT persisted.
    func armSingleAutoApproval() {
        lock.lock()
        autoApproveOnce = true
        lock.unlock()
    }

    /// Consume the one-shot grant, if armed. Returns whether it applied.
    private func takeSingleAutoApproval() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard autoApproveOnce else { return false }
        autoApproveOnce = false
        return true
    }

    // MARK: - Pairing

    /// Ask the user to approve a new client, then mint a 32-byte key.
    ///
    /// Every pairing needs the user's tap on the device; a client that already
    /// holds a key never pairs again, so nothing is lost by not remembering
    /// earlier approvals. (A name-based shortcut would be worse than useless:
    /// `clientName` is whatever the requester claims.) The exceptions are the
    /// developer's one-shot `LOOPCTRL_ALLOW_AUTH_ONCE` (never for a request
    /// from a nearby device), and a grant the user armed from the recent
    /// requests list for exactly this public key (`allowRecentRequest`).
    ///
    /// One request may wait for the user at a time, and a refused or expired
    /// request holds off new ones for `pairCooldown`; a request let in by a
    /// grant skips both.
    /// `local`: the request came over loopback (this device or USB); it has
    /// its own slot, see `pairSlots`.
    /// `keyID`: `PairRequestLedger.keyID(forPublicKey:)` of the client's key,
    /// nil for a plain loopback grant. `peer`: where it came from, for the
    /// app's card.
    func requestAuth(clientName: String, nearby: Bool, local: Bool = false, fingerprint: String? = nil,
                     keyID: String? = nil, peer: (address: String, via: String)? = nil,
                     completion: @escaping (PairOutcome) -> Void) {
        let requestID = "auth-\(UUID().uuidString)"
        let source = peer.map { Self.displaySource(address: $0.address, via: $0.via) }
            ?? (nearby ? PeerSource.nearby.rawValue : local ? PeerSource.local.rawValue : PeerSource.other.rawValue)
        lock.lock()
        let now = Date()
        if let keyID, ledger.consumeGrant(keyID: keyID, id: requestID, clientName: clientName,
                                          source: source, address: peer?.address,
                                          fingerprint: fingerprint, now: now) {
            lock.unlock()
            Self.postChange()
            // No prompt, no slot, no cooldown: the user already said yes to
            // this key. A failure to mint is still just a refusal.
            completion(createSession(clientName: clientName).map { .approved($0) } ?? .denied)
            return
        }
        var slot = pairSlots[local] ?? PairSlot()
        if slot.pending {
            lock.unlock()
            completion(.busy(retryAfter: Int(Self.approvalTimeout)))
            return
        }
        if now < slot.cooldownUntil {
            let wait = Int(slot.cooldownUntil.timeIntervalSince(now).rounded(.up))
            lock.unlock()
            completion(.coolingDown(retryAfter: max(wait, 1)))
            return
        }
        slot.pending = true
        pairSlots[local] = slot
        lock.unlock()

        if !nearby && takeSingleAutoApproval() {
            finishPairing(clientName: clientName, approved: true, local: local, completion: completion)
            return
        }
        guard let delegate = delegate else {
            // Nobody to ask means nobody approved.
            finishPairing(clientName: clientName, approved: false, local: local, completion: completion)
            return
        }

        // Exactly one of: the user's answer (notification or app card), or
        // the timeout.
        let settle: (PairRequestLedger.Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.lock.lock()
            let first = self.resolvers.removeValue(forKey: requestID) != nil
            if first { self.ledger.finish(id: requestID, outcome: outcome, now: Date()) }
            self.lock.unlock()
            guard first else { return }
            Self.postChange()
            self.finishPairing(clientName: clientName, approved: outcome == .allowed, local: local,
                               completion: completion)
        }
        lock.lock()
        ledger.begin(id: requestID, clientName: clientName, source: source, address: peer?.address,
                     fingerprint: fingerprint, keyID: keyID, now: now, timeout: Self.approvalTimeout)
        resolvers[requestID] = settle
        lock.unlock()
        Self.postChange()

        delegate.authManager(self, didReceiveAuthRequest: clientName, requestID: requestID,
                             nearby: nearby, local: local, fingerprint: fingerprint) { approved in
            settle(approved ? .allowed : .denied)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.approvalTimeout) { [weak self] in
            guard let self, self.isPending(requestID) else { return }
            self.delegate?.authManager(self, didExpireAuthRequest: clientName, requestID: requestID)
            settle(.timedOut)
        }
    }

    private func isPending(_ requestID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return resolvers[requestID] != nil
    }

    /// Answer a waiting request from the LoopCtrl app's card, as the
    /// notification would. Returns false if it was no longer waiting.
    ///
    /// Only for callers on the device itself: the in-process app, or the
    /// app over loopback in the two-IPA build (see the runner's `config`).
    @discardableResult
    func respondToPendingRequest(id: String, allow: Bool) -> Bool {
        lock.lock()
        let settle = resolvers[id]
        let name = ledger.pending.first { $0.id == id }?.clientName ?? ""
        lock.unlock()
        guard let settle else { return false }
        delegate?.authManager(self, didWithdrawAuthRequest: name, requestID: id)
        settle(allow ? .allowed : .denied)
        return true
    }

    /// Allow a refused or timed-out client from the recent list: its next
    /// request with the same public key is approved once, without a prompt
    /// or cooldown. Same callers as `respondToPendingRequest`.
    @discardableResult
    func allowRecentRequest(id: String) -> Bool {
        lock.lock()
        let ok = ledger.allowAfterTheFact(id: id, now: Date())
        lock.unlock()
        if ok { Self.postChange() }
        return ok
    }

    /// The waiting and recently finished requests (pruned to the window).
    func pairingRequests() -> (pending: [PairRequestLedger.Entry], recent: [PairRequestLedger.Entry]) {
        lock.lock(); defer { lock.unlock() }
        ledger.prune(now: Date())
        return (ledger.pending, ledger.recent)
    }

    private static func postChange() {
        NotificationCenter.default.post(name: pairingRequestsDidChange, object: nil)
    }

    /// The source shown for a request: `PeerSource`, except that a VPN
    /// tunnel address in Tailscale's ranges (100.64.0.0/10, fd7a:115c:a1e0::/48,
    /// which the project's Headscale also uses) is "tailnet". A tailnet peer
    /// reached through a DERP relay arrives the same way, so it is "tailnet" too.
    static func displaySource(address: String, via: String) -> String {
        guard via == PeerSource.vpn.rawValue else { return via }
        let lower = address.lowercased()
        if lower.hasPrefix("fd7a:115c:a1e0:") { return "tailnet" }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return "tailnet" }
        return via
    }

    private func finishPairing(clientName: String, approved: Bool, local: Bool,
                               completion: (PairOutcome) -> Void) {
        let session = approved ? createSession(clientName: clientName) : nil
        lock.lock()
        var slot = pairSlots[local] ?? PairSlot()
        slot.pending = false
        if session == nil { slot.cooldownUntil = Date().addingTimeInterval(Self.pairCooldown) }
        pairSlots[local] = slot
        lock.unlock()
        completion(session.map { .approved($0) } ?? .denied)
    }

    private func createSession(clientName: String) -> AuthSession? {
        guard let key = SecureEnvelope.randomBytes(32) else { return nil }
        let now = Date()
        let session = AuthSession(
            id: SecureEnvelope.tokenId(for: key),
            keyHex: key.hexString,
            clientName: clientName,
            grantedAt: now,
            lastActiveAt: now
        )
        lock.lock()
        sessions[session.id] = session
        lock.unlock()
        persist()
        return session
    }

    // MARK: - Envelope verification

    /// Verifies and decrypts a request envelope. On success returns the plaintext
    /// JSON-RPC body plus a sealer that encrypts the reply under the same nonce.
    ///
    /// Order matters: the MAC is checked BEFORE the replay cache is touched, so
    /// an unauthenticated caller can never perturb a legitimate client's state.
    /// Returns the VERIFIED token id so callers that mint credentials bind them
    /// to the identity this envelope actually proved, not to unverified input.
    /// `peer` is where the request came from (address, `PeerSource` raw
    /// value); it is recorded on the session for the client list.
    func openEnvelope(_ obj: [String: Any], peer: (address: String, via: String)? = nil) throws
        -> (tokId: String, plaintext: String, seal: (String) -> String) {
        let p = try SecureEnvelope.parse(obj)

        lock.lock()
        let record = sessions[p.tokId]
        lock.unlock()

        guard var session = record else {
            // Deliberately the SAME code/message as every other pre-MAC
            // rejection: distinct codes here would let an unauthenticated
            // caller enumerate which token ids exist and which are live.
            // The shared text may say what to DO (re-pair) but must never say
            // WHY this particular call failed — "no such token" and "expired"
            // have to stay indistinguishable from outside.
            throw SecureEnvelope.Failure(code: "auth_failed", message: "Authentication failed — this key is not usable. Re-pair to continue: POST /pair (the device user must tap Allow). Note a key is dropped after 30 days with no successful call, so a long-idle client must re-pair. If instead the clock is off you would get ts_skew, not this.")
        }
        let now = Date()
        if now.timeIntervalSince(session.lastActiveAt) > Self.inactivityWindow {
            lock.lock()
            sessions.removeValue(forKey: p.tokId)
            seenNonces.removeValue(forKey: p.tokId)
            lock.unlock()
            persist()
            throw SecureEnvelope.Failure(code: "auth_failed", message: "Authentication failed — this key is not usable. Re-pair to continue: POST /pair (the device user must tap Allow). Note a key is dropped after 30 days with no successful call, so a long-idle client must re-pair. If instead the clock is off you would get ts_skew, not this.")
        }
        guard abs(now.timeIntervalSince1970 - Double(p.ts)) <= SecureEnvelope.timestampWindow else {
            // Kept distinct: a client with a skewed clock must be told to fix
            // its clock, not to re-pair — and this reveals nothing about
            // whether the token exists (it is thrown before the key is used).
            throw SecureEnvelope.Failure(code: "ts_skew", message: "Timestamp outside ±120s window")
        }
        guard let key = session.key else {
            throw SecureEnvelope.Failure(code: "auth_failed", message: "Authentication failed — this key is not usable. Re-pair to continue: POST /pair (the device user must tap Allow). Note a key is dropped after 30 days with no successful call, so a long-idle client must re-pair. If instead the clock is off you would get ts_skew, not this.")
        }

        let plaintext = try SecureEnvelope.open(p, key: key)

        // Authentic — now consume a replay slot and slide the idle window.
        lock.lock()
        var seen = seenNonces[p.tokId] ?? [:]
        // Drop entries too old to be replayable: once a nonce's timestamp falls
        // outside the window, the ts check above rejects any replay of it.
        let cutoff = Int(now.timeIntervalSince1970 - SecureEnvelope.timestampWindow)
        if seen.count > 64 { seen = seen.filter { $0.value >= cutoff } }
        if seen[p.nonceHex] != nil {
            lock.unlock()
            throw SecureEnvelope.Failure(code: "nonce_replayed", message: "Duplicate nonce")
        }
        if seen.count >= Self.nonceCapacityPerSession {
            lock.unlock()
            throw SecureEnvelope.Failure(code: "nonce_flood",
                                         message: "Too many in-flight nonces; slow down")
        }
        seen[p.nonceHex] = p.ts
        seenNonces[p.tokId] = seen
        session.lastActiveAt = now
        // A new source is worth writing at once; the same one only on the
        // usual hourly flush.
        let peerChanged = peer.map { $0.address != session.lastAddress || $0.via != session.lastVia } ?? false
        if let peer {
            session.lastAddress = peer.address
            session.lastVia = peer.via
        }
        sessions[p.tokId] = session
        let needsPersist = peerChanged || (lastPersistedUse[p.tokId].map {
            now.timeIntervalSince($0) > Self.persistUseInterval
        } ?? true)
        if needsPersist { lastPersistedUse[p.tokId] = now }
        lock.unlock()
        if needsPersist { persist() }

        let seal: (String) -> String = { responseJSON in
            SecureEnvelope.seal(responseJSON: responseJSON, key: key,
                                nonce: p.nonce, nonceHex: p.nonceHex)
        }
        return (p.tokId, plaintext, seal)
    }

    // MARK: - Stream tickets

    /// Mint a single-use, short-lived ticket for `GET /stream`. Callable only
    /// from an already-authenticated (enveloped) RPC, so the ticket inherits
    /// that request's proof of key possession. `<video src>` can't sign its own
    /// request, so this is what stands in for an envelope there.
    func issueStreamTicket(forTokenId tokId: String) -> (ticket: String, expiresIn: Int)? {
        guard let raw = SecureEnvelope.randomBytes(24) else { return nil }
        let ticket = raw.hexString
        lock.lock()
        guard sessions[tokId] != nil else {
            lock.unlock()
            return nil
        }
        streamTickets = streamTickets.filter { $0.value.expires > Date() }   // opportunistic sweep
        streamTickets[ticket] = (tokId, Date().addingTimeInterval(Self.streamTicketTTL))
        lock.unlock()
        return (ticket, Int(Self.streamTicketTTL))
    }

    /// Redeem a stream ticket. Single use: a valid ticket is removed as it is
    /// accepted, so a leaked URL can't be replayed.
    func consumeStreamTicket(_ ticket: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = streamTickets.removeValue(forKey: ticket) else { return false }
        guard entry.expires > Date(), sessions[entry.sessionId] != nil else { return false }
        return true
    }

    // MARK: - Management

    /// Note where a session's client is connecting from (at pairing time,
    /// before its first request).
    func recordPeer(sessionID: String, peer: (address: String, via: String)?) {
        guard let peer else { return }
        lock.lock()
        guard var session = sessions[sessionID] else { lock.unlock(); return }
        session.lastAddress = peer.address
        session.lastVia = peer.via
        sessions[sessionID] = session
        lock.unlock()
        persist()
    }

    func revokeSession(id: String) {
        lock.lock()
        sessions.removeValue(forKey: id)
        seenNonces.removeValue(forKey: id)
        streamTickets = streamTickets.filter { $0.value.sessionId != id }
        lock.unlock()
        persist()
    }

    func revokeAll() {
        lock.lock()
        sessions.removeAll()
        seenNonces.removeAll()
        streamTickets.removeAll()
        lock.unlock()
        persist()
    }

    /// Remove long-idle sessions and cap the count. Safe to call often.
    @discardableResult
    func pruneExpired() -> Int {
        lock.lock()
        let before = sessions.count
        let now = Date()
        sessions = sessions.filter { _, s in
            now.timeIntervalSince(s.lastActiveAt) < Self.inactivityWindow
        }
        if sessions.count > Self.maxSessions {
            let keep = sessions.values
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
                .prefix(Self.maxSessions)
            sessions = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
        seenNonces = seenNonces.filter { sessions[$0.key] != nil }
        let removed = before - sessions.count
        lock.unlock()
        if removed > 0 { persist() }
        return removed
    }

    // MARK: - Persistence

    /// Callers must NOT hold `lock`.
    private func persist() {
        lock.lock()
        let list = Array(sessions.values)
        lock.unlock()
        if let data = try? JSONEncoder.iso.encode(list) {
            TokenFileStore.save(data)
        }
    }

    private func loadFromKeychain() {
        // (Name kept for call sites.) Loads from the sandbox file; also migrates a
        // legacy Keychain blob once. Records from the pre-v1 plaintext-token era
        // decode to nothing (no `key` field) and are simply dropped — those
        // clients must re-pair, which is intended: their UUID tokens carried no
        // key material and cannot drive the encrypted channel.
        var data = TokenFileStore.load()
        if data == nil, let legacy = KeychainStore.load() {
            data = legacy
            if let legacy = data { TokenFileStore.save(legacy) }
        }
        guard let data = data,
              let list = try? JSONDecoder.iso.decode([AuthSession].self, from: data) else {
            return
        }
        lock.lock()
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        lock.unlock()
    }
}

// MARK: - ISO8601 JSON coders (stable date encoding for the token blob)

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
