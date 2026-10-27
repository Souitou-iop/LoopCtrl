import CryptoKit
import Foundation
import Security

/// The 远程服务 transport against a real relay: the API in
/// docs/relay-enrollment.md, served by the reference relay in server/connect/relay
/// (connect/relay/loopctrl_relay_server.py) or by anyone's own implementation
/// of it.
///
/// The channel is the tunnel in docs/remote-control.md (`RelayChannel`): one
/// WebSocket the relay opens HTTP exchanges on, each carried to the runner's
/// relay ingress on loopback with source `relay`. The relay never sees a
/// pairing key, and this client never opens an envelope.
final class RelayRemoteServiceClient: RemoteServiceClient {
    private var channels: [String: Task<Void, Never>] = [:]
    private let lock = NSLock()

    // MARK: - Enrolment

    func preview(_ invite: RemoteInvite) async throws -> RemoteServerInfo {
        let api = RelayHTTP(base: invite.serverURL, pin: invite.spkiPin)
        let (status, body) = try await api.post("/v1/enroll/preview", ["code": invite.code])
        guard status == 200 else { throw Self.enrollError(status, body) }
        return RemoteServerInfo(
            organization: body["organization"] as? String ?? "",
            operators: try Self.operators(body),
            capabilities: body["capabilities"] as? [String] ?? [],
            spkiSHA256: api.seenSPKI,
            codeExpiresAt: (body["code_expires_at"] as? Double).map(Date.init(timeIntervalSince1970:)))
    }

    func redeem(_ invite: RemoteInvite, deviceKey: Curve25519.Signing.PrivateKey,
                deviceName: String) async throws -> RemoteEnrollment {
        let api = RelayHTTP(base: invite.serverURL, pin: invite.spkiPin)
        let message = "loopctrl-enroll-v1\n\(invite.code)\n\(invite.serverDisplay)"
        let proof = try deviceKey.signature(for: Data(message.utf8))
        let (status, body) = try await api.post("/v1/enroll/redeem", [
            "code": invite.code,
            "device_public_key": RelayHTTP.base64url(deviceKey.publicKey.rawRepresentation),
            "device_name": deviceName,
            "proof": RelayHTTP.base64url(proof),
        ])
        guard status == 200 else { throw Self.enrollError(status, body) }
        guard let deviceID = body["device_id"] as? String, !deviceID.isEmpty else {
            throw RemoteServiceError.invalidResponse
        }
        return RemoteEnrollment(deviceID: deviceID, organization: body["organization"] as? String ?? "",
                                operators: try Self.operators(body), spkiSHA256: api.seenSPKI,
                                publicURL: (body["public_url"] as? String).flatMap(URL.init(string:)))
    }

    // MARK: - Channel

    func open(_ connection: RemoteConnection, deviceKey: Curve25519.Signing.PrivateKey) -> AsyncStream<RemoteChannelEvent> {
        close(connectionID: connection.id)
        return AsyncStream { continuation in
            let channel = RelayChannel(connection: connection, key: deviceKey, emit: { continuation.yield($0) })
            let task = Task {
                await channel.run()
                continuation.finish()
            }
            lock.lock()
            channels[connection.id] = task
            lock.unlock()
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close(connectionID: String) {
        lock.lock()
        let task = channels.removeValue(forKey: connectionID)
        lock.unlock()
        task?.cancel()
    }

    func unbind(_ connection: RemoteConnection, deviceKey: Curve25519.Signing.PrivateKey) async throws {
        close(connectionID: connection.id)
        let ts = Int(Date().timeIntervalSince1970)
        let message = "loopctrl-unbind-v1\n\(connection.deviceID)\n\(ts)\n\(connection.serverDisplay)"
        let sig = try deviceKey.signature(for: Data(message.utf8))
        let api = RelayHTTP(base: connection.serverURL, pin: connection.spkiPin)
        let (status, _) = try await api.send("DELETE", "/v1/devices/\(connection.deviceID)", nil,
                                             headers: ["Authorization": "LoopCtrl-Device sig=\(RelayHTTP.base64url(sig)), ts=\(ts)"])
        // Already gone on the server is as good as removed.
        guard status == 200 || status == 404 else { throw RemoteServiceError.invalidResponse }
    }

    func currentSPKI(_ connection: RemoteConnection) async throws -> Data {
        let api = RelayHTTP(base: connection.serverURL, pin: nil)
        _ = try await api.send("GET", "/healthz", nil)
        guard let spki = api.seenSPKI else { throw RemoteServiceError.tlsFailure }
        return spki
    }

    // MARK: - Helpers

    private static func operators(_ body: [String: Any]) throws -> [RemoteOperator] {
        guard let list = body["operators"] as? [[String: Any]] else { throw RemoteServiceError.invalidResponse }
        return try list.map { op in
            guard let keyID = (op["key_id"] as? String)?.lowercased(), keyID.count == 64,
                  keyID.allSatisfy(\.isHexDigit) else { throw RemoteServiceError.invalidResponse }
            return RemoteOperator(name: op["name"] as? String ?? "", keyID: keyID)
        }
    }

    private static func enrollError(_ status: Int, _ body: [String: Any]) -> RemoteServiceError {
        switch (status, body["error"] as? String) {
        case (_, "invalid_code"), (404, _): return .invalidCode
        case (_, "expired_code"), (410, _): return .expiredCode
        case (429, _), (500..., _): return .serverUnreachable
        default: return .invalidResponse
        }
    }
}

/// HTTPS to one relay: JSON in and out, the certificate's SPKI recorded,
/// and the invite's pin (if any) enforced before a byte is sent.
final class RelayHTTP: NSObject, URLSessionDelegate {
    /// A transient failure: retry.
    struct Retry: Error {}

    let base: URL
    let pin: Data?
    private(set) var seenSPKI: Data?
    private var refusal: RemoteServiceError?
    private lazy var session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.connectionProxyDictionary = [:]
        return c
    }(), delegate: self, delegateQueue: nil)

    init(base: URL, pin: Data?) {
        self.base = base
        self.pin = pin
    }

    deinit { session.invalidateAndCancel() }

    func post(_ path: String, _ json: [String: Any]) async throws -> (Int, [String: Any]) {
        let (status, data) = try await send("POST", path, try JSONSerialization.data(withJSONObject: json))
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    func send(_ method: String, _ path: String, _ body: Data?, headers: [String: String] = [:],
              timeout: TimeInterval = 20) async throws -> (Int, Data) {
        var prefix = base.absoluteString
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard let url = URL(string: prefix + path) else { throw RemoteServiceError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let error as URLError {
            if let refusal { throw refusal }
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected:
                throw RemoteServiceError.tlsFailure
            default:
                throw RemoteServiceError.serverUnreachable
            }
        }
    }

    /// The tunnel WebSocket at `path`, over this session (so the pin holds).
    func webSocket(_ path: String, headers: [String: String]) -> URLSessionWebSocketTask? {
        var prefix = base.absoluteString
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard var components = URLComponents(string: prefix + path) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        return task
    }

    /// After a failed call: the certificate refusal, if that was the cause.
    func refusalOrRetry() throws -> Error {
        refusal ?? Retry()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let spki = Self.spkiSHA256(trust)
        seenSPKI = spki
        if let pin {
            // A pinned key is the trust anchor: the invite carried it out of
            // band, which says more than any CA could. So a self-hosted relay
            // with its own certificate works when its invite pins it.
            guard spki == pin else {
                refusal = .pinMismatch
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard SecTrustEvaluateWithError(trust, nil) else {
            refusal = .tlsFailure
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// SHA-256 of the leaf certificate's DER SubjectPublicKeyInfo, as
    /// `openssl x509 -pubkey | openssl pkey -pubin -outform der | sha256`
    /// prints it. Security only hands out the bare key, so the ASN.1 header
    /// for its type is put back in front.
    static func spkiSHA256(_ trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attrs[kSecAttrKeyType] as? String,
              let bits = attrs[kSecAttrKeySizeInBits] as? Int else { return nil }
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String, rsa = kSecAttrKeyTypeRSA as String
        let header: [UInt8]
        switch (type, bits) {
        case (ec, 256):
            header = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                      0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        case (ec, 384):
            header = [0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                      0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00]
        case (rsa, 2048):
            header = [0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d,
                      0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00]
        case (rsa, 4096):
            header = [0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d,
                      0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00]
        default:
            return nil
        }
        return Data(SHA256.hash(data: Data(header) + raw))
    }

    static func base64url(_ data: Data) -> String { RemoteInvite.base64url(data) }
}
