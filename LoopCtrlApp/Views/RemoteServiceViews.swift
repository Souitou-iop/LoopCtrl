import PhotosUI
import SwiftUI
import UIKit

// MARK: - Home card

/// 「远程服务」 on the home screen, under the address card: not connected,
/// connecting, connected (server, organisation, latency) or being operated,
/// with 断开 right there while someone is driving the phone.
struct RemoteServiceCard: View {
    @EnvironmentObject var store: RemoteServiceStore
    let onAdd: () -> Void

    var body: some View {
        Group {
            if let connection = store.primary {
                content(connection, store.machine(connection.id))
            } else {
                emptyState
            }
        }
        .card()
        .animation(.default, value: store.primary.map { store.machine($0.id) })
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RemoteBadge(tint: .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.rs(.title)).font(.headline)
                    Text(L10n.rs(.subtitleEmpty))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button(action: onAdd) {
                Label(L10n.rs(.addConnection), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(16)
    }

    @ViewBuilder
    private func content(_ c: RemoteConnection, _ m: RemoteConnectionMachine) -> some View {
        switch m.phase {
        case .operated(let name, let since, _):
            // 断开 sits outside the link, so a tap on it never navigates.
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink { RemoteServiceView() } label: {
                HStack(spacing: 12) {
                    RemoteBadge(tint: .orange, systemImage: "hand.tap.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: L10n.rs(.operating), name))
                            .font(.headline)
                        Text(verbatim: "\(c.serverDisplay) · \(String(format: L10n.rs(.operatingSince), since.formatted(date: .omitted, time: .shortened)))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    store.disconnect(c.id)
                } label: {
                    Label(L10n.rs(.disconnect), systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .primaryAction(.red)
            }
            .padding(16)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.6), lineWidth: 1.5))
        default:
            NavigationLink { RemoteServiceView() } label: { row(c, m) }
                .buttonStyle(.plain)
        }
    }

    private func row(_ c: RemoteConnection, _ m: RemoteConnectionMachine) -> some View {
        HStack(spacing: 12) {
            RemoteBadge(tint: tint(m))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.rs(.title))
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Text(verbatim: c.serverDisplay)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: subtitle(c, m))
                    .font(.subheadline)
                    .foregroundColor(isFailed(m) ? .orange : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            status(m)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func status(_ m: RemoteConnectionMachine) -> some View {
        switch m.phase {
        case .connected:
            Circle().fill(Color.green).frame(width: 10, height: 10)
        case .enrolling, .connecting, .reconnecting:
            ProgressView()
        default:
            EmptyView()
        }
    }

    private func subtitle(_ c: RemoteConnection, _ m: RemoteConnectionMachine) -> String {
        switch m.phase {
        case .connected:
            // Latency here, not beside the domain, so the domain keeps its width.
            return m.latencyMS.map { "\(c.organization) · \(String(format: L10n.rs(.latency), $0))" } ?? c.organization
        case .enrolling, .connecting: return L10n.rs(.connecting)
        case .reconnecting(let attempt, _): return String(format: L10n.rs(.reconnecting), attempt)
        case .failed(let error): return RemoteServiceText.error(error)
        case .idle: return "\(c.organization) · \(L10n.rs(.disconnectedState))"
        case .operated: return c.organization
        }
    }

    private func isFailed(_ m: RemoteConnectionMachine) -> Bool {
        if case .failed = m.phase { return true }
        return false
    }

    private func tint(_ m: RemoteConnectionMachine) -> Color {
        switch m.phase {
        case .connected, .operated: return .green
        case .failed: return .orange
        case .idle: return .secondary
        default: return .accentColor
        }
    }
}

/// The round server badge used by the card and lists.
struct RemoteBadge: View {
    var tint: Color = .accentColor
    var systemImage = "server.rack"
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.medium))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: Circle())
    }
}

// MARK: - Add connection

/// 「添加连接」: paste, scan, pick from Photos or type in; then the
/// confirmation screen.
struct AddConnectionSheet: View {
    @EnvironmentObject var store: RemoteServiceStore
    @Environment(\.dismiss) private var dismiss
    /// An invite that arrived as a link: go straight to its confirmation.
    var initialInvite: RemoteInvite?

    @State private var confirming: RemoteInvite?
    @State private var showConfirm = false
    @State private var error: String?
    @State private var showScanner = false
    @State private var photoItem: PhotosPickerItem?
    @State private var manualOpen = false
    @State private var manualServer = ""
    @State private var manualCode = ""
    @State private var scenario = MockRemoteServiceClient.Scenario.success

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in accept(strings.first ?? "") }
                    }
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text(L10n.rs(.pasteInvite))
                } footer: {
                    Text(L10n.rs(.pasteFooter))
                }

                Section {
                    Button {
                        error = nil
                        showScanner = true
                    } label: {
                        OptionRow(title: L10n.rs(.scanQR), detail: L10n.rs(.scanQRDetail), systemImage: "qrcode.viewfinder")
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        OptionRow(title: L10n.rs(.pickPhoto), detail: L10n.rs(.pickPhotoDetail), systemImage: "photo.on.rectangle")
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $manualOpen) {
                        TextField(L10n.rs(.serverAddress), text: $manualServer, prompt: Text(verbatim: "relay.example.com"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField(L10n.rs(.connectionCode), text: $manualCode, prompt: Text(verbatim: "7K3M-9QX2"))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button(L10n.rs(.continueButton)) { acceptManual() }
                            .disabled(manualServer.isEmpty || manualCode.isEmpty)
                    } label: {
                        OptionRow(title: L10n.rs(.manualEntry), detail: nil, systemImage: "keyboard")
                    }
                } footer: {
                    if manualOpen { Text(L10n.rs(.manualFooter)) }
                }

                if let error {
                    Section { NoticeLabel(text: error) }
                }

                if store.mock != nil {
                    Section {
                        Button(L10n.rs(.demoWithOperators)) { accept(Self.demoLink) }
                        Button(L10n.rs(.demoTextForm)) { accept(Self.demoText) }
                        Picker(L10n.rs(.mockScenario), selection: $scenario) {
                            ForEach(MockRemoteServiceClient.Scenario.allCases) { s in
                                Text(RemoteServiceText.scenario(s)).tag(s)
                            }
                        }
                    } header: {
                        Text(L10n.rs(.demoSection))
                    } footer: {
                        Text(L10n.rs(.mockFooter))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.rs(.addTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.rs(.cancel)) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showConfirm) {
                if let confirming {
                    InviteConfirmView(invite: confirming) { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                ScannerSheet { payload in
                    showScanner = false
                    accept(payload)
                }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task { await decodePhoto(item) }
            }
            .onChange(of: scenario) { store.mock?.scenario = $0 }
            .onAppear {
                if let mock = store.mock { scenario = mock.scenario }
                if let initialInvite, confirming == nil {
                    confirming = initialInvite
                    showConfirm = true
                }
            }
        }
    }

    private func accept(_ text: String) {
        switch store.parse(text) {
        case .success(let invite):
            error = nil
            confirming = invite
            showConfirm = true
        case .failure(let e):
            error = RemoteServiceText.parse(e)
        }
    }

    private func acceptManual() {
        do {
            let invite = try RemoteInvite.manual(server: manualServer, code: manualCode,
                                                 allowInsecureLoopback: RemoteServiceStore.allowInsecureLoopback)
            error = nil
            confirming = invite
            showConfirm = true
        } catch let e as RemoteInvite.ParseError {
            error = RemoteServiceText.parse(e)
        } catch {}
    }

    private func decodePhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let payloads = await QRImageDecoder.payloads(in: data)
        // The first one that is an invite; else say what the first was.
        if let invite = payloads.lazy.compactMap({ try? store.parse($0).get() }).first {
            error = nil
            confirming = invite
            showConfirm = true
        } else if let first = payloads.first {
            accept(first)
        } else {
            error = L10n.rs(.noQRInPhoto)
        }
    }

    /// A pinned, operator-carrying invite for the demo relay (mock only).
    static var demoLink: String {
        let exp = Int(Date().addingTimeInterval(10 * 60).timeIntervalSince1970)
        return "loopctrl://connect?v=1&server=relay.example.com&code=7K3M-9QX2"
            + "&op=\(MockRemoteServiceClient.demoOperator.keyID)"
            + "&pin=\(RemoteInvite.base64url(MockRemoteServiceClient.demoSPKI))&exp=\(exp)"
    }

    static let demoText = "LoopCtrl 连接邀请 · 服务器 relay.example.com · 连接码 7K3M-9QX2 · 10 分钟内有效"
}

private struct OptionRow: View {
    let title: String
    let detail: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(.primary)
                if let detail {
                    Text(detail).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }
}

private struct ScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void
    @State private var delivered = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRCodeScannerView { payload in
                    guard !delivered else { return }
                    delivered = true
                    onScan(payload)
                }
                .ignoresSafeArea()
                if QRCodeScannerView.isAvailable {
                    Text(L10n.rs(.scanHint))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle(L10n.rs(.scanQR))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.rs(.cancel)) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Confirmation

/// The key screen: who this phone is about to trust. The server domain comes
/// from the invite, never from the server; the organisation is the server's
/// word and says so; operators are checked against the invite's fingerprints
/// and a mismatch refuses to connect.
struct InviteConfirmView: View {
    @EnvironmentObject var store: RemoteServiceStore
    @EnvironmentObject var admin: RunnerAdmin
    @Environment(\.dismiss) private var dismiss
    let invite: RemoteInvite
    let onFinished: () -> Void

    private enum Stage: Equatable {
        case loading
        case failed(RemoteServiceError)
        case ready(RemoteServerInfo, OperatorCheck)
        case enrolling(String?, RemoteServerInfo, OperatorCheck)
        case enrollFailed(RemoteServiceError, RemoteServerInfo, OperatorCheck)
        case done(RemoteServerInfo, OperatorCheck)
    }

    @State private var stage = Stage.loading

    var body: some View {
        List {
            serverSection
            switch stage {
            case .loading:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.rs(.checking)).foregroundColor(.secondary)
                    }
                }
            case .failed(let error):
                Section {
                    NoticeLabel(text: RemoteServiceText.error(error))
                    Button(L10n.rs(.retry)) { Task { await load() } }
                }
            case .ready(let info, let check), .enrollFailed(_, let info, let check):
                details(info, check)
                if case .enrollFailed(let error, _, _) = stage {
                    Section { NoticeLabel(text: RemoteServiceText.error(error)) }
                }
            case .enrolling(let id, let info, let check):
                details(info, check)
                progressSection(id)
            case .done(let info, let check):
                details(info, check)
                progressSection(nil)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.rs(.confirmTitle))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { buttons }
        // The enrolment steps advance in the store, outside setStage.
        .animation(Self.stageAnimation, value: store.machines)
        .task { if stage == .loading { await load() } }
    }

    private func load() async {
        setStage(.loading)
        do {
            let (info, check) = try await store.preview(invite)
            setStage(.ready(info, check))
        } catch {
            setStage(.failed(error as? RemoteServiceError ?? .serverUnreachable))
        }
    }

    // MARK: Sections

    private var serverSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: lockSymbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(invite.isHTTPS ? .green : .orange)
                Text(verbatim: invite.serverDisplay)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                Text(lockText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text(verbatim: codeLine)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private var lockSymbol: String {
        if !invite.isHTTPS { return "lock.open.fill" }
        return invite.spkiPin != nil ? "lock.shield.fill" : "lock.fill"
    }

    private var lockText: String {
        if !invite.isHTTPS { return L10n.rs(.insecureDebug) }
        return invite.spkiPin != nil ? L10n.rs(.pinnedLock) : L10n.rs(.httpsLock)
    }

    private var codeLine: String {
        var at = invite.expiresAt
        switch stage {
        case .ready(let info, _), .enrolling(_, let info, _), .enrollFailed(_, let info, _), .done(let info, _):
            at = info.codeExpiresAt ?? at
        case .loading, .failed:
            break
        }
        guard let at else { return invite.displayCode }
        let f = RelativeDateTimeFormatter()
        f.locale = RemoteServiceText.locale
        let expires = f.localizedString(for: at, relativeTo: Date())
        return String(format: L10n.rs(.codeExpires), invite.displayCode, expires)
    }

    @ViewBuilder
    private func details(_ info: RemoteServerInfo, _ check: OperatorCheck) -> some View {
        if case .mismatch = check {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.rs(.mismatchTitle), systemImage: "xmark.octagon.fill")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text(L10n.rs(.mismatchBody))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(info.operators) { op in
                    OperatorRow(op: op, state: invite.operatorKeyIDs.contains(op.keyID) ? .matched : .mismatched)
                }
            } header: {
                Text(L10n.rs(.operatorsSection))
            }
        } else {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: info.organization).font(.headline)
                    Text(L10n.rs(.providedByServer)).font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text(L10n.rs(.organization))
            }

            Section {
                ForEach(check.operators) { op in
                    OperatorRow(op: op, state: check.preApproved.isEmpty ? .unverified : .matched)
                }
            } header: {
                Text(L10n.rs(.operatorsSection))
            } footer: {
                if case .unverified = check {
                    Label(L10n.rs(.checkFingerprintFooter), systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                }
            }

            Section {
                ForEach(info.capabilities, id: \.self) { raw in
                    if let cap = RemoteServiceText.capability(raw) {
                        Label(cap.0, systemImage: cap.1)
                    }
                }
            } header: {
                Text(L10n.rs(.capabilitiesSection))
            } footer: {
                Label(check.preApproved.isEmpty ? L10n.rs(.relayPromiseUnverified) : L10n.rs(.relayPromise),
                      systemImage: "lock.rectangle.stack")
                    .font(.footnote)
                    .padding(.top, 6)
            }
        }
    }

    private func progressSection(_ id: String?) -> some View {
        let phase = id.map { store.machine($0).phase }
        return Section {
            ForEach(EnrollmentStep.allCases, id: \.self) { step in
                StepRow(title: Self.stepTitle(step), state: stepState(step, phase))
            }
        }
    }

    private enum StepState { case waiting, running, done, failed }

    private func stepState(_ step: EnrollmentStep, _ phase: RemoteConnectionMachine.Phase?) -> StepState {
        if case .done = stage { return .done }
        switch phase {
        case .enrolling(let current):
            return step.rawValue < current.rawValue ? .done : step == current ? .running : .waiting
        case .connected, .operated, .connecting:
            return .done
        case .failed:
            return .failed
        default:
            return step == .createKey ? .running : .waiting
        }
    }

    private static func stepTitle(_ step: EnrollmentStep) -> String {
        switch step {
        case .createKey: return L10n.rs(.stepCreateKey)
        case .redeemCode: return L10n.rs(.stepRedeem)
        case .openRelay: return L10n.rs(.stepOpenRelay)
        case .preApprove: return L10n.rs(.stepPreApprove)
        }
    }

    private struct StepRow: View {
        let title: String
        let state: StepState

        var body: some View {
            HStack(spacing: 12) {
                Group {
                    switch state {
                    case .waiting: Image(systemName: "circle").foregroundColor(Color(.tertiaryLabel))
                    case .running: ProgressView()
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    }
                }
                .id(state)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .frame(width: 22)
                Text(title).foregroundColor(state == .waiting ? .secondary : .primary)
            }
        }
    }

    // MARK: Buttons

    static let stageAnimation = Animation.spring(response: 0.42, dampingFraction: 0.82)

    /// Every stage change animates: sections slide in, the buttons morph.
    private func setStage(_ next: Stage) {
        if case .done = next {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if case .enrollFailed = next {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        withAnimation(Self.stageAnimation) { stage = next }
    }

    /// What the one prominent button says now. It stays the same view
    /// through 连接 → 正在连接 → 已连接, so it resizes and recolours smoothly
    /// instead of being swapped for another button.
    private struct Primary: Equatable {
        enum Kind: Equatable { case connect, connecting, done }
        let kind: Kind
        var title: String {
            switch kind {
            case .connect: return L10n.rs(.connect)
            case .connecting: return L10n.rs(.connecting)
            case .done: return L10n.rs(.connectedDone)
            }
        }
        var symbol: String { kind == .done ? "checkmark" : "link" }
        var tint: Color { kind == .done ? .green : .accentColor }
    }

    private var primary: Primary? {
        switch stage {
        case .ready(_, let check), .enrollFailed(_, _, let check):
            if case .mismatch = check { return nil }
            return Primary(kind: .connect)
        case .enrolling: return Primary(kind: .connecting)
        case .done: return Primary(kind: .done)
        case .loading, .failed: return nil
        }
    }

    private var showsCancel: Bool {
        switch stage {
        case .enrolling, .done: return false
        default: return true
        }
    }

    /// Floating, right-aligned capsules over the list (Liquid Glass on iOS 26,
    /// where neighbouring glass shapes also merge and split as they change).
    private var buttons: some View {
        FloatingGlassGroup {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if showsCancel {
                    Button(role: .cancel) { onFinished() } label: {
                        Text(L10n.rs(.cancel))
                    }
                    .floatingAction(prominent: false, tint: .primary)
                    .transition(.scale(scale: 0.5, anchor: .trailing).combined(with: .opacity))
                }
                if let primary {
                    Button { primaryTapped() } label: {
                        HStack(spacing: 8) {
                            if primary.kind == .connecting {
                                ProgressView()
                                    .tint(.white)
                                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                            } else {
                                Image(systemName: primary.symbol)
                                    .id(primary.symbol)
                                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                            }
                            Text(primary.title)
                                .id(primary.title)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                        removal: .move(edge: .top).combined(with: .opacity)))
                        }
                        .fontWeight(.semibold)
                        .clipped()
                    }
                    .floatingAction(prominent: true, tint: primary.tint)
                    // Not .disabled while connecting: that would grey it out.
                    .allowsHitTesting(primary.kind != .connecting)
                    .transition(.scale(scale: 0.5, anchor: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .animation(Self.stageAnimation, value: primary)
        .animation(Self.stageAnimation, value: showsCancel)
    }

    private func primaryTapped() {
        switch stage {
        case .ready(_, let check), .enrollFailed(_, _, let check):
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await enroll(check) }
        case .done:
            onFinished()
        default:
            break
        }
    }

    private func enroll(_ check: OperatorCheck) async {
        switch stage {
        case .ready(let info, _), .enrollFailed(_, let info, _): await run(info, check)
        default: break
        }
    }

    private func run(_ info: RemoteServerInfo, _ check: OperatorCheck) async {
        setStage(.enrolling(nil, info, check))
        // Poll the store for the new connection's id so the steps can follow it.
        let before = Set(store.machines.keys)
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let id = store.machines.keys.first(where: { !before.contains($0) }),
                   case .enrolling(nil, _, _) = stage {
                    setStage(.enrolling(id, info, check))
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { watcher.cancel() }
        do {
            let id = try await store.enroll(invite, check: check, admin: admin)
            setStage(.enrolling(id, info, check))
            try? await Task.sleep(nanoseconds: 300_000_000)
            setStage(.done(info, check))
        } catch {
            setStage(.enrollFailed(error as? RemoteServiceError ?? .serverUnreachable, info, check))
        }
    }
}

/// An operator: name, the full key in groups, and how it compares with the invite.
struct OperatorRow: View {
    enum State { case matched, unverified, mismatched, preApproved, pending, asksFirst }
    let op: RemoteOperator
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.crop.circle")
                    .foregroundColor(.secondary)
                Text(verbatim: op.name).font(.body.weight(.semibold))
                Spacer(minLength: 8)
                badge
            }
            Text(verbatim: PairRequestText.groupedFingerprint(op.fingerprint))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
            Text(verbatim: op.groupedKeyID)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .matched: StateChip(text: "✓ " + L10n.rs(.matchesInvite), tone: .good)
        case .unverified: StateChip(text: L10n.rs(.checkFingerprint), tone: .warning)
        case .mismatched: StateChip(text: L10n.rs(.mismatchTitle), tone: .bad)
        case .preApproved: StateChip(text: L10n.rs(.preApproved), tone: .good)
        case .pending: StateChip(text: L10n.rs(.preApprovalPending), tone: .warning)
        case .asksFirst: StateChip(text: L10n.rs(.notPreApproved), tone: .idle)
        }
    }
}

// MARK: - Settings › 远程服务

/// The connection list (one active in v1), adding one, and — with the mock
/// relay — buttons that drive every state.
struct RemoteServiceView: View {
    @EnvironmentObject var store: RemoteServiceStore
    @State private var showAdd = false
    @State private var mockToast: String?

    var body: some View {
        List {
            Section {
                ForEach(store.connections) { c in
                    NavigationLink {
                        RemoteConnectionDetailView(connectionID: c.id)
                    } label: {
                        ConnectionRow(connection: c, machine: store.machine(c.id))
                    }
                }
                Button {
                    showAdd = true
                } label: {
                    Label(L10n.rs(.addConnection), systemImage: "plus.circle")
                }
            } header: {
                Text(L10n.rs(.connectionsSection))
            } footer: {
                Text(L10n.rs(.subtitleEmpty))
                    .onLongPressGesture(minimumDuration: 2) { toggleHiddenMock() }
            }

            if let mock = store.mock {
                MockControls(mock: mock)
            }

            if let mockToast {
                Section { Text(mockToast).foregroundColor(.secondary) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.rs(.title))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            AddConnectionSheet()
        }
    }

    /// Release builds: the hidden switch for the mock relay. Takes effect on
    /// the next launch (the store picks its client once).
    private func toggleHiddenMock() {
        #if !DEBUG
        let d = UserDefaults.standard
        let on = !d.bool(forKey: MockRemoteServiceClient.enabledKey)
        d.set(on, forKey: MockRemoteServiceClient.enabledKey)
        mockToast = on ? L10n.rs(.mockEnabled) : L10n.rs(.mockDisabled)
        #endif
    }
}

private struct ConnectionRow: View {
    let connection: RemoteConnection
    let machine: RemoteConnectionMachine

    var body: some View {
        HStack(spacing: 12) {
            RemoteBadge(tint: tone == .good ? .green : .secondary, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: connection.serverDisplay)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.middle)
                Text(verbatim: connection.organization).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            StateChip(text: RemoteServiceView.phaseText(machine), tone: tone)
                .layoutPriority(-1)
        }
    }

    private var tone: StateChip.Tone { RemoteServiceView.phaseTone(machine) }
}

extension RemoteServiceView {
    static func phaseText(_ m: RemoteConnectionMachine) -> String {
        switch m.phase {
        case .idle: return L10n.rs(.disconnectedState)
        case .enrolling, .connecting: return L10n.rs(.connecting)
        case .reconnecting(let attempt, _): return String(format: L10n.rs(.reconnecting), attempt)
        case .connected: return m.latencyMS.map { String(format: L10n.rs(.latency), $0) } ?? L10n.rs(.connectedDone)
        case .operated(let name, _, _): return String(format: L10n.rs(.operating), name)
        case .failed: return L10n.rs(.failedState)
        }
    }

    static func phaseTone(_ m: RemoteConnectionMachine) -> StateChip.Tone {
        switch m.phase {
        case .idle: return .idle
        case .enrolling, .connecting, .reconnecting: return .busy
        case .connected: return .good
        case .operated: return .warning
        case .failed: return .bad
        }
    }
}

private struct MockControls: View {
    @EnvironmentObject var store: RemoteServiceStore
    let mock: MockRemoteServiceClient
    @State private var scenario = MockRemoteServiceClient.Scenario.success

    private var active: RemoteConnection? { store.connections.first { store.machine($0.id).isActive } }

    var body: some View {
        Section {
            Picker(L10n.rs(.mockScenario), selection: $scenario) {
                ForEach(MockRemoteServiceClient.Scenario.allCases) { s in
                    Text(RemoteServiceText.scenario(s)).tag(s)
                }
            }
            if let active {
                let operatorName = active.operators.first?.name ?? MockRemoteServiceClient.demoOperator.name
                Button(L10n.rs(.simulateOperator)) {
                    mock.simulateOperatorStarted(connectionID: active.id, name: operatorName)
                }
                Button(L10n.rs(.simulateOperatorEnd)) { mock.simulateOperatorEnded(connectionID: active.id) }
                Button(L10n.rs(.simulateDrop)) { mock.simulateDrop(connectionID: active.id) }
                Button(L10n.rs(.simulateServerClose), role: .destructive) {
                    mock.simulateServerClosed(connectionID: active.id)
                }
            }
        } header: {
            Text(L10n.rs(.mockSection))
        } footer: {
            Text(L10n.rs(.mockFooter))
        }
        .onAppear { scenario = mock.scenario }
        .onChange(of: scenario) { mock.scenario = $0 }
    }
}

/// One connection: who, since when, which operators, the log, and the two
/// ways out (断开 keeps the key, 解除绑定 deletes it).
struct RemoteConnectionDetailView: View {
    @EnvironmentObject var store: RemoteServiceStore
    @EnvironmentObject var admin: RunnerAdmin
    @Environment(\.dismiss) private var dismiss
    let connectionID: String
    @State private var confirmUnbind = false
    @State private var currentSPKI: Data?
    @State private var loadingSPKI = false
    @State private var syncing = false

    var body: some View {
        if let c = store.connections.first(where: { $0.id == connectionID }) {
            list(c, store.machine(c.id))
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private func list(_ c: RemoteConnection, _ m: RemoteConnectionMachine) -> some View {
        List {
            Section {
                HStack {
                    Text(L10n.rs(.title))
                    Spacer()
                    StateChip(text: RemoteServiceView.phaseText(m), tone: RemoteServiceView.phaseTone(m))
                }
                if case .failed(let error) = m.phase {
                    NoticeLabel(text: RemoteServiceText.error(error))
                }
                HStack(spacing: 12) {
                    Label(L10n.rs(.server), systemImage: c.serverURL.scheme == "https" ? "lock.fill" : "lock.open")
                    Spacer(minLength: 8)
                    Text(verbatim: c.serverDisplay).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ValueRow(title: L10n.rs(.organization), systemImage: "building.2", value: c.organization)
                    Text(L10n.rs(.providedByServer)).font(.caption2).foregroundColor(.secondary).padding(.leading, 36)
                }
                CopyRow(title: L10n.rs(.deviceID), systemImage: "iphone", value: c.deviceID)
                if let since = m.connectedSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ValueRow(title: L10n.rs(.connectedFor), systemImage: "clock",
                                 value: Self.duration(context.date.timeIntervalSince(since)))
                    }
                }
                ValueRow(title: L10n.rs(.reconnects24h), systemImage: "arrow.triangle.2.circlepath",
                         value: "\(m.reconnectCount(now: Date()))")
            }

            Section {
                ForEach(c.operators) { op in
                    OperatorRow(op: op, state: operatorState(op, c))
                }
                if !c.preApprovalSynced {
                    Button {
                        Task {
                            syncing = true
                            #if !LOOPCTRL_ALL_IN_ONE
                            if !admin.isPaired { await admin.connect() }
                            #endif
                            await store.syncPreApprovals(c.id, admin: admin)
                            syncing = false
                        }
                    } label: {
                        HStack { Text(L10n.rs(.syncNow)); if syncing { Spacer(); ProgressView() } }
                    }
                    .disabled(syncing)
                }
            } header: {
                Text(L10n.rs(.operators))
            } footer: {
                if !c.preApprovalSynced { Text(L10n.rs(.preApprovalPendingFooter)) }
            }

            Section {
                if m.isActive {
                    Button(role: .destructive) { store.disconnect(c.id) } label: {
                        Label(L10n.rs(.disconnect), systemImage: "pause.circle")
                    }
                } else {
                    Button { store.connect(c.id) } label: {
                        Label(L10n.rs(.connect), systemImage: "play.circle")
                    }
                }
                Button(role: .destructive) { confirmUnbind = true } label: {
                    Label(L10n.rs(.unbind), systemImage: "trash")
                }
            } footer: {
                Text(L10n.rs(.disconnectFooter))
            }

            Section {
                let entries = store.entries(for: c.id).prefix(30)
                if entries.isEmpty {
                    Text(L10n.rs(.noLog)).foregroundColor(.secondary)
                }
                ForEach(Array(entries)) { entry in
                    LogEntryRow(entry: entry)
                }
            } header: {
                Text(L10n.rs(.recentLog))
            }

            Section {
                if let pin = c.spkiPin {
                    SPKIRow(title: L10n.rs(.pinnedSPKI), digest: pin)
                }
                if let currentSPKI {
                    SPKIRow(title: L10n.rs(.certificateSPKI), digest: currentSPKI)
                    if let pin = c.spkiPin {
                        Label(pin == currentSPKI ? L10n.rs(.spkiMatches) : L10n.rs(.spkiDiffers),
                              systemImage: pin == currentSPKI ? "checkmark.seal" : "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(pin == currentSPKI ? .green : .orange)
                    }
                } else {
                    Button {
                        Task {
                            loadingSPKI = true
                            currentSPKI = await store.currentSPKI(c.id)
                            loadingSPKI = false
                        }
                    } label: {
                        HStack { Text(L10n.rs(.loadSPKI)); if loadingSPKI { Spacer(); ProgressView() } }
                    }
                }
            } header: {
                Text(L10n.rs(.advanced))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(c.serverDisplay)
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: m)
        .confirmationDialog(L10n.rs(.unbindConfirm), isPresented: $confirmUnbind, titleVisibility: .visible) {
            Button(L10n.rs(.unbind), role: .destructive) {
                Task { await store.unbind(c.id, admin: admin) }
            }
            Button(L10n.rs(.cancel), role: .cancel) {}
        } message: {
            Text(String(format: L10n.rs(.unbindBody), c.serverDisplay))
        }
    }

    private func operatorState(_ op: RemoteOperator, _ c: RemoteConnection) -> OperatorRow.State {
        guard c.preApprovedKeyIDs.contains(op.keyID) else { return .asksFirst }
        return c.preApprovalSynced ? .preApproved : .pending
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        var calendar = Calendar.current
        calendar.locale = RemoteServiceText.locale
        f.calendar = calendar
        return f.string(from: max(0, seconds)) ?? "—"
    }
}

private struct SPKIRow: View {
    let title: String
    let digest: Data

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            Text(verbatim: "sha256/" + digest.base64EncodedString())
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            Text(verbatim: digest.map { String(format: "%02x", $0) }.joined())
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

private struct LogEntryRow: View {
    let entry: RemoteServiceStore.LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .frame(width: 20)
            Text(entry.text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .connected, .enrolled: return "link"
        case .disconnected, .unbound: return "link.badge.plus"
        case .operatorStarted: return "hand.tap.fill"
        case .operatorEnded: return "hand.raised"
        case .action: return "cursorarrow.click"
        case .reconnect: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .error: return .orange
        case .operatorStarted: return .orange
        case .connected, .enrolled, .reconnect: return .green
        default: return .secondary
        }
    }
}

// MARK: - Authorization page

/// Operators pre-approved through the remote service, in the Authorization
/// page next to the clients holding a key.
struct RelayPreApprovalSection: View {
    @EnvironmentObject var admin: RunnerAdmin
    @EnvironmentObject var store: RemoteServiceStore

    /// The runner's list when it reports one; otherwise what this app sent.
    private var rows: [(id: String, name: String, keyID: String, server: String, synced: Bool)] {
        let servers = Dictionary(store.connections.map { ($0.id, $0.serverDisplay) }, uniquingKeysWith: { a, _ in a })
        if !admin.relayPreApprovals.isEmpty {
            return admin.relayPreApprovals.map {
                ($0.id, $0.name, $0.keyID, servers[$0.connectionID] ?? $0.connectionID, true)
            }
        }
        return store.connections.flatMap { c in
            c.operators.filter { c.preApprovedKeyIDs.contains($0.keyID) }
                .map { (c.id + $0.keyID, $0.name, $0.keyID, c.serverDisplay, c.preApprovalSynced) }
        }
    }

    var body: some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: 12) {
                        SourceStyle.badge(PeerSource.relay.rawValue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.name).lineLimit(1)
                            Text(verbatim: "\(SourceStyle.name(PeerSource.relay.rawValue)) · \(row.server) · \(PairRequestText.groupedFingerprint(String(row.keyID.prefix(8))))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        StateChip(text: row.synced ? L10n.rs(.preApproved) : L10n.rs(.preApprovalPending),
                                  tone: row.synced ? .good : .warning)
                    }
                }
            } header: {
                Text(L10n.rs(.relayOperatorsSection))
            } footer: {
                Text(L10n.rs(.relayOperatorsFooter))
            }
        }
    }
}
