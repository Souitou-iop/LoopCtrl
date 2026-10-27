import CryptoKit
import Foundation
import Network

/// One open relay connection: sign in with the device key, hold the tunnel
/// WebSocket (docs/remote-control.md), and carry every exchange the relay
/// opens to the runner's relay ingress on loopback. Retries through drops.
///
/// The runner sees each exchange as an ordinary HTTP request from source
/// `relay`, so the public address behaves exactly like the LAN one: the
/// control page, pairing, the encrypted RPC, the screen stream.
final class RelayChannel {
    private let connection: RemoteConnection
    private let key: Curve25519.Signing.PrivateKey
    private let emit: (RemoteChannelEvent) -> Void
    private let api: RelayHTTP
    private var established = false
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
                let (token, rtt) = try await authenticate()
                try await runTunnel(token: token, rtt: rtt)
            } catch is CancellationError {
                return
            } catch let error as RemoteServiceError where [.pinMismatch, .tlsFailure, .disconnectedByServer].contains(error) {
                emit(.failed(error))
                return
            } catch is TokenLapsed {
                continue   // sign in again at once
            } catch {
                if Task.isCancelled { return }
                if established {
                    // Up a while, then dropped: start the retries afresh.
                    established = false
                    failures = 0
                    emit(.lost)
                }
                failures += 1
                // Five tries with backoff, then 无法连接服务器 (the store's
                // machine counts the same drops for its reconnect state).
                if failures > RemoteConnectionMachine.maxReconnectAttempts {
                    emit(.failed(.serverUnreachable))
                    return
                }
                let delay = min(16, pow(2, Double(failures - 1)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private struct TokenLapsed: Error {}

    /// Challenge, signature, device token; the round trip is the latency.
    private func authenticate() async throws -> (String, Int) {
        let started = Date()
        let (status, body) = try await api.post("/v1/device/challenge", ["device_id": connection.deviceID])
        if status == 404 { throw RemoteServiceError.disconnectedByServer }   // unbound on the server
        guard status == 200, let nonce = body["nonce"] as? String else { throw RelayHTTP.Retry() }
        let message = "loopctrl-channel-v1\n\(nonce)\n\(connection.serverDisplay)"
        let sig = try key.signature(for: Data(message.utf8))
        let (s2, session) = try await api.post("/v1/device/session", [
            "device_id": connection.deviceID, "nonce": nonce, "sig": RelayHTTP.base64url(sig),
        ])
        if s2 == 404 { throw RemoteServiceError.disconnectedByServer }
        guard s2 == 200, let token = session["device_token"] as? String else { throw RelayHTTP.Retry() }
        return (token, Int(Date().timeIntervalSince(started) * 1000))
    }

    private func runTunnel(token: String, rtt: Int) async throws {
        guard let task = api.webSocket("/v1/device/tunnel", headers: [
            "Authorization": "Bearer \(token)", "Sec-WebSocket-Protocol": "loopctrl-tunnel-v1",
        ]) else { throw RemoteServiceError.invalidResponse }
        task.resume()
        let mux = TunnelMux(task: task, connectionID: connection.id, server: connection.serverDisplay,
                            port: ServerPort.relayIngress(for: ServerPort.stored)) { [weak self] path, request, status, reply in
            self?.observe(path: path, request: request, status: status, reply: reply)
        }
        defer {
            mux.closeAll()
            task.cancel(with: .goingAway, reason: nil)
        }
        let first: URLSessionWebSocketTask.Message
        do {
            first = try await task.receive()
        } catch {
            if (task.response as? HTTPURLResponse)?.statusCode == 401 { throw TokenLapsed() }
            throw try api.refusalOrRetry()
        }
        guard case .string(let text) = first,
              let hello = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              hello["type"] as? String == "hello" else { throw RelayHTTP.Retry() }
        if let s = hello["public_url"] as? String, let url = URL(string: s) {
            emit(.publicURL(url))
        }
        if established {
            emit(.latency(rtt))
        } else {
            established = true
            failures = 0
            emit(.established(latencyMS: rtt))
        }

        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                task.sendPing { error in if error != nil { task.cancel(with: .goingAway, reason: nil) } }
            }
        }
        defer { pinger.cancel() }
        while true {
            try Task.checkCancellation()
            let message = try await task.receive()
            if case .data(let data) = message, let frame = TunnelFrame(decoding: data) {
                mux.handle(frame)
            }
        }
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

    /// Forgets the operator after a quiet spell; true if one was active.
    private func endIdleOperator() -> Bool {
        state.lock()
        defer { state.unlock() }
        guard activeOperator != nil, Date().timeIntervalSince(lastActivity) > Self.operatorIdle else { return false }
        activeOperator = nil
        return true
    }

    /// Ends an operator's session after a quiet spell; refreshes latency.
    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            if endIdleOperator() { emit(.operatorEnded) }
            guard established else { continue }
            let started = Date()
            if let (status, _) = try? await api.send("GET", "/healthz", nil, timeout: 10), status == 200 {
                emit(.latency(Int(Date().timeIntervalSince(started) * 1000)))
            }
        }
    }
}

/// The streams of one tunnel. All state lives on `queue`, which is also the
/// queue every local connection runs on.
private final class TunnelMux {
    typealias Observer = (_ path: String, _ request: Data, _ status: Int, _ reply: Data) -> Void

    let queue = DispatchQueue(label: "top.ebato.loopctrl.tunnel")
    private let task: URLSessionWebSocketTask
    private let connectionID: String
    private let server: String
    private let port: UInt16
    private let observer: Observer
    private var streams: [UInt32: LocalStream] = [:]

    init(task: URLSessionWebSocketTask, connectionID: String, server: String, port: UInt16, observer: @escaping Observer) {
        self.task = task
        self.connectionID = connectionID
        self.server = server
        self.port = port
        self.observer = observer
    }

    func send(_ frame: TunnelFrame) {
        task.send(.data(frame.encoded)) { [task] error in
            if error != nil { task.cancel(with: .goingAway, reason: nil) }
        }
    }

    func handle(_ frame: TunnelFrame) {
        queue.async { self.dispatch(frame) }
    }

    private func dispatch(_ frame: TunnelFrame) {
        let id = frame.stream
        switch frame.kind {
        case .open:
            guard streams[id] == nil,
                  let open = try? JSONDecoder().decode(TunnelRequest.Open.self, from: frame.payload),
                  let head = TunnelRequest.head(open, connectionID: connectionID, server: server),
                  let nwPort = NWEndpoint.Port(rawValue: port) else {
                send(TunnelFrame(.reset, stream: id, payload: Data("bad request".utf8)))
                return
            }
            let stream = LocalStream(id: id, path: String(open.path.prefix { $0 != "?" }), mux: self)
            streams[id] = stream
            stream.start(head: head, port: nwPort)
        case .data:
            streams[id]?.write(frame.payload)
        case .end:
            break   // the body's length is in the head; the runner reads exactly that
        case .reset:
            streams[id]?.cancel()
        case .window:
            if let credit = frame.windowCredit { streams[id]?.grant(credit) }
        }
    }

    func finished(_ stream: LocalStream) {
        streams[stream.id] = nil
        if stream.path == "/pair" || stream.path == "/rpc" {
            let (status, body) = Self.split(stream.replyCapture)
            observer(stream.path, stream.requestCapture, status, body)
        }
    }

    func closeAll() {
        queue.async {
            for stream in self.streams.values { stream.cancel() }
            self.streams.removeAll()
        }
    }

    /// Status and body of a captured HTTP response.
    private static func split(_ raw: Data) -> (Int, Data) {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw[raw.startIndex..<end.lowerBound], encoding: .utf8) else { return (0, Data()) }
        let status = head.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) } ?? 0
        return (status, raw[end.upperBound...])
    }
}

/// One exchange: a TCP connection to the relay ingress. Response bytes go
/// up only while the relay has granted credit, so a slow browser slows the
/// runner instead of filling memory here.
private final class LocalStream {
    let id: UInt32
    let path: String
    private weak var mux: TunnelMux?
    private var connection: NWConnection?
    private var credit = TunnelFrame.initialWindow
    private var receiving = false
    private var done = false
    /// /pair and /rpc bodies, for operator presence; small by nature.
    private(set) var requestCapture = Data()
    private(set) var replyCapture = Data()
    private static let captureLimit = 64 * 1024
    private var captures: Bool { path == "/pair" || path == "/rpc" }

    init(id: UInt32, path: String, mux: TunnelMux) {
        self.id = id
        self.path = path
        self.mux = mux
    }

    func start(head: Data, port: NWEndpoint.Port) {
        guard let mux else { return }
        let conn = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.fail("runner unreachable") }
        }
        conn.start(queue: mux.queue)
        conn.send(content: head, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.fail("runner unreachable") }
        })
        pump()
    }

    func write(_ data: Data) {
        guard let connection, !done else { return }
        if captures, requestCapture.count < Self.captureLimit { requestCapture.append(data.prefix(Self.captureLimit)) }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.fail("runner write failed") } else { self.mux?.send(.window(self.id, data.count)) }
        })
    }

    func grant(_ bytes: Int) {
        credit += bytes
        pump()
    }

    private func pump() {
        guard let connection, !done, !receiving, credit > 0 else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(credit, TunnelFrame.maxData)) { [weak self] data, _, complete, error in
            guard let self, !self.done else { return }
            self.receiving = false
            if let data, !data.isEmpty {
                self.credit -= data.count
                if self.captures, self.replyCapture.count < Self.captureLimit { self.replyCapture.append(data) }
                self.mux?.send(TunnelFrame(.data, stream: self.id, payload: data))
            }
            if complete {
                self.mux?.send(TunnelFrame(.end, stream: self.id))
                self.finish()
            } else if error != nil {
                self.fail("runner closed")
            } else {
                self.pump()
            }
        }
    }

    private func fail(_ reason: String) {
        guard !done else { return }
        mux?.send(TunnelFrame(.reset, stream: id, payload: Data(reason.utf8)))
        finish()
    }

    /// The relay reset it, or the tunnel went away.
    func cancel() {
        guard !done else { return }
        finish()
    }

    private func finish() {
        done = true
        connection?.cancel()
        connection = nil
        mux?.finished(self)
    }
}
