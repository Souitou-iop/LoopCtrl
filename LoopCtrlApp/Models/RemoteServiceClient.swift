import CryptoKit
import Foundation

/// The seam between the 远程服务 screens and whatever carries the relay
/// traffic. Today only `MockRemoteServiceClient` implements it; the relay
/// prototype (branch codex/qr-relay-feasibility) and a WebSocket tunnel are
/// meant to slot in behind the same calls. The relay protocol itself is in
/// docs/relay-enrollment.md.
///
/// The relay is untrusted. It learns this phone's public key and forwards
/// bytes; pairing and the end-to-end envelope stay between the operator's
/// client and the runner, exactly as on the LAN. Errors are always
/// `RemoteServiceError`, so each has its own message on screen.
protocol RemoteServiceClient: AnyObject {
    /// What the relay says about an invite, before anything is redeemed:
    /// organisation, operators, capabilities and the certificate it presented.
    /// Throws `invalidCode`, `expiredCode`, `tlsFailure`, `pinMismatch`,
    /// `serverUnreachable`.
    func preview(_ invite: RemoteInvite) async throws -> RemoteServerInfo

    /// Redeem the one-time code with this phone's long-lived public key. The
    /// code is spent; from now on the phone authenticates with its key.
    func redeem(_ invite: RemoteInvite, devicePublicKey: Data, deviceName: String) async throws -> RemoteEnrollment

    /// Open the relay channel for an enrolled connection. Events arrive until
    /// `close` or a terminal event (`closedByServer`, `failed`).
    func open(_ connection: RemoteConnection, deviceKey: Curve25519.Signing.PrivateKey) -> AsyncStream<RemoteChannelEvent>

    func close(connectionID: String)

    /// Tell the relay this phone is gone, so it drops the device record.
    /// Best effort: unbinding locally never waits on it.
    func unbind(_ connection: RemoteConnection, deviceKey: Curve25519.Signing.PrivateKey) async throws

    /// SHA-256 of the SubjectPublicKeyInfo the relay presents right now.
    func currentSPKI(_ connection: RemoteConnection) async throws -> Data
}

/// What redeeming a code returns.
struct RemoteEnrollment: Equatable {
    /// The relay's name for this phone.
    let deviceID: String
    let organization: String
    let operators: [RemoteOperator]
    /// The certificate the enrolment went over; pinned from then on when the
    /// invite carried no pin.
    let spkiSHA256: Data?
}

enum RemoteChannelEvent: Equatable {
    case established(latencyMS: Int?)
    case latency(Int)
    case operatorStarted(String)
    case operatorEnded
    /// One thing an operator did, for the operation log.
    case action(String)
    /// The channel dropped; the client is retrying.
    case lost
    case failed(RemoteServiceError)
}

/// A relay this phone is enrolled with. No secrets: the device key lives in
/// the Keychain (`RemoteDeviceKeyStore`), the rest in UserDefaults.
struct RemoteConnection: Identifiable, Codable, Equatable {
    let id: String
    let serverURL: URL
    var organization: String
    var deviceID: String
    var operators: [RemoteOperator]
    /// Key IDs pre-approved on the runner (the invite's `op`, confirmed).
    var preApprovedKeyIDs: [String]
    /// Whether the runner has the pre-approvals yet (it may not have been
    /// running when the invite was confirmed).
    var preApprovalSynced: Bool
    /// From the invite, or the certificate seen at enrolment.
    var spkiPin: Data?
    let enrolledAt: Date
    /// Reconnect on launch: it was connected when the app last ran.
    var autoConnect: Bool

    var serverDisplay: String {
        guard let host = serverURL.host else { return serverURL.absoluteString }
        return serverURL.port.map { "\(host):\($0)" } ?? host
    }
}

/// The phone's long-lived relay credential: an Ed25519 key per connection,
/// generated here, never exported, deleted on 解除绑定.
enum RemoteDeviceKeyStore {
    private static func account(_ connectionID: String) -> String { "relay-device-\(connectionID)" }

    static func create(connectionID: String) -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        KeychainStore.save(key.rawRepresentation, account: account(connectionID))
        return key
    }

    static func load(connectionID: String) -> Curve25519.Signing.PrivateKey? {
        KeychainStore.load(account: account(connectionID))
            .flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
    }

    static func delete(connectionID: String) {
        KeychainStore.clear(account: account(connectionID))
    }
}
