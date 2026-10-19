import CryptoKit
import Foundation
import UIKit

/// The 远程服务 connections, their live state and the operation log, behind
/// the home card, the add/confirm sheet and Settings › 远程服务.
///
/// The model is multi-connection; v1 keeps one active at a time, so opening
/// one closes the others (their credentials stay).
@MainActor
final class RemoteServiceStore: ObservableObject {
    struct LogEntry: Identifiable, Codable, Equatable {
        enum Kind: String, Codable { case connected, disconnected, operatorStarted, operatorEnded, action, reconnect, error, enrolled, unbound }
        var id = UUID()
        let date: Date
        let connectionID: String
        let kind: Kind
        let text: String
    }

    @Published private(set) var connections: [RemoteConnection] = []
    @Published private(set) var machines: [String: RemoteConnectionMachine] = [:]
    @Published private(set) var log: [LogEntry] = []
    /// An invite opened from a link (or handed over by another screen),
    /// waiting for the add sheet to show its confirmation.
    @Published var incomingInvite: RemoteInvite?
    @Published var incomingInviteError: RemoteInvite.ParseError?

    let client: RemoteServiceClient
    var mock: MockRemoteServiceClient? { client as? MockRemoteServiceClient }

    private var channelTasks: [String: Task<Void, Never>] = [:]
    private static let connectionsKey = "remoteServiceConnections"
    private static let logKey = "remoteServiceLog"
    private static let maxLog = 200

    static var allowInsecureLoopback: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    init(client: RemoteServiceClient? = nil) {
        self.client = client ?? (MockRemoteServiceClient.isEnabled
                                 ? MockRemoteServiceClient() : UnavailableRemoteServiceClient())
        load()
        for c in connections where c.autoConnect { connect(c.id) }
        #if DEBUG
        applyDemoLaunchArgument()
        #endif
    }

    #if DEBUG
    /// `-remoteDemo connected|operated|reconnecting|failed`: put the mock
    /// connection in that state at launch, for screenshots without tapping.
    /// `-remoteInvite <link>` opens that invite's confirmation, as if the
    /// link had been tapped (no "Open in LoopCtrl?" prompt in between).
    private func applyDemoLaunchArgument() {
        if let link = UserDefaults.standard.string(forKey: "remoteInvite"), let url = URL(string: link) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.receive(link: url) }
        }
        guard let state = UserDefaults.standard.string(forKey: "remoteDemo"), let mock else { return }
        let id = connections.first?.id ?? UUID().uuidString
        if connections.isEmpty {
            // Three relays, so the list's swipe and batch actions have something to act on.
            let op = RemoteOperator(name: L10n.rs(.mockOperatorA), keyID: MockRemoteServiceClient.demoOperator.keyID)
            let hosts = ["relay.example.com", "ops.example.net", "relay.self-hosted.dev"]
            connections = hosts.enumerated().map { i, host in
                RemoteConnection(
                    id: i == 0 ? id : UUID().uuidString, serverURL: URL(string: "https://\(host)")!,
                    organization: L10n.rs(.mockOrganization), deviceID: "dev_8f3a1c22e\(i)", operators: [op],
                    preApprovedKeyIDs: [op.keyID], preApprovalSynced: true,
                    spkiPin: MockRemoteServiceClient.demoSPKI, enrolledAt: Date(), autoConnect: false)
            }
            for c in connections where RemoteDeviceKeyStore.load(connectionID: c.id) == nil {
                _ = RemoteDeviceKeyStore.create(connectionID: c.id)
            }
        }
        connect(id)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            switch state {
            case "operated": mock.simulateOperatorStarted(connectionID: id, name: L10n.rs(.mockOperatorA))
            case "reconnecting": mock.simulateDrop(connectionID: id)
            case "failed": mock.simulateServerClosed(connectionID: id)
            default: break
            }
        }
    }
    #endif

    // MARK: - Reading

    /// The connection the home card shows: an active one, else the newest.
    var primary: RemoteConnection? {
        connections.first { machine($0.id).isActive } ?? connections.last
    }

    func machine(_ id: String) -> RemoteConnectionMachine { machines[id] ?? RemoteConnectionMachine() }

    func entries(for id: String) -> [LogEntry] { log.filter { $0.connectionID == id } }

    // MARK: - Invites

    func parse(_ text: String) -> Result<RemoteInvite, RemoteInvite.ParseError> {
        do {
            return .success(try RemoteInvite.parse(text, allowInsecureLoopback: Self.allowInsecureLoopback))
        } catch let error as RemoteInvite.ParseError {
            return .failure(error)
        } catch {
            return .failure(.notAnInvite)
        }
    }

    /// A `loopctrl://connect?…` link opened from outside the app.
    func receive(link url: URL) {
        switch parse(url.absoluteString) {
        case .success(let invite): incomingInvite = invite; incomingInviteError = nil
        case .failure(let error): incomingInviteError = error
        }
    }

    /// Look at the invite on the server, and compare the operators it names.
    /// A pinned invite whose certificate doesn't match is refused here too,
    /// whatever the transport already checked.
    func preview(_ invite: RemoteInvite) async throws -> (RemoteServerInfo, OperatorCheck) {
        let info: RemoteServerInfo
        do {
            info = try await client.preview(invite)
        } catch let error as RemoteServiceError {
            throw error
        } catch {
            throw RemoteServiceError.serverUnreachable
        }
        if let pin = invite.spkiPin, info.spkiSHA256 != pin { throw RemoteServiceError.pinMismatch }
        if let expires = info.codeExpiresAt, expires <= Date() { throw RemoteServiceError.expiredCode }
        return (info, OperatorCheck.verify(inviteKeyIDs: invite.operatorKeyIDs, serverOperators: info.operators))
    }

    // MARK: - Enrolment

    /// 连接 on the confirmation screen: make the device key, redeem the code,
    /// open the relay, pre-approve exactly the invite's operators. Progress
    /// shows through the new connection's machine; returns its id.
    @discardableResult
    func enroll(_ invite: RemoteInvite, check: OperatorCheck, admin: RunnerAdmin) async throws -> String {
        if case .mismatch = check { throw RemoteServiceError.fingerprintMismatch }
        let id = UUID().uuidString
        var m = RemoteConnectionMachine()
        m.handle(.enroll, now: Date())
        machines[id] = m

        func fail(_ error: RemoteServiceError) -> RemoteServiceError {
            RemoteDeviceKeyStore.delete(connectionID: id)
            update(id, .fail(error))
            return error
        }

        // 1. The long-lived credential, made here and kept in the Keychain.
        let key = RemoteDeviceKeyStore.create(connectionID: id)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 2. Spend the one-time code.
        update(id, .advance(.redeemCode))
        let enrollment: RemoteEnrollment
        do {
            enrollment = try await client.redeem(invite, devicePublicKey: key.publicKey.rawRepresentation,
                                                 deviceName: UIDevice.current.name)
        } catch {
            throw fail(error as? RemoteServiceError ?? .serverUnreachable)
        }
        // The operators again, now from the redemption itself: a server that
        // shows one set on preview and enrols another is refused.
        if !invite.operatorKeyIDs.isEmpty,
           case .mismatch = OperatorCheck.verify(inviteKeyIDs: invite.operatorKeyIDs, serverOperators: enrollment.operators) {
            throw fail(.fingerprintMismatch)
        }
        if let pin = invite.spkiPin, let seen = enrollment.spkiSHA256, seen != pin {
            throw fail(.pinMismatch)
        }

        // v1: one active connection.
        for other in connections where machine(other.id).isActive { disconnect(other.id) }

        let connection = RemoteConnection(
            id: id, serverURL: invite.serverURL, organization: enrollment.organization,
            deviceID: enrollment.deviceID, operators: enrollment.operators,
            preApprovedKeyIDs: check.preApproved.map(\.keyID), preApprovalSynced: check.preApproved.isEmpty,
            spkiPin: invite.spkiPin ?? enrollment.spkiSHA256, enrolledAt: Date(), autoConnect: true)
        connections.append(connection)
        save()
        append(id, .enrolled, String(format: L10n.rs(.logEnrolled), connection.serverDisplay))

        // 3. The relay channel.
        update(id, .advance(.openRelay))
        startChannel(connection, key: key)
        try? await Task.sleep(nanoseconds: 250_000_000)

        // 4. Only the operators the invite named; everyone else still asks.
        // Recorded on the connection now; handed to the runner in the
        // background, so a stopped service doesn't hold up 连接 (it gets
        // them when it starts, and the detail page shows them pending).
        update(id, .advance(.preApprove))
        Task { await self.syncPreApprovals(id, admin: admin) }
        try? await Task.sleep(nanoseconds: 250_000_000)
        return id
    }

    /// Push a connection's pre-approvals to the runner if it doesn't have
    /// them yet. Called after enrolment and whenever the service comes up.
    func syncPreApprovals(_ id: String, admin: RunnerAdmin) async {
        guard let index = connections.firstIndex(where: { $0.id == id }),
              !connections[index].preApprovalSynced else { return }
        let c = connections[index]
        let ops = c.operators.filter { c.preApprovedKeyIDs.contains($0.keyID) }
        if await admin.setRelayPreApprovals(connectionID: id, operators: ops) {
            connections[index].preApprovalSynced = true
            save()
        }
    }

    func syncAllPreApprovals(admin: RunnerAdmin) async {
        for c in connections where !c.preApprovalSynced { await syncPreApprovals(c.id, admin: admin) }
    }

    // MARK: - Connect / disconnect

    func connect(_ id: String) {
        guard let c = connections.first(where: { $0.id == id }) else { return }
        guard let key = RemoteDeviceKeyStore.load(connectionID: id) else {
            update(id, .open)
            update(id, .fail(.credentialMissing))
            return
        }
        for other in connections where other.id != id && machine(other.id).isActive { disconnect(other.id) }
        update(id, .open)
        setAutoConnect(id, true)
        startChannel(c, key: key)
    }

    /// 断开: close the channel, keep the credential.
    func disconnect(_ id: String) {
        channelTasks.removeValue(forKey: id)?.cancel()
        client.close(connectionID: id)
        if machine(id).isActive { append(id, .disconnected, L10n.rs(.logDisconnected)) }
        update(id, .disconnect)
        setAutoConnect(id, false)
    }

    /// 解除绑定: close, delete the credential, revoke the pre-approvals (and the
    /// sessions they let in) on the runner, and tell the server. Only the local
    /// part has to succeed.
    /// 解除绑定 for one or many. The local part is immediate: channels close,
    /// keys leave the Keychain, rows leave the list. The rest goes on in the
    /// background — every server is told at once, and the runner gets one
    /// call for all of them. If the runner can't be reached its revocations
    /// stay pending (`pendingRevocations`) and are sent when it comes up, so
    /// nothing waits on a stopped service.
    func unbind(_ ids: [String], admin: RunnerAdmin) {
        let gone = connections.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        // Keys read before they are deleted, for the servers' unbind calls.
        let notices = gone.compactMap { c in RemoteDeviceKeyStore.load(connectionID: c.id).map { (c, $0) } }
        for c in gone {
            channelTasks.removeValue(forKey: c.id)?.cancel()
            client.close(connectionID: c.id)
            RemoteDeviceKeyStore.delete(connectionID: c.id)
            machines[c.id] = nil
        }
        let goneIDs = Set(gone.map(\.id))
        connections.removeAll { goneIDs.contains($0.id) }
        log.removeAll { goneIDs.contains($0.connectionID) }
        pendingRevocations.formUnion(goneIDs)
        save()

        let client = self.client
        Task {
            await withTaskGroup(of: Void.self) { group in
                for (c, key) in notices {
                    group.addTask { try? await client.unbind(c, deviceKey: key) }
                }
                group.addTask { @MainActor in await self.flushPendingRevocations(admin: admin) }
            }
        }
    }

    /// Unbound while the runner was down; revoked on the runner once it's up.
    private var pendingRevocations: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "remoteServicePendingRevocations") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "remoteServicePendingRevocations") }
    }

    func flushPendingRevocations(admin: RunnerAdmin) async {
        let ids = Array(pendingRevocations)
        if await admin.revokeRelay(connectionIDs: ids) {
            pendingRevocations.subtract(ids)
        }
    }

    func currentSPKI(_ id: String) async -> Data? {
        guard let c = connections.first(where: { $0.id == id }) else { return nil }
        return try? await client.currentSPKI(c)
    }

    // MARK: - Channel

    private func startChannel(_ connection: RemoteConnection, key: Curve25519.Signing.PrivateKey) {
        let id = connection.id
        channelTasks.removeValue(forKey: id)?.cancel()
        let stream = client.open(connection, deviceKey: key)
        channelTasks[id] = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.apply(event, to: id)
            }
        }
    }

    private func apply(_ event: RemoteChannelEvent, to id: String) {
        let before = machine(id).phase
        switch event {
        case .established(let latency):
            update(id, .established)
            if let latency { update(id, .latency(latency)) }
            if case .reconnecting = before {
                append(id, .reconnect, L10n.rs(.logReconnected))
            } else {
                append(id, .connected, L10n.rs(.logConnected))
            }
        case .latency(let ms):
            update(id, .latency(ms))
        case .operatorStarted(let name):
            update(id, .operatorStarted(name))
            append(id, .operatorStarted, String(format: L10n.rs(.logOperatorStarted), name))
        case .operatorEnded:
            if case .operated(let name, _, _) = before {
                append(id, .operatorEnded, String(format: L10n.rs(.logOperatorEnded), name))
            }
            update(id, .operatorEnded)
        case .action(let text):
            append(id, .action, text)
        case .lost:
            update(id, .lost)
            if case .failed(let error) = machine(id).phase {
                append(id, .error, RemoteServiceText.error(error))
            }
        case .failed(let error):
            update(id, .fail(error))
            append(id, .error, RemoteServiceText.error(error))
            setAutoConnect(id, false)
        }
    }

    // MARK: - Helpers

    private func update(_ id: String, _ event: RemoteConnectionMachine.Event) {
        var m = machine(id)
        m.handle(event, now: Date())
        machines[id] = m
    }

    private func setAutoConnect(_ id: String, _ on: Bool) {
        guard let i = connections.firstIndex(where: { $0.id == id }), connections[i].autoConnect != on else { return }
        connections[i].autoConnect = on
        save()
    }

    private func append(_ id: String, _ kind: LogEntry.Kind, _ text: String) {
        log.insert(LogEntry(date: Date(), connectionID: id, kind: kind, text: text), at: 0)
        if log.count > Self.maxLog { log.removeLast(log.count - Self.maxLog) }
        saveLog()
    }

    private func load() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.connectionsKey),
           let list = try? JSONDecoder().decode([RemoteConnection].self, from: data) {
            connections = list
        }
        if let data = d.data(forKey: Self.logKey),
           let list = try? JSONDecoder().decode([LogEntry].self, from: data) {
            log = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: Self.connectionsKey)
        }
        saveLog()
    }

    private func saveLog() {
        if let data = try? JSONEncoder().encode(log) {
            UserDefaults.standard.set(data, forKey: Self.logKey)
        }
    }
}
