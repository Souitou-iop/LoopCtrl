import CryptoKit
import Foundation

/// A minimal outbound client for the Phase 0 LoopCtrl relay.
///
/// The relay treats the HTTP request and response bodies as opaque bytes. This
/// client only adds the relay's bearer credentials and sends the existing
/// `/rpc` envelope to the local LoopCtrl server unchanged. It deliberately has
/// no QR scanner: a future enrollment UI can construct `RelayEnrollment`.
///
/// The client is feature-gated by construction. Nothing starts it unless the
/// host explicitly creates it and calls `start()`.
@available(iOS 16.0, *)
final class RelayRPCClient {
    enum State: Equatable {
        case idle
        case registering
        case polling
        case forwarding
        case waitingToReconnect(String)
        case failed(String)
        case stopped
    }

    struct Configuration {
        var enrollment: RelayEnrollment
        var clientName: String
        var rpcPort: UInt16
        /// Fallback only. Registration's server-advertised `poll_timeout` takes
        /// precedence, so the client cannot outlive the server wait by accident.
        var pollTimeout: TimeInterval
        /// Allowance for response generation after any server-held poll wait.
        var pollResponseGrace: TimeInterval
        var requestTimeout: TimeInterval

        init(
            enrollment: RelayEnrollment,
            clientName: String = "LoopCtrl",
            rpcPort: UInt16 = ServerPort.defaultPort,
            pollTimeout: TimeInterval = 25,
            pollResponseGrace: TimeInterval = 15,
            requestTimeout: TimeInterval = 90
        ) {
            self.enrollment = enrollment
            self.clientName = clientName
            self.rpcPort = rpcPort
            self.pollTimeout = pollTimeout
            self.pollResponseGrace = pollResponseGrace
            self.requestTimeout = requestTimeout
        }
    }

    private struct Registration {
        let deviceID: String
        let deviceToken: String
        let pollTimeout: TimeInterval
    }

    private struct PollWork {
        let requestID: String
        let body: Data
    }

    private struct HTTPResult {
        let status: Int
        let body: Data
        let contentType: String
    }

    var onState: ((State) -> Void)?
    var onLog: ((String) -> Void)?

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.openminis.loopctrl.relay-client")
    private var lifetimeTask: Task<Void, Never>?
    private var started = false
    private var cancelled = false
    private let cancelLock = NSLock()

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        lifetimeTask?.cancel()
    }

    /// Starts a loop of separate HTTP poll requests. Calling this again while
    /// it is running is harmless. `stop()` is the only way to end the loop.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.setCancelled(false)
            self.emit(.idle)
            self.lifetimeTask = Task { [weak self] in
                await self?.runLoop()
            }
        }
    }

    /// Stops the loop and cancels its in-flight URLSession/Task work.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setCancelled(true)
            self.lifetimeTask?.cancel()
            self.lifetimeTask = nil
            self.started = false
            self.emit(.stopped)
        }
    }

    private func runLoop() async {
        var registration: Registration?
        var reconnectAttempt = 0

        while !Task.isCancelled && !isCancelled {
            if registration == nil {
                emit(.registering)
                do {
                    registration = try await register()
                    reconnectAttempt = 0
                } catch let error as RelayFailure {
                    if case .registrationRejected = error {
                        emit(.failed("relay rejected this enrollment token"))
                        break
                    }
                    registration = nil
                    reconnectAttempt += 1
                    emit(.waitingToReconnect(error.localizedDescription))
                    do {
                        try await sleep(seconds: reconnectDelay(attempt: reconnectAttempt))
                    } catch {
                        break
                    }
                    continue
                } catch {
                    registration = nil
                    reconnectAttempt += 1
                    emit(.waitingToReconnect(error.localizedDescription))
                    do {
                        try await sleep(seconds: reconnectDelay(attempt: reconnectAttempt))
                    } catch {
                        break
                    }
                    continue
                }
            }

            guard let active = registration else { continue }
            emit(.polling)
            do {
                let work = try await poll(active)
                reconnectAttempt = 0
                guard let work else {
                    continue
                }
                emit(.forwarding)
                do {
                    let localResponse = try await forwardToLoopCtrl(work.body)
                    try await postResponse(work: work, response: localResponse,
                                           deviceToken: active.deviceToken)
                } catch {
                    // A local endpoint failure must still release the operator
                    // request. The error is intentionally generic: relay logs
                    // and operator responses must not contain secrets.
                    let failure = HTTPResult(
                        status: 502,
                        body: Data(#"{"error":"loopctrl_unavailable"}"#.utf8),
                        contentType: "application/json"
                    )
                    try? await postResponse(work: work, response: failure,
                                            deviceToken: active.deviceToken)
                    throw error
                }
            } catch is CancellationError {
                break
            } catch let error as RelayFailure {
                if Self.sessionIsLost(after: error) {
                    // The short-lived device token expired. The enrollment token
                    // is not reusable, so this loop cannot silently re-register.
                    emit(.failed("relay device session expired; re-enroll"))
                    break
                }
                // Keep the device session: the enrollment token was consumed by
                // registration, so dropping it here would turn any network
                // blip into a permanent 401 on re-register.
                reconnectAttempt += 1
                emit(.waitingToReconnect(error.localizedDescription))
                do {
                    try await sleep(seconds: reconnectDelay(attempt: reconnectAttempt))
                } catch {
                    break
                }
            } catch {
                reconnectAttempt += 1
                emit(.waitingToReconnect(error.localizedDescription))
                do {
                    try await sleep(seconds: reconnectDelay(attempt: reconnectAttempt))
                } catch {
                    break
                }
            }
        }
        emit(.stopped)
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    private func setCancelled(_ value: Bool) {
        cancelLock.lock()
        cancelled = value
        cancelLock.unlock()
    }

    /// Only a relay that no longer knows this device token ends the session.
    /// Transport errors, 5xx, and local LoopCtrl failures keep the token and
    /// retry the poll; re-registering would need a fresh enrollment token.
    static func sessionIsLost(after error: RelayFailure) -> Bool {
        if case .unauthorized = error { return true }
        return false
    }

    private func reconnectDelay(attempt: Int) -> TimeInterval {
        min(30, 2 * Double(max(attempt, 1)))
    }

    /// The poll request must outlive the server's hold. Exposed as a static
    /// function so a compile-time test can assert the arithmetic.
    static func pollRequestTimeout(
        serverPollTimeout: TimeInterval,
        responseGrace: TimeInterval
    ) -> TimeInterval {
        max(serverPollTimeout + responseGrace, 12)
    }

    private func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }

    private func register() async throws -> Registration {
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["name": configuration.clientName]
        ) else {
            throw RelayFailure.protocolFailure("could not encode registration")
        }
        let result = try await request(
            method: "POST",
            path: "/v1/device/register",
            bearer: configuration.enrollment.token,
            body: body,
            timeout: configuration.requestTimeout
        )
        guard result.status == 201 || result.status == 200 else {
            if result.status == 401 || result.status == 403 {
                throw RelayFailure.registrationRejected
            }
            throw RelayFailure.server(status: result.status)
        }
        let object = try jsonObject(result.body)
        guard let deviceID = object["device_id"] as? String,
              let deviceToken = object["device_token"] as? String,
              !deviceID.isEmpty, !deviceToken.isEmpty else {
            throw RelayFailure.protocolFailure("registration response is malformed")
        }
        // Optional pinning: a QR payload may name the device id it was minted
        // for. Without one, accept the random id the relay assigned.
        if let expected = configuration.enrollment.expectedDeviceID, expected != deviceID {
            throw RelayFailure.protocolFailure("relay device id does not match enrollment")
        }
        let advertised = (object["poll_timeout"] as? NSNumber)?.doubleValue
        let pollTimeout = advertised ?? configuration.pollTimeout
        guard pollTimeout >= 0 else {
            throw RelayFailure.protocolFailure("relay poll timeout is malformed")
        }
        log("relay device session registered (poll wait \(pollTimeout)s)")
        return Registration(
            deviceID: deviceID,
            deviceToken: deviceToken,
            pollTimeout: pollTimeout
        )
    }

    private func poll(_ active: Registration) async throws -> PollWork? {
        let result = try await request(
            method: "POST",
            path: "/v1/device/poll",
            bearer: active.deviceToken,
            body: nil,
            timeout: Self.pollRequestTimeout(
                serverPollTimeout: active.pollTimeout,
                responseGrace: configuration.pollResponseGrace
            )
        )
        if result.status == 204 {
            return nil
        }
        guard result.status == 200 else {
            if result.status == 401 || result.status == 404 {
                throw RelayFailure.unauthorized
            }
            throw RelayFailure.server(status: result.status)
        }
        let object = try jsonObject(result.body)
        guard let requestID = object["request_id"] as? String,
              let encoded = object["body_b64"] as? String,
              let body = Data(base64Encoded: encoded) else {
            throw RelayFailure.protocolFailure("poll response is malformed")
        }
        guard requestID.count >= 16,
              requestID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
              }) else {
            throw RelayFailure.protocolFailure("relay request id is malformed")
        }
        return PollWork(requestID: requestID, body: body)
    }

    private func forwardToLoopCtrl(_ envelope: Data) async throws -> HTTPResult {
        guard let url = URL(string: "http://127.0.0.1:\(configuration.rpcPort)/rpc") else {
            throw RelayFailure.protocolFailure("invalid local LoopCtrl URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = envelope
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    private func postResponse(
        work: PollWork,
        response: HTTPResult,
        deviceToken: String
    ) async throws {
        let object: [String: Any] = [
            "request_id": work.requestID,
            "status": response.status,
            "body_b64": response.body.base64EncodedString(),
            "content_type": response.contentType,
        ]
        let body = try JSONSerialization.data(withJSONObject: object)
        let result = try await request(
            method: "POST",
            path: "/v1/device/response",
            bearer: deviceToken,
            body: body,
            timeout: configuration.requestTimeout
        )
        guard result.status == 200 else {
            if result.status == 401 || result.status == 404 {
                throw RelayFailure.unauthorized
            }
            throw RelayFailure.server(status: result.status)
        }
    }

    private func request(
        method: String,
        path: String,
        bearer: String,
        body: Data?,
        timeout: TimeInterval
    ) async throws -> HTTPResult {
        guard let url = Self.endpoint(base: configuration.enrollment.baseURL, path: path) else {
            throw RelayFailure.protocolFailure("invalid relay URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = max(timeout, 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    /// `base` may carry a path prefix (a relay mounted at
    /// `https://host/loopctrl-relay/` behind a reverse proxy); `path` is the
    /// relay route, e.g. `/v1/device/poll`.
    static func endpoint(base: URL, path: String) -> URL? {
        var prefix = base.absoluteString
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return URL(string: prefix + path)
    }

    private func perform(_ request: URLRequest) async throws -> HTTPResult {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RelayFailure.protocolFailure("relay returned a non-HTTP response")
            }
            return HTTPResult(
                status: http.statusCode,
                body: data,
                contentType: http.value(forHTTPHeaderField: "Content-Type")
                    ?? "application/octet-stream"
            )
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CancellationError()
            }
            throw RelayFailure.transport(error.code.rawValue)
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw RelayFailure.protocolFailure("relay response was not a JSON object")
        }
        return dictionary
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    private func emit(_ state: State) {
        onState?(state)
    }
}

enum RelayEnrollmentError: LocalizedError {
    case insecureTransport
    case invalidToken
    case invalidDeviceID
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .insecureTransport:
            return "Relay enrollment requires HTTPS, except for a loopback development server."
        case .invalidToken:
            return "Relay enrollment token is malformed."
        case .invalidDeviceID:
            return "Expected relay device id is malformed."
        case .invalidBaseURL:
            return "Relay base URL must be an http(s) URL with no query, fragment, or credentials."
        }
    }
}

/// The short-lived value a future QR scanner or local test would provide.
/// This type does not persist it.
struct RelayEnrollment {
    let baseURL: URL
    let token: String
    /// Optional id a short-lived enrollment was pre-bound to. Nil lets the
    /// relay assign a random id; a future QR payload can pin it.
    let expectedDeviceID: String?

    init(baseURL: URL, token: String, expectedDeviceID: String? = nil) throws {
        let scheme = baseURL.scheme?.lowercased()
        let host = baseURL.host?.lowercased()
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw RelayEnrollmentError.insecureTransport
        }
        // A path prefix is allowed (a relay behind a reverse-proxy location);
        // query, fragment, credentials, and dot segments are not.
        guard scheme != nil, host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              !baseURL.pathComponents.contains(".."),
              !baseURL.pathComponents.contains(".") else {
            throw RelayEnrollmentError.invalidBaseURL
        }

        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        guard token.count >= 20,
              token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw RelayEnrollmentError.invalidToken
        }
        if let expectedDeviceID {
            guard expectedDeviceID.count >= 8,
                  expectedDeviceID.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0)
                  }) else {
                throw RelayEnrollmentError.invalidDeviceID
            }
        }

        self.baseURL = baseURL
        self.token = token
        self.expectedDeviceID = expectedDeviceID
    }
}

enum RelayFailure: LocalizedError {
    case registrationRejected
    case unauthorized
    case server(status: Int)
    case transport(Int)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .registrationRejected:
            return "Relay rejected the enrollment token."
        case .unauthorized:
            return "Relay device session expired."
        case .server(let status):
            return "Relay returned HTTP \(status)."
        case .transport(let code):
            return "Relay transport failed (URLError \(code))."
        case .protocolFailure(let message):
            return "Relay protocol failure: \(message)."
        }
    }
}
