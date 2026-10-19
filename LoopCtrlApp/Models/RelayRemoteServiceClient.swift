import CryptoKit
import Foundation
import Security

/// The 远程服务 transport against a real relay: the API in
/// docs/relay-enrollment.md, served by relay/loopctrl_relay_server.py or by
/// anyone's own implementation of it.
///
/// The channel is a repeated HTTPS poll, not a held socket: each poll is one
/// request the relay holds until an operator sends something (or
/// `poll_timeout`), so nothing has to survive iOS suspending the app. What
/// arrives is an operator's `/pair` or `/rpc` body, opaque here; it goes to
/// the runner in this process with source `relay` (`InProcessRunnerControl
/// .relayed`) and the runner's answer goes back the same way. The relay never
/// sees a pairing key, and this client never opens an envelope.
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
                                operators: try Self.operators(body), spkiSHA256: api.seenSPKI)
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

/// One open channel: authenticate with the device key, poll, hand each
/// request to the runner, answer, and retry through drops.
private final class RelayChannel {
    private let connection: RemoteConnection
    private let key: Curve25519.Signing.PrivateKey
    private let emit: (RemoteChannelEvent) -> Void
    private let api: RelayHTTP
    private var token: String?
    private var pollTimeout: TimeInterval = 25
    private var established = false
    private var needsEstablished = true
    private var failures = 0

    /// Who is operating, from the relayed traffic itself: a `/pair` whose key
    /// is one of this connection's operators, and the session id (`tok`) the
    /// runner gave it, which every later envelope carries in the clear.
    private let state = NSLock()
    private var operatorByToken: [String: String] = [:]
    private var activeOperator: String?
    private var lastActivity = Date.distantPast
    private static let operatorIdle: TimeInterval = 120

    init(connection: RemoteConnection, key: Curve25519.Signing.PrivateKey,
         emit: @escaping (RemoteChannelEvent) -> Void) {
        self.connection = connection
        self.key = key
        self.emit = emit
        self.api = RelayHTTP(base: connection.serverURL, pin: connection.spkiPin)
    }

    func run() async {
        let ticker = Task { await self.tick() }
        defer { ticker.cancel() }
        while !Task.isCancelled {
            do {
                if token == nil { try await authenticate() }
                try await pollOnce()
                failures = 0
            } catch is CancellationError {
                return
            } catch let error as RemoteServiceError where [.pinMismatch, .tlsFailure, .disconnectedByServer].contains(error) {
                emit(.failed(error))
                return
            } catch {
                if Task.isCancelled { return }
                failures += 1
                // Five tries with backoff, then 无法连接服务器 (the store's
                // machine counts the same drops for its reconnect state).
                if failures > RemoteConnectionMachine.maxReconnectAttempts {
                    emit(.failed(.serverUnreachable))
                    return
                }
                if established { emit(.lost) }
                // Sign in again on the way back, so 已连接 shows as soon as
                // the relay answers rather than after the next held poll.
                token = nil
                needsEstablished = true
                let delay = min(16, pow(2, Double(failures - 1)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Challenge, signature, device token. Reports the round trip as latency.
    private func authenticate() async throws {
        let started = Date()
        let (status, body) = try await api.post("/v1/device/challenge", ["device_id": connection.deviceID])
        let rtt = Int(Date().timeIntervalSince(started) * 1000)
        if status == 404 { throw RemoteServiceError.disconnectedByServer }   // unbound on the server
        guard status == 200, let nonce = body["nonce"] as? String else { throw RelayHTTP.Retry() }
        let message = "loopctrl-channel-v1\n\(nonce)\n\(connection.serverDisplay)"
        let sig = try key.signature(for: Data(message.utf8))
        let (s2, session) = try await api.post("/v1/device/session", [
            "device_id": connection.deviceID, "nonce": nonce, "sig": RelayHTTP.base64url(sig),
        ])
        if s2 == 404 { throw RemoteServiceError.disconnectedByServer }
        guard s2 == 200, let t = session["device_token"] as? String else { throw RelayHTTP.Retry() }
        token = t
        if let p = session["poll_timeout"] as? Double, p > 0 { pollTimeout = p }
        // First sign-in, or back after a drop: connected. A token that just
        // lapsed while all was well only refreshes the latency.
        if needsEstablished {
            needsEstablished = false
            established = true
            emit(.established(latencyMS: rtt))
        } else {
            emit(.latency(rtt))
        }
    }

    private func pollOnce() async throws {
        guard let token else { return }
        let (status, body) = try await api.send("POST", "/v1/device/poll", Data(),
                                                headers: ["Authorization": "Bearer \(token)"],
                                                timeout: pollTimeout + 15)
        switch status {
        case 204: return
        case 401: self.token = nil; return   // lapsed: sign in again with the key
        case 200: break
        default: throw RelayHTTP.Retry()
        }
        guard let work = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let requestID = work["request_id"] as? String, let path = work["path"] as? String,
              let b64 = work["body_b64"] as? String, let payload = Data(base64Encoded: b64) else {
            throw RelayHTTP.Retry()
        }
        // Answer in the background and poll again at once: a pairing prompt
        // can wait a minute for the user, and nothing else should wait with it.
        Task { await self.answer(requestID: requestID, path: path, payload: payload, token: token) }
    }

    private func answer(requestID: String, path: String, payload: Data, token: String) async {
        let (status, reply) = await RelayRunnerBridge.deliver(path: path, body: payload, connection: connection)
        observe(path: path, request: payload, status: status, reply: reply)
        let response: [String: Any] = [
            "request_id": requestID, "status": status,
            "body_b64": reply.base64EncodedString(), "content_type": "application/json",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        _ = try? await api.send("POST", "/v1/device/response", data,
                                headers: ["Authorization": "Bearer \(self.token ?? token)"])
    }

    /// Operator presence for the home card and the log. Display only: what
    /// an operator may do is decided by pairing and the envelope, not here.
    private func observe(path: String, request: Data, status: Int, reply: Data) {
        let req = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
        state.lock()
        var started: String?
        if path == "/pair", status == 200,
           let pub = (req?["pub"] as? String).flatMap({ Data(base64Encoded: $0) }),
           let tok = ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["tok"] as? String {
            let keyID = PairRequestLedger.keyID(forPublicKey: pub)
            let name = connection.operators.first { $0.keyID == keyID }?.name
                ?? (req?["client_name"] as? String) ?? keyID.prefix(8).description
            operatorByToken[tok] = name
            started = name
        } else if path == "/rpc", let tok = req?["tok"] as? String, let name = operatorByToken[tok] {
            started = name
        }
        if let name = started {
            lastActivity = Date()
            if activeOperator != name {
                activeOperator = name
                state.unlock()
                emit(.operatorStarted(name))
                return
            }
        }
        state.unlock()
    }

    /// Ends an operator's session after a quiet spell; refreshes latency.
    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            state.lock()
            let ended = activeOperator != nil && Date().timeIntervalSince(lastActivity) > Self.operatorIdle
            if ended { activeOperator = nil }
            state.unlock()
            if ended { emit(.operatorEnded) }
            guard established else { continue }
            let started = Date()
            if let (status, _) = try? await api.send("GET", "/healthz", nil, timeout: 10), status == 200 {
                emit(.latency(Int(Date().timeIntervalSince(started) * 1000)))
            }
        }
    }
}

/// Hands a relayed request to the runner and waits for its answer.
enum RelayRunnerBridge {
    static func deliver(path: String, body: Data, connection: RemoteConnection) async -> (Int, Data) {
        #if LOOPCTRL_ALL_IN_ONE
        // Longer than a pairing prompt waits (60 s), shorter than the relay
        // waits for us.
        let timeout: TimeInterval = path == "/pair" ? 80 : 60
        return await withCheckedContinuation { continuation in
            let once = NSLock()
            var done = false
            func finish(_ status: Int, _ data: Data) {
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                done = true
                continuation.resume(returning: (status, data))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(504, Self.error("loopctrl_timeout", "LoopCtrl did not answer in time"))
            }
            // No observer until the runner has started: the timeout answers.
            NotificationCenter.default.post(name: InProcessRunnerControl.relayed, object: nil, userInfo: [
                "path": path, "body": body, "connection": connection.id,
                "server": connection.serverDisplay,
                "reply": { (status: Int, data: Data) in finish(status, data) } as (Int, Data) -> Void,
            ])
        }
        #else
        // The two-app build's runner is another process; it has no relayed
        // entry point yet, and loopback would make the request `local`.
        return (503, error("loopctrl_unavailable", "This build cannot take relayed requests"))
        #endif
    }

    private static func error(_ code: String, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])) ?? Data()
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

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard SecTrustEvaluateWithError(trust, nil) else {
            refusal = .tlsFailure
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let spki = Self.spkiSHA256(trust)
        seenSPKI = spki
        if let pin, spki != pin {
            refusal = .pinMismatch
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
