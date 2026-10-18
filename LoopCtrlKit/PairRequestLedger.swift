import CryptoKit
import Foundation

/// Pairing requests the device user can still act on: the one waiting for an
/// answer, and the ones answered or timed out in the last few minutes.
///
/// It exists so that missing the approval notification costs nothing. A
/// request that timed out (or was refused by mistake) stays listed for
/// `recentWindow`; from the list the user can allow that client after the
/// fact, which arms a ONE-SHOT grant bound to the client's X25519 public key.
/// The client's next `/pair` with the same key is approved without a prompt
/// and without the refusal cooldown; any other key, or the same key after the
/// grant was used or ran out, is asked about as usual.
///
/// The binding is `keyID`, the full SHA-256 of the client's public key — not
/// the 8-hex `fingerprint` shown on screen, which is short enough that someone
/// could grind out a different key with the same prefix. Holding the matching
/// public key is not enough either: the device wraps the session key against
/// it, so only the holder of the private key can use what the grant hands out.
///
/// A plain (unkeyed) loopback request has no key to bind to, and its client
/// name is whatever the caller claims — any app on the device could send the
/// same one. Those are listed but can never be allowed after the fact; the
/// client has to ask again and be answered while it waits.
///
/// Plain value type with an injected clock: `AuthManager` owns one under its
/// lock, and the tests drive it directly.
struct PairRequestLedger {
    /// How long a finished request stays listed, and how long a grant armed
    /// from it waits for the client's retry.
    static let recentWindow: TimeInterval = 10 * 60
    /// Oldest finished requests beyond this are dropped.
    static let maxRecent = 20

    enum Outcome: String {
        case pending
        case allowed
        case denied
        case timedOut = "timed_out"
    }

    /// State of the after-the-fact grant on a finished request.
    enum Grant: Equatable {
        case none
        /// The user allowed this client; its next request with the same key
        /// is approved until `until`.
        case armed(until: Date)
        /// The client came back and was let in.
        case used
    }

    struct Entry: Equatable {
        let id: String
        let clientName: String
        /// `PeerSource` raw value, or "tailnet".
        let source: String
        let address: String?
        /// 8 hex characters, as the client prints it; nil for plain loopback.
        let fingerprint: String?
        /// SHA-256 of the client's public key, hex; nil for plain loopback.
        let keyID: String?
        let requestedAt: Date
        /// When an unanswered request is refused.
        let deadline: Date
        var outcome: Outcome = .pending
        var resolvedAt: Date?
        var grant: Grant = .none
        /// Let in by a grant from an earlier request rather than by a prompt.
        var autoApproved = false

        /// Whether the user can still allow this client from the list.
        func canAllow(now: Date) -> Bool {
            guard keyID != nil, grant == .none, let resolvedAt else { return false }
            guard outcome == .denied || outcome == .timedOut else { return false }
            return now < resolvedAt.addingTimeInterval(PairRequestLedger.recentWindow)
        }

        /// When the entry leaves the list.
        var listedUntil: Date {
            let finished = (resolvedAt ?? deadline).addingTimeInterval(PairRequestLedger.recentWindow)
            if case .armed(let until) = grant { return max(finished, until) }
            return finished
        }
    }

    private(set) var pending: [Entry] = []
    /// Newest first.
    private(set) var recent: [Entry] = []

    /// An operator the user approved ahead of time by confirming a remote
    /// service invite (docs/relay-enrollment.md). Standing, unlike a grant:
    /// it lasts until the connection is unbound. Bound to the full `keyID`
    /// the invite named, and honoured only for requests that arrive through
    /// the relay, so the same key on the LAN is still asked about.
    struct PreApproval: Equatable, Codable {
        let connectionID: String
        let operatorName: String
        let keyID: String
    }

    /// The `source` a relayed request carries (`PeerSource.relay`).
    static let relaySource = "relay"

    private(set) var preApprovals: [PreApproval] = []

    // MARK: - Lifecycle

    /// A request is now waiting for the user.
    mutating func begin(id: String, clientName: String, source: String, address: String?,
                        fingerprint: String?, keyID: String?, now: Date, timeout: TimeInterval) {
        pending.append(Entry(id: id, clientName: clientName, source: source, address: address,
                             fingerprint: fingerprint, keyID: keyID, requestedAt: now,
                             deadline: now.addingTimeInterval(timeout)))
    }

    /// The request was answered (`allowed` / `denied`) or ran out of time.
    /// Returns false if no such request was pending.
    @discardableResult
    mutating func finish(id: String, outcome: Outcome, now: Date) -> Bool {
        guard outcome != .pending, let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        var entry = pending.remove(at: index)
        entry.outcome = outcome
        entry.resolvedAt = now
        insertRecent(entry, now: now)
        return true
    }

    /// The device user allowed a refused or timed-out client from the list.
    /// Returns false when the entry is gone, has no key, or isn't allowable.
    @discardableResult
    mutating func allowAfterTheFact(id: String, now: Date) -> Bool {
        prune(now: now)
        guard let index = recent.firstIndex(where: { $0.id == id }),
              recent[index].canAllow(now: now) else { return false }
        recent[index].grant = .armed(until: now.addingTimeInterval(Self.recentWindow))
        return true
    }

    /// Spend the grant armed for `keyID`, if there is a live one. The match is
    /// on the full key hash only; the client name plays no part.
    ///
    /// On success the request is recorded as allowed (`autoApproved`) under
    /// `id`, and the entry the grant came from is marked used, so the same
    /// grant can never let a second request in.
    mutating func consumeGrant(keyID: String, id: String, clientName: String, source: String,
                               address: String?, fingerprint: String?, now: Date) -> Bool {
        prune(now: now)
        guard let index = recent.firstIndex(where: {
            guard $0.keyID == keyID, case .armed(let until) = $0.grant else { return false }
            return now < until
        }) else { return false }
        recent[index].grant = .used
        var entry = Entry(id: id, clientName: clientName, source: source, address: address,
                          fingerprint: fingerprint, keyID: keyID, requestedAt: now, deadline: now)
        entry.outcome = .allowed
        entry.resolvedAt = now
        entry.autoApproved = true
        insertRecent(entry, now: now)
        return true
    }

    // MARK: - Remote service pre-approvals

    /// Replace the pre-approved operators of one connection. Keys are
    /// lower-cased; anything but 64 hex characters is dropped, so a short
    /// fingerprint can never become a binding.
    mutating func setPreApprovals(connectionID: String, operators: [(name: String, keyID: String)]) {
        preApprovals.removeAll { $0.connectionID == connectionID }
        for op in operators {
            let keyID = op.keyID.lowercased()
            guard keyID.count == 64, keyID.allSatisfy({ $0.isHexDigit }),
                  !preApprovals.contains(where: { $0.connectionID == connectionID && $0.keyID == keyID })
            else { continue }
            preApprovals.append(PreApproval(connectionID: connectionID, operatorName: op.name, keyID: keyID))
        }
    }

    /// Forget a connection's pre-approvals (解除绑定). Returns how many went.
    @discardableResult
    mutating func revokePreApprovals(connectionID: String) -> Int {
        let before = preApprovals.count
        preApprovals.removeAll { $0.connectionID == connectionID }
        return before - preApprovals.count
    }

    mutating func restorePreApprovals(_ list: [PreApproval]) {
        preApprovals = list
    }

    /// Let a relayed request in if its key was pre-approved. Recorded as
    /// allowed (`autoApproved`) under `id`. Not spent: the operator may pair
    /// again later (a new computer, a revoked key) for as long as the
    /// connection is bound.
    mutating func admitPreApproved(keyID: String, source: String, id: String, clientName: String,
                                   address: String?, fingerprint: String?, now: Date) -> PreApproval? {
        guard source == Self.relaySource,
              let match = preApprovals.first(where: { $0.keyID == keyID.lowercased() }) else { return nil }
        var entry = Entry(id: id, clientName: clientName, source: source, address: address,
                          fingerprint: fingerprint, keyID: keyID, requestedAt: now, deadline: now)
        entry.outcome = .allowed
        entry.resolvedAt = now
        entry.autoApproved = true
        insertRecent(entry, now: now)
        return match
    }

    /// Drop finished entries past their window.
    mutating func prune(now: Date) {
        recent.removeAll { $0.listedUntil <= now }
    }

    private mutating func insertRecent(_ entry: Entry, now: Date) {
        recent.insert(entry, at: 0)
        prune(now: now)
        if recent.count > Self.maxRecent { recent.removeLast(recent.count - Self.maxRecent) }
    }
}

extension PairRequestLedger {
    /// The binding for a client's X25519 public key: full SHA-256, hex.
    static func keyID(forPublicKey pub: Data) -> String {
        SHA256.hash(data: pub).map { String(format: "%02x", $0) }.joined()
    }

    /// The 8-hex fingerprint the client prints and the prompt shows.
    static func fingerprint(forPublicKey pub: Data) -> String {
        String(keyID(forPublicKey: pub).prefix(8))
    }
}
