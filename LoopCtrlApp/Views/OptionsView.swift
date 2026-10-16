import SwiftUI
import UIKit

/// Everything that isn't the one thing the home screen does, by task: a summary
/// of this device and the service, how clients connect, setting up the disk
/// image, who holds a key, diagnostics, and about.
struct OptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runnerAdmin: RunnerAdmin
    @ObservedObject var runner: RunnerStatus

    @State private var ddi = DeveloperDiskImage.status()
    @State private var setupDone = 0
    @State private var tunnelUp = false
    @State private var showMountSheet = false
    @State private var logCount = AppLog.allFiles().count
    @State private var portText = String(ServerPort.stored)
    @State private var movingPort = false

    @State private var pendingRevoke: RunnerAdmin.Client?
    @State private var confirmRevokeOthers = false
    @State private var confirmDisconnect = false

    /// Clients listed inline before the rest move behind "Show All".
    private static let inlineClientLimit = 4
    static let repositoryURL = URL(string: "https://github.com/Souitou-iop/LoopCtrl")!

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summaryCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                connectionSection
                setupSection
                clientsSection
                diagnosticsSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.ui(.settingsTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t(.doneButton)) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .animation(.default, value: runner.state)
            .animation(.default, value: runnerAdmin.visibility)
            .animation(.default, value: runnerAdmin.clients)
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: PairingFileStore.didImport)) { _ in refresh() }
            .sheet(isPresented: $showMountSheet, onDismiss: refresh) {
                DDIMountView()
            }
            .clientConfirmations(admin: runnerAdmin,
                                 pendingRevoke: $pendingRevoke,
                                 confirmRevokeOthers: $confirmRevokeOthers,
                                 confirmDisconnect: $confirmDisconnect)
            // Visibility and clients kept current while shown: remote access
            // and nearby can be switched from the runner's notification at any
            // time, and a new client can pair. Pairing is never started here.
            .task(id: runnerAdmin.isPaired) {
                while !Task.isCancelled {
                    #if LOOPCTRL_ALL_IN_ONE
                    runnerAdmin.refreshInProcessVisibility()
                    #endif
                    if runner.isRunning && runnerAdmin.isPaired {
                        await runnerAdmin.loadClients()
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    private func refresh() {
        ddi = DeveloperDiskImage.status()
        logCount = AppLog.allFiles().count
        let hasPairing = PairingFileStore.exists
        let images = DeveloperDiskImageStore.isComplete
        let wifi = NetworkTypeMonitor.shared.current == .wifi
        setupDone = [hasPairing, images, wifi, tunnelUp].filter { $0 }.count
        // The tunnel is only worth probing once the user is into the flow:
        // a probe of a private address is what can raise the Local Network
        // prompt, which shouldn't come from just opening Settings.
        if !ddi.isMounted, hasPairing, images {
            Task { @MainActor in
                tunnelUp = await LocalDevVPN.probeTunnel() == .reachable
                setupDone = [hasPairing, images, wifi, tunnelUp].filter { $0 }.count
            }
        }
    }

    // MARK: - Summary

    /// This device and the service at a glance. Read locally, not from the
    /// server: most useful precisely when the runner won't start.
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "iphone")
                    .font(.title2.weight(.medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 50, height: 50)
                    .background(Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: UIDevice.current.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(verbatim: "\(DeviceInfo.modelIdentifier) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            serviceChip
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var serviceChip: some View {
        switch runner.state {
        case .unknown, .checking:
            StateChip(text: L10n.t(.checking), tone: .busy)
        case .running:
            StateChip(text: "\(L10n.t(.running)) · 127.0.0.1:\(appState.serverPort)", tone: .good)
        case .stopped:
            StateChip(text: L10n.t(.stopped), tone: .idle)
        }
    }

    // MARK: - Connection

    private var portIsValid: Bool {
        Int(portText).map(ServerPort.allowed.contains) ?? false
    }

    private var remoteOn: Bool {
        runnerAdmin.visibility.map { $0 != .local } ?? false
    }

    private var busy: Bool { runnerAdmin.pairing || runnerAdmin.changingVisibility }

    private var connectionSection: some View {
        Section {
            portRow
            if runner.isRunning && portIsValid && Int(portText) != appState.serverPort {
                Button {
                    Task { await movePort() }
                } label: {
                    HStack {
                        Label(String(format: L10n.ui(.portApply), portText), systemImage: "arrow.triangle.2.circlepath")
                        if movingPort { Spacer(); ProgressView() }
                    }
                }
                .disabled(movingPort)
            }
            if portText != String(ServerPort.defaultPort) && !runner.isRunning {
                Button {
                    portText = String(ServerPort.defaultPort)
                } label: {
                    Label(L10n.ui(.portReset), systemImage: "arrow.uturn.backward")
                }
            }

            visibilityRow

            if runner.isRunning {
                CopyRow(title: L10n.ui(.localAddress), systemImage: "iphone",
                        value: "127.0.0.1:\(appState.serverPort)")
                if remoteOn {
                    CopyRow(title: L10n.ui(.lanAddress), systemImage: "wifi",
                            value: AppState.wifiAddress().map { "\($0):\(appState.serverPort)" },
                            placeholder: L10n.ui(.noWiFi))
                }
            }
        } header: {
            Text(L10n.ui(.connectionSection))
        } footer: {
            connectionFooter
        }
    }

    /// The server's port. While stopped it is saved as soon as it is valid and
    /// used on the next start. While running it is only saved once the runner
    /// has moved to it (`movePort`): saved early, the status probe would look
    /// at a port nothing listens on yet and report the service stopped.
    private var portRow: some View {
        HStack(spacing: 12) {
            Label(L10n.ui(.portLabel), systemImage: "number")
            Spacer(minLength: 8)
            TextField(String(ServerPort.defaultPort), text: $portText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(portIsValid ? .primary : .orange)
                .frame(maxWidth: 110)
                .disabled(movingPort)
                .onChange(of: portText) { text in
                    let digits = String(text.filter(\.isNumber).prefix(5))
                    if digits != text { portText = digits; return }
                    if !runner.isRunning, let value = Int(digits), ServerPort.allowed.contains(value) {
                        appState.serverPort = value
                    }
                }
        }
    }

    /// Move the running service to the typed port (`config{listen_port}`),
    /// then save it here and re-probe there.
    private func movePort() async {
        guard let value = Int(portText), ServerPort.allowed.contains(value) else { return }
        movingPort = true
        defer { movingPort = false }
        #if !LOOPCTRL_ALL_IN_ONE
        if !runnerAdmin.isPaired {
            await runnerAdmin.connect()
            guard runnerAdmin.isPaired else { return }
        }
        #endif
        guard await runnerAdmin.setListenPort(value) else { return }
        appState.serverPort = value
        // The runner restarts its listener just after replying.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await runner.check()
    }

    private static let visibilityChoices: [RunnerAdmin.Visibility] = [.local, .lan, .lanAndNearby]

    private static func shortName(_ visibility: RunnerAdmin.Visibility) -> String {
        switch visibility {
        case .local: return L10n.ui(.visibilityThisDevice)
        case .lan: return L10n.ui(.visibilityLAN)
        case .lanAndNearby: return L10n.ui(.visibilityNearby)
        }
    }

    /// Who can reach the server. Changing it needs the service running: the
    /// runner applies it to its live listener.
    private var visibilityRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.t(.visibilityLabel), systemImage: "eye")
                Spacer()
                if busy { ProgressView() }
            }
            Picker(L10n.t(.visibilityLabel), selection: Binding(
                get: { runnerAdmin.visibility ?? .local },
                set: { target in Task { await setVisibility(target) } })) {
                ForEach(Self.visibilityChoices, id: \.self) { choice in
                    Text(Self.shortName(choice)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!runner.isRunning || busy)
        }
        .padding(.vertical, 4)
    }

    /// Changing who can reach the runner is a `config` call, which needs this
    /// app paired with it: the first time, that asks for the user's approval.
    /// The all-in-one runner shares this process and is told directly.
    private func setVisibility(_ target: RunnerAdmin.Visibility) async {
        #if LOOPCTRL_ALL_IN_ONE
        await runnerAdmin.setVisibilityInProcess(target)
        #else
        if !runnerAdmin.isPaired {
            await runnerAdmin.connect()
            guard runnerAdmin.isPaired else { return }
        }
        await runnerAdmin.setVisibility(target)
        #endif
    }

    @ViewBuilder private var connectionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !portIsValid {
                Text(String(format: L10n.ui(.portInvalid),
                            ServerPort.allowed.lowerBound, ServerPort.allowed.upperBound))
                    .foregroundColor(.orange)
            } else if runner.isRunning && Int(portText) != appState.serverPort {
                Text(L10n.ui(.portRunningFooter))
            } else {
                Text(String(format: L10n.ui(.portFooter), Int(ServerPort.defaultPort)))
            }

            if !runner.isRunning {
                Text(L10n.ui(.visibilityStoppedFooter))
            } else {
                #if !LOOPCTRL_ALL_IN_ONE
                if let notice = runnerAdmin.notice {
                    Text(notice).foregroundColor(.orange)
                } else if !runnerAdmin.isPaired || runnerAdmin.pairing {
                    Text(L10n.ui(.remoteAccessApproveFooter))
                }
                #endif
                switch runnerAdmin.visibility ?? .local {
                case .local: Text(L10n.ui(.remoteAccessOffFooter))
                case .lan: Text(L10n.ui(.remoteAccessOnFooter))
                case .lanAndNearby:
                    Text(runnerAdmin.nearbyPending ? L10n.ui(.visibilityNearbyPendingFooter)
                         : L10n.ui(.visibilityNearbyFooter))
                }
                if runnerAdmin.localNetworkDenied {
                    // Remote clients connecting in still work without it, so
                    // this is the only sign of why nearby discovery cannot.
                    Text(L10n.t(.runnerLocalNetworkDenied)).foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: - Setup

    /// Pairing, image download, Wi-Fi, tunnel app and the mount all live in
    /// DDIMountView; here it is one row that says how far along they are.
    private var setupSection: some View {
        let total = SetupStep.allCases.count
        let done = ddi.isMounted ? total : setupDone
        return Section {
            Button {
                showMountSheet = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        ProgressRing(fraction: Double(done) / Double(total), lineWidth: 3.5,
                                     tint: ddi.isMounted ? .green : .accentColor)
                        if ddi.isMounted {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.green)
                        } else {
                            Text(verbatim: "\(done)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundColor(.accentColor)
                        }
                    }
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.ui(.setupRow)).foregroundColor(.primary)
                        Text(ddi.isMounted ? L10n.ui(.diskImageMounted)
                             : String(format: L10n.ui(.stepsDone), done, total))
                            .font(.subheadline)
                            .foregroundColor(ddi.isMounted ? .green : .secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(L10n.ui(.setupSection))
        } footer: {
            if !ddi.isMounted, let advice = ddi.advice {
                Text(advice)
            }
        }
    }

    // MARK: - Clients

    @ViewBuilder private var clientsSection: some View {
        Section {
            if !runner.isRunning {
                Label(L10n.ui(.clientsNeedService), systemImage: "person.2")
                    .foregroundColor(.secondary)
            } else if !runnerAdmin.isPaired {
                // Two processes in both builds as far as /rpc is concerned:
                // listing and revoking keys needs this app's own key.
                RunnerConnectRows()
            } else {
                if !runnerAdmin.clientsLoaded && runnerAdmin.notice == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if runnerAdmin.clients.isEmpty {
                    Text(L10n.t(.noClients)).foregroundColor(.secondary)
                }
                ClientRows(clients: Array(runnerAdmin.clients.prefix(Self.inlineClientLimit)),
                           pendingRevoke: $pendingRevoke,
                           confirmDisconnect: $confirmDisconnect)
                if runnerAdmin.clients.count > Self.inlineClientLimit {
                    NavigationLink {
                        RunnerClientsView()
                    } label: {
                        Label(String(format: L10n.ui(.showAllClients), runnerAdmin.clients.count),
                              systemImage: "person.2")
                    }
                }
                if !runnerAdmin.otherClients.isEmpty {
                    Button(role: .destructive) { confirmRevokeOthers = true } label: {
                        Label(L10n.t(.revokeOthers), systemImage: "person.crop.circle.badge.xmark")
                    }
                }
                if let notice = runnerAdmin.notice {
                    NoticeLabel(text: notice)
                }
            }
        } header: {
            Text(L10n.ui(.clientsSection))
        } footer: {
            if runner.isRunning && runnerAdmin.isPaired && !runnerAdmin.clients.isEmpty {
                Text(L10n.ui(.clientsSwipeFooter))
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                RunnerLogsView()
            } label: {
                Label(L10n.t(.runnerLogs), systemImage: "terminal")
            }
            NavigationLink {
                LogListView()
            } label: {
                HStack {
                    Label(L10n.ui(.appLogs), systemImage: "doc.text")
                    Spacer()
                    Text(verbatim: "\(logCount)").foregroundColor(.secondary)
                }
            }
            NavigationLink {
                ServiceInfoView(runner: runner)
            } label: {
                Label(L10n.ui(.serviceInfo), systemImage: "info.circle")
            }
        } header: {
            Text(L10n.ui(.diagnosticsSection))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            ValueRow(title: L10n.t(.versionLabel), systemImage: "app.badge", value: Self.appVersion)
            Link(destination: Self.repositoryURL) {
                HStack {
                    Label {
                        Text(verbatim: "GitHub").foregroundColor(.primary)
                    } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    Spacer()
                    Text(verbatim: "Souitou-iop/LoopCtrl")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
            }
            ValueRow(title: L10n.ui(.license), systemImage: "checkmark.seal", value: "Apache-2.0")
        } header: {
            Text(L10n.t(.aboutSection))
        }
    }
}

/// What the running server reports about itself, and the device facts the
/// automation API depends on.
private struct ServiceInfoView: View {
    @ObservedObject var runner: RunnerStatus

    var body: some View {
        List {
            Section {
                switch runner.state {
                case .running(let info):
                    if let version = info.serverVersion {
                        ValueRow(title: L10n.t(.serverLabel), systemImage: "server.rack", value: version, monospaced: true)
                    }
                    if let proto = info.protocolVersion {
                        ValueRow(title: L10n.t(.protocolLabel), systemImage: "arrow.left.arrow.right", value: "v\(proto) · JSON-RPC 2.0")
                    }
                    if let methods = info.methodCount {
                        ValueRow(title: L10n.t(.methodsLabel), systemImage: "list.bullet", value: "\(methods)")
                    }
                    ValueRow(title: L10n.t(.capabilitiesLabel), systemImage: "puzzlepiece.extension",
                             value: "\(info.capabilities.count)")
                case .unknown, .checking:
                    HStack { Spacer(); ProgressView(); Spacer() }
                case .stopped:
                    Label(L10n.ui(.serviceStoppedInfo), systemImage: "pause.circle")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(L10n.ui(.serviceLabel))
            }

            if case .running(let info) = runner.state, !info.capabilities.isEmpty {
                // Clients feature-detect against these, so "is X there" is the
                // useful question: a flat, sorted list.
                Section {
                    ForEach(info.capabilities.sorted(), id: \.self) { tag in
                        Text(verbatim: tag)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(L10n.t(.capabilitiesLabel))
                }
            }

            Section {
                ValueRow(title: L10n.t(.modelLabel), systemImage: "iphone", value: DeviceInfo.modelIdentifier, monospaced: true)
                ValueRow(title: L10n.t(.systemLabel), systemImage: "gearshape",
                         value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                // Points and pixels — the two coordinate spaces the API mixes.
                ValueRow(title: L10n.t(.screenLabel), systemImage: "rectangle.dashed",
                         value: DeviceInfo.screenDescription, monospaced: true)
            } header: {
                Text(L10n.t(.deviceSection))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.ui(.serviceInfo))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Facts about this device that don't need the server running.
enum DeviceInfo {
    /// e.g. "iPhone17,2". `UIDevice.model` only ever says "iPhone".
    static var modelIdentifier: String {
        // On the simulator `utsname.machine` reports the host architecture;
        // the real identifier is passed in the environment instead.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var sysinfo = utsname()
        uname(&sysinfo)
        let raw = withUnsafeBytes(of: &sysinfo.machine) { buf in
            buf.prefix { $0 != 0 }.map { UInt8($0) }
        }
        let id = String(decoding: raw, as: UTF8.self)
        return id.isEmpty ? UIDevice.current.model : id
    }

    /// Points and pixels — the two coordinate spaces the automation API mixes.
    static var screenDescription: String {
        let b = UIScreen.main.bounds
        let s = UIScreen.main.scale
        return "\(Int(b.width))×\(Int(b.height)) pt · \(Int(b.width * s))×\(Int(b.height * s)) px"
    }
}
