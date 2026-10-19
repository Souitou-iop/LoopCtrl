import CryptoKit
import Foundation

/// A pretend relay, so every 远程服务 screen and failure can be clicked
/// through without a server. Off by default: the hidden switch (long-press
/// the footer of Settings › 远程服务) turns it on, or in DEBUG the demo
/// launch arguments.
///
/// `scenario` picks what the next preview/enrolment does; the `simulate…`
/// calls inject what an operator or the server would do on an open channel.
final class MockRemoteServiceClient: RemoteServiceClient {
    enum Scenario: String, CaseIterable, Identifiable {
        case success
        case invalidCode
        case expiredCode
        case fingerprintMismatch
        case tlsFailure
        case pinMismatch
        case serverUnreachable
        /// Connects, then the server hangs up a few seconds later.
        case disconnectedByServer

        var id: String { rawValue }
    }

    static let scenarioKey = "remoteServiceMockScenario"
    /// Release builds: the hidden switch that turns the mock on.
    static let enabledKey = "remoteServiceMockEnabled"

    /// Off unless the hidden switch is on; in DEBUG also for the screenshot
    /// launch arguments (`-remoteDemo`, `-remoteServiceMockScenario`).
    static var isEnabled: Bool {
        let d = UserDefaults.standard
        #if DEBUG
        if d.string(forKey: "remoteDemo") != nil || d.string(forKey: scenarioKey) != nil { return true }
        #endif
        return d.bool(forKey: enabledKey)
    }

    var scenario: Scenario {
        get { UserDefaults.standard.string(forKey: Self.scenarioKey).flatMap(Scenario.init(rawValue:)) ?? .success }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.scenarioKey) }
    }

    /// A demo operator for invites that name none (the text form, manual entry).
    static let demoOperator = RemoteOperator(
        name: "Operator",
        keyID: "3f9a6c0d5be2417e8a90c4d1f7b3a25e6d8c1f0a9b7e4d2c5a3f1e0d9c8b7a65")
    /// The certificate digest the mock relay presents.
    static let demoSPKI = Data(SHA256.hash(data: Data("loopctrl-mock-relay".utf8)))

    private var channels: [String: AsyncStream<RemoteChannelEvent>.Continuation] = [:]
    private var tickers: [String: Task<Void, Never>] = [:]
    private let lock = NSLock()

    // MARK: - RemoteServiceClient

    func preview(_ invite: RemoteInvite) async throws -> RemoteServerInfo {
        try await pause(0.6)
        return try serverInfo(invite)
    }

    /// What the pretend server answers, without the network delay.
    private func serverInfo(_ invite: RemoteInvite) throws -> RemoteServerInfo {
        switch scenario {
        case .invalidCode: throw RemoteServiceError.invalidCode
        case .expiredCode: throw RemoteServiceError.expiredCode
        case .tlsFailure: throw RemoteServiceError.tlsFailure
        case .serverUnreachable: throw RemoteServiceError.serverUnreachable
        default: break
        }
        var operators = invite.operatorKeyIDs.enumerated().map { i, keyID in
            RemoteOperator(name: Self.operatorNames[i % Self.operatorNames.count], keyID: keyID)
        }
        if operators.isEmpty {
            operators = [RemoteOperator(name: Self.operatorNames[0], keyID: Self.demoOperator.keyID)]
        }
        if scenario == .fingerprintMismatch {
            // Same name, the server's own key: what a malicious relay would do.
            let forged = Data(SHA256.hash(data: Data((operators[0].keyID + "forged").utf8)))
                .map { String(format: "%02x", $0) }.joined()
            operators[0] = RemoteOperator(name: operators[0].name, keyID: forged)
        }
        let spki = scenario == .pinMismatch
            ? Data(SHA256.hash(data: Data("someone-elses-certificate".utf8)))
            : (invite.spkiPin ?? Self.demoSPKI)
        return RemoteServerInfo(organization: Self.organization,
                                operators: operators,
                                capabilities: RemoteCapability.allCases.map(\.rawValue),
                                spkiSHA256: spki,
                                codeExpiresAt: invite.expiresAt ?? Date().addingTimeInterval(10 * 60))
    }

    func redeem(_ invite: RemoteInvite, deviceKey: Curve25519.Signing.PrivateKey, deviceName: String) async throws -> RemoteEnrollment {
        let devicePublicKey = deviceKey.publicKey.rawRepresentation
        try await pause(0.5)
        if scenario == .serverUnreachable { throw RemoteServiceError.serverUnreachable }
        let info = try serverInfo(invite)
        let deviceID = "dev_" + Data(SHA256.hash(data: devicePublicKey)).prefix(5)
            .map { String(format: "%02x", $0) }.joined()
        return RemoteEnrollment(deviceID: deviceID, organization: info.organization,
                                operators: info.operators, spkiSHA256: info.spkiSHA256)
    }

    func open(_ connection: RemoteConnection, deviceKey: Curve25519.Signing.PrivateKey) -> AsyncStream<RemoteChannelEvent> {
        let id = connection.id
        close(connectionID: id)
        let scenario = self.scenario
        return AsyncStream { continuation in
            lock.lock()
            channels[id] = continuation
            lock.unlock()
            let ticker = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                continuation.yield(.established(latencyMS: Int.random(in: 28...46)))
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    tick += 1
                    if scenario == .disconnectedByServer && tick == 2 {
                        continuation.yield(.failed(.disconnectedByServer))
                        self?.close(connectionID: id)
                        return
                    }
                    continuation.yield(.latency(Int.random(in: 24...72)))
                }
            }
            lock.lock()
            tickers[id] = ticker
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.cancelTicker(id) }
        }
    }

    func close(connectionID: String) {
        lock.lock()
        let continuation = channels.removeValue(forKey: connectionID)
        let ticker = tickers.removeValue(forKey: connectionID)
        lock.unlock()
        ticker?.cancel()
        continuation?.finish()
    }

    func unbind(_ connection: RemoteConnection, deviceKey: Curve25519.Signing.PrivateKey) async throws {
        close(connectionID: connection.id)
        try await pause(0.3)
    }

    func currentSPKI(_ connection: RemoteConnection) async throws -> Data {
        try await pause(0.4)
        return connection.spkiPin ?? Self.demoSPKI
    }

    // MARK: - Driving an open channel

    func simulateOperatorStarted(connectionID: String, name: String) {
        send(.operatorStarted(name), to: connectionID)
        for (i, action) in Self.demoActions.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 1.4) { [weak self] in
                self?.send(.action(action), to: connectionID)
            }
        }
    }

    func simulateOperatorEnded(connectionID: String) { send(.operatorEnded, to: connectionID) }

    /// The channel drops and comes back after a couple of tries.
    func simulateDrop(connectionID: String) {
        send(.lost, to: connectionID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.send(.lost, to: connectionID) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.send(.established(latencyMS: Int.random(in: 30...60)), to: connectionID)
        }
    }

    func simulateServerClosed(connectionID: String) {
        send(.failed(.disconnectedByServer), to: connectionID)
        close(connectionID: connectionID)
    }

    // MARK: - Helpers

    private func send(_ event: RemoteChannelEvent, to id: String) {
        lock.lock()
        let continuation = channels[id]
        lock.unlock()
        continuation?.yield(event)
    }

    private func cancelTicker(_ id: String) {
        lock.lock()
        let ticker = tickers.removeValue(forKey: id)
        channels.removeValue(forKey: id)
        lock.unlock()
        ticker?.cancel()
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static var organization: String { L10n.rs(.mockOrganization) }
    private static var operatorNames: [String] { [L10n.rs(.mockOperatorA), L10n.rs(.mockOperatorB)] }
    private static var demoActions: [String] {
        [L10n.rs(.mockActionScreen), L10n.rs(.mockActionLaunch), L10n.rs(.mockActionTap), L10n.rs(.mockActionType)]
    }
}
