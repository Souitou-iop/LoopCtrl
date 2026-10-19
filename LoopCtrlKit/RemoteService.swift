import Foundation

// The pieces of the remote service ("远程服务") that need nothing from iOS:
// what a relay says about itself, the operator check, and the connection state
// machine. The transport behind them is `RemoteServiceClient` on the app side;
// these are tested on macOS in Tests/LoopCtrlKitTests.

/// Someone who may control this phone through a relay: a name the server
/// gives, and the key the runner will see when they pair.
struct RemoteOperator: Equatable, Codable, Identifiable {
    /// As the server names them. Display only: never matched on.
    let name: String
    /// Full SHA-256 of their X25519 public key, lower-case hex
    /// (`PairRequestLedger.keyID(forPublicKey:)`).
    let keyID: String

    var id: String { keyID }

    /// The 8-hex prefix the runner's prompt and the client print.
    var fingerprint: String { String(keyID.prefix(8)) }

    /// "a1b2 c3d4 · e5f6 0718 · …": the whole key, in groups, for comparing by eye.
    var groupedKeyID: String {
        stride(from: 0, to: keyID.count, by: 4).map { i -> String in
            let start = keyID.index(keyID.startIndex, offsetBy: i)
            let end = keyID.index(start, offsetBy: min(4, keyID.count - i))
            return String(keyID[start..<end])
        }.joined(separator: " ")
    }
}

/// What the relay says about an invite before it is redeemed
/// (`POST /v1/enroll/preview`, docs/relay-enrollment.md). None of it is
/// trusted on its own word: the operators are checked against the invite.
struct RemoteServerInfo: Equatable {
    /// Shown labelled 「由服务器提供」: the server could say anything here.
    let organization: String
    let operators: [RemoteOperator]
    /// What an operator will be able to do, as `RemoteCapability` raw values.
    let capabilities: [String]
    /// SHA-256 of the certificate's SubjectPublicKeyInfo as presented on this
    /// connection, if the transport could read it.
    let spkiSHA256: Data?
    let codeExpiresAt: Date?
}

/// What an operator can do once paired, as the confirmation screen lists it.
enum RemoteCapability: String, CaseIterable {
    case viewScreen = "view_screen"
    case control
    case launchApps = "launch_apps"
    case readText = "read_text"
}

/// The result of comparing the server's operators with the invite's.
enum OperatorCheck: Equatable {
    /// The server named exactly the invite's operators. These may be
    /// pre-approved.
    case matched([RemoteOperator])
    /// The invite carried no operators (typed in, or the text form). Shown
    /// with 「请核对操作员指纹」; nothing is pre-approved, so each operator is
    /// asked about on this phone the first time they pair.
    case unverified([RemoteOperator])
    /// The server's operators differ from the invite's: refuse to connect.
    /// `unexpected` are keys the server added, `missing` keys it left out.
    case mismatch(unexpected: [String], missing: [String])

    /// The invite's `op` against what the server returned. Matching is on the
    /// full key hash; names play no part. A server that returns no operators
    /// for an invite that names some is a mismatch too.
    static func verify(inviteKeyIDs: [String], serverOperators: [RemoteOperator]) -> OperatorCheck {
        let invite = Set(inviteKeyIDs.map { $0.lowercased() })
        let server = serverOperators.map { RemoteOperator(name: $0.name, keyID: $0.keyID.lowercased()) }
        guard !invite.isEmpty else { return .unverified(server) }
        let serverIDs = Set(server.map(\.keyID))
        let unexpected = server.map(\.keyID).filter { !invite.contains($0) }
        let missing = inviteKeyIDs.map { $0.lowercased() }.filter { !serverIDs.contains($0) }
        if !unexpected.isEmpty || !missing.isEmpty || server.isEmpty {
            return .mismatch(unexpected: unexpected, missing: missing)
        }
        return .matched(server)
    }

    /// The operators to pre-approve on 连接: only those the invite vouched for.
    var preApproved: [RemoteOperator] {
        if case .matched(let ops) = self { return ops }
        return []
    }

    var operators: [RemoteOperator] {
        switch self {
        case .matched(let ops), .unverified(let ops): return ops
        case .mismatch: return []
        }
    }
}

/// Why connecting or staying connected failed. Every case has its own
/// message in the app and is reachable from `MockRemoteServiceClient`.
enum RemoteServiceError: String, Error, Equatable, CaseIterable, Codable {
    case invalidCode = "invalid_code"
    case expiredCode = "expired_code"
    case fingerprintMismatch = "fingerprint_mismatch"
    case tlsFailure = "tls_failure"
    case pinMismatch = "pin_mismatch"
    case serverUnreachable = "server_unreachable"
    case disconnectedByServer = "disconnected_by_server"
    case invalidResponse = "invalid_response"
    /// This phone's key for the connection is gone from the Keychain (a
    /// restore to another phone, say): it can only be unbound and re-added.
    case credentialMissing = "credential_missing"
}

/// The steps of 连接, in order, for the progress list.
enum EnrollmentStep: Int, CaseIterable, Codable {
    case createKey, redeemCode, openRelay, preApprove
}

/// One connection's lifecycle. A value type with an injected clock: the app's
/// store owns one per connection and the tests drive it directly.
///
///     idle ─connect→ enrolling(step) ─established→ connected ─operatorStarted→ operated
///       ↑                 │                          │  ↑                         │
///       │               fail                    lost │  │ reconnected        lost │
///       │                 ↓                          ↓  │                         ↓
///       └──disconnect── failed            reconnecting(attempt) ──fail/closed──→ failed
struct RemoteConnectionMachine: Equatable {
    enum Phase: Equatable {
        /// Not connected; the credential may still be stored.
        case idle
        case enrolling(EnrollmentStep)
        /// An enrolled connection opening its relay channel.
        case connecting
        case connected(since: Date)
        /// An operator is driving the phone right now.
        case operated(by: String, since: Date, connectedSince: Date)
        case reconnecting(attempt: Int, connectedSince: Date?)
        case failed(RemoteServiceError)
    }

    enum Event: Equatable {
        /// Start enrolment with a new invite.
        case enroll
        case advance(EnrollmentStep)
        /// Reconnect an enrolled connection (app launch, 连接 after 断开).
        case open
        case established
        case latency(Int)
        case operatorStarted(String)
        case operatorEnded
        /// The relay channel dropped; we will try again.
        case lost
        case fail(RemoteServiceError)
        /// The user tapped 断开 or 解除绑定.
        case disconnect
    }

    /// Reconnect attempts before giving up with `serverUnreachable`.
    static let maxReconnectAttempts = 5
    static let reconnectWindow: TimeInterval = 24 * 60 * 60

    private(set) var phase: Phase = .idle
    private(set) var latencyMS: Int?
    /// When each reconnect succeeded, for 「24 小时内重连次数」.
    private(set) var reconnects: [Date] = []

    init(phase: Phase = .idle) { self.phase = phase }

    var isActive: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    var connectedSince: Date? {
        switch phase {
        case .connected(let since): return since
        case .operated(_, _, let since): return since
        case .reconnecting(_, let since): return since
        default: return nil
        }
    }

    func reconnectCount(now: Date) -> Int {
        reconnects.filter { now.timeIntervalSince($0) < Self.reconnectWindow }.count
    }

    /// Apply `event`. Returns false (and leaves the state alone) when it
    /// makes no sense in the current phase.
    @discardableResult
    mutating func handle(_ event: Event, now: Date) -> Bool {
        switch (phase, event) {
        case (.idle, .enroll), (.failed, .enroll):
            phase = .enrolling(.createKey)
        case (.enrolling(let current), .advance(let next)) where next.rawValue >= current.rawValue:
            phase = .enrolling(next)
        case (.idle, .open), (.failed, .open):
            phase = .connecting
        case (.enrolling, .established), (.connecting, .established):
            phase = .connected(since: now)
        case (.reconnecting(_, let since), .established):
            reconnects.append(now)
            reconnects.removeAll { now.timeIntervalSince($0) >= Self.reconnectWindow }
            phase = .connected(since: since ?? now)
        case (.connected, .latency(let ms)), (.operated, .latency(let ms)):
            latencyMS = ms
        case (.connected(let since), .operatorStarted(let name)):
            phase = .operated(by: name, since: now, connectedSince: since)
        case (.operated(_, _, let since), .operatorStarted(let name)):
            phase = .operated(by: name, since: now, connectedSince: since)
        case (.operated(_, _, let since), .operatorEnded):
            phase = .connected(since: since)
        case (.connected(let since), .lost), (.operated(_, _, let since), .lost):
            latencyMS = nil
            phase = .reconnecting(attempt: 1, connectedSince: since)
        case (.reconnecting(let attempt, let since), .lost):
            if attempt >= Self.maxReconnectAttempts {
                phase = .failed(.serverUnreachable)
            } else {
                phase = .reconnecting(attempt: attempt + 1, connectedSince: since)
            }
        case (.enrolling, .fail(let error)), (.connecting, .fail(let error)),
             (.connected, .fail(let error)), (.operated, .fail(let error)),
             (.reconnecting, .fail(let error)):
            latencyMS = nil
            phase = .failed(error)
        case (_, .disconnect):
            latencyMS = nil
            phase = .idle
        default:
            return false
        }
        return true
    }
}
