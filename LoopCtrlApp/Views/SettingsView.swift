import SwiftUI
import UIKit

/// The app's home screen: the three things that decide whether automation can
/// run (pairing, the Developer Disk Image, the server) and the one action that
/// moves it forward. Everything else is in `OptionsView`, behind the gear.
///
/// Automation runs in the XCUITest runner — a separate app, or in-process in
/// the all-in-one build — so the server state shown here is what an HTTP probe
/// of it says, and Start/Stop go through its `loopctrl://` scheme.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    /// Re-probed whenever the screen comes back rather than held in AppState:
    /// the DDI can be unmounted while the app sits in the background.
    @State private var ddi = DeveloperDiskImage.status()
    @State private var hasPairingFile = PairingFileStore.exists
    @State private var launchFailed = false
    @State private var showMountSheet = false
    @State private var showOptions = false
    @State private var showAddRemote = false
    /// DEBUG `-remoteShow list|connection`: a 远程服务 page pushed at launch.
    @State private var debugRemotePage: String?
    @EnvironmentObject private var remote: RemoteServiceStore
    @StateObject private var runner = RunnerStatus()
    @EnvironmentObject private var runnerAdmin: RunnerAdmin

    /// The runner registers this scheme; opening it starts the automation server.
    ///
    /// `callback` asks the runner to bounce back to us once it has decided
    /// whether the server came up, appending `status` and `address`. Without it
    /// the user is left in the runner — a blank XCTest app with nothing to show
    /// — wondering whether anything happened. `port` is the Settings choice: the
    /// two-IPA runner has its own container and can't read it.
    private var runnerURL: URL {
        URL(string: "loopctrl://start?port=\(ServerPort.stored)&callback=loopctrl-app://started")!
    }

    /// Stopping goes through the URL scheme too. The only other route is
    /// `config{stop_server:true}` over /rpc, which needs an encrypted envelope —
    /// and this app deliberately holds no pairing key.
    private static let runnerStopURL = URL(string: "loopctrl://stop?callback=loopctrl-app://stopped")!

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 0)

                    AppIconImage()

                    Text(verbatim: "LoopCtrl")
                        .font(.largeTitle.bold())

                    VStack(spacing: 20) {
                        // A request waiting for an answer comes first: it
                        // stays here until answered or timed out, whatever
                        // happened to its notification.
                        if runner.isRunning {
                            ForEach(runnerAdmin.pendingRequests) { request in
                                PairRequestCard(request: request)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        statusCard
                        if runner.isRunning {
                            connectionCard
                        }
                        RemoteServiceCard { showAddRemote = true }
                        if runner.isRunning && runnerAdmin.isPaired {
                            AuthorizationEntryRow()
                        }
                        primaryButton
                        hint
                    }
                    .frame(maxWidth: 340)

                    Spacer(minLength: 0)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .animation(.default, value: runner.state)
        .animation(.default, value: ddi.isMounted)
        .animation(.default, value: runnerAdmin.visibility)
        .animation(.default, value: runnerAdmin.pendingRequests)
        .pairingRequestPolling(admin: runnerAdmin, active: runner.isRunning)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showOptions = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(L10n.ui(.settingsTitle))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refresh()
            runner.startPolling()
            #if DEBUG
            // Screenshots without tapping: -remoteShow add|list|connection|settings
            switch UserDefaults.standard.string(forKey: "remoteShow") {
            case "add": showAddRemote = true
            case "settings": showOptions = true
            case let page?: debugRemotePage = page
            case nil: break
            }
            #endif
        }
        .navigationDestination(isPresented: Binding(
            get: { debugRemotePage != nil }, set: { if !$0 { debugRemotePage = nil } })) {
            if debugRemotePage == "connection", let id = remote.primary?.id {
                RemoteConnectionDetailView(connectionID: id)
            } else {
                RemoteServiceView()
            }
        }
        .onDisappear { runner.stopPolling() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: PairingFileStore.didImport)) { _ in refresh() }
        .onOpenURL { url in
            // The runner bounced back: loopctrl-app://started?status=…&address=…
            guard url.scheme == "loopctrl-app", !RemoteInvite.isInviteLink(url) else { return }
            // loopctrl-app://started or loopctrl-app://stopped
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let status = items.first { $0.name == "status" }?.value
            launchFailed = (status == "failed")
            // Trust the probe over the reported status — by the time we're back,
            // asking the server directly is both cheap and authoritative.
            Task { await runner.check() }
        }
        // Re-probe on dismiss: a mount or a new pairing file changes the card.
        .sheet(isPresented: $showMountSheet, onDismiss: refresh) {
            DDIMountView()
        }
        .sheet(isPresented: $showOptions, onDismiss: refresh) {
            OptionsView(runner: runner)
                .environmentObject(appState)
                .environmentObject(runnerAdmin)
                .environmentObject(remote)
        }
        .sheet(isPresented: $showAddRemote, onDismiss: { remote.incomingInvite = nil }) {
            AddConnectionSheet(initialInvite: remote.incomingInvite)
                .environmentObject(remote)
                .environmentObject(runnerAdmin)
        }
        // An invite opened as a link: straight to its confirmation.
        .onReceive(remote.$incomingInvite) { invite in
            guard invite != nil else { return }
            if showOptions {
                // One sheet at a time: let Settings go away first.
                showOptions = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showAddRemote = true }
            } else {
                showAddRemote = true
            }
        }
        .alert(L10n.rs(.title), isPresented: Binding(
            get: { remote.incomingInviteError != nil },
            set: { if !$0 { remote.incomingInviteError = nil } })) {
            Button(L10n.rs(.done), role: .cancel) {}
        } message: {
            Text(remote.incomingInviteError.map(RemoteServiceText.parse) ?? "")
        }
        // Pre-approvals confirmed while the service was down reach it now.
        .task(id: runner.isRunning) {
            guard runner.isRunning else { return }
            await remote.syncAllPreApprovals(admin: runnerAdmin)
            await remote.flushPendingRevocations(admin: runnerAdmin)
        }
    }

    private func refresh() {
        ddi = DeveloperDiskImage.status()
        hasPairingFile = PairingFileStore.exists
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(spacing: 0) {
            StatusRow(icon: "link",
                      title: L10n.ui(.pairingLabel),
                      value: hasPairingFile ? L10n.ui(.paired) : L10n.ui(.notPaired),
                      // Only needed to mount: once the image is up, a missing
                      // pairing file is not something to warn about.
                      tone: hasPairingFile ? .good : ddi.isMounted ? .idle : .warning)
            Divider().padding(.leading, 50)
            StatusRow(icon: "externaldrive",
                      title: L10n.ui(.diskImageLabel),
                      value: ddi.localizedSummary,
                      tone: ddi.isMounted ? .good : .warning)
            Divider().padding(.leading, 50)
            serviceRow
        }
        .padding(.vertical, 4)
        .card()
    }

    @ViewBuilder private var serviceRow: some View {
        switch runner.state {
        case .unknown, .checking:
            StatusRow(icon: "bolt.horizontal", title: L10n.ui(.serviceLabel),
                      value: L10n.t(.checking), tone: .busy)
        case .running:
            StatusRow(icon: "bolt.horizontal", title: L10n.ui(.serviceLabel),
                      value: L10n.t(.running), tone: .good)
        case .stopped:
            StatusRow(icon: "bolt.horizontal", title: L10n.ui(.serviceLabel),
                      value: L10n.t(.stopped), tone: .idle)
        }
    }

    // MARK: - Connection

    private var remoteOn: Bool {
        runnerAdmin.visibility.map { $0 != .local } ?? false
    }

    /// The browser page for a host we advertise: the same control page the relay
    /// hands out, served plain over the LAN (docs/remote-control.md). Optional
    /// because a host that cannot form a URL is no use to anyone, and forcing
    /// one here would put the failure in the middle of a card.
    private static func controlPageURL(host: String, port: Int) -> URL? {
        URL(string: "http://\(host):\(port)/remote")
    }

    /// The address to hand clients. The runner's own list comes first: it is the
    /// process holding the port, and that list has already left out tunnels and
    /// cellular. It is empty until a `config` call has been made, which the
    /// all-in-one app never needs for its own settings (it reads the choice in
    /// process, without pairing) — so read the interface as a fallback. Same
    /// process, same answer; the fallback is only ever narrower.
    private var lanHost: String? {
        runnerAdmin.lanAddresses.first?.address ?? AppState.wifiAddress()
    }

    /// Where clients reach the server, and the switch that opens it to the LAN.
    private var connectionCard: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                AddressRow(title: L10n.ui(.localAddress),
                           address: "127.0.0.1:\(appState.serverPort)")
                if remoteOn {
                    Divider().padding(.leading, 16)
                    if let host = lanHost {
                        AddressRow(title: L10n.ui(.lanAddress),
                                   address: "\(host):\(appState.serverPort)")
                        if let page = Self.controlPageURL(host: host, port: appState.serverPort) {
                            Divider().padding(.leading, 16)
                            ControlPageRow(url: page)
                        }
                    } else {
                        AddressRow(title: L10n.ui(.lanAddress), address: nil)
                    }
                }
                Divider().padding(.leading, 16)
                HStack {
                    Text(L10n.ui(.remoteAccess))
                    Spacer()
                    if runnerAdmin.pairing || runnerAdmin.changingVisibility {
                        ProgressView()
                    } else {
                        Toggle("", isOn: Binding(
                            get: { remoteOn },
                            set: { on in Task { await setRemoteAccess(on) } }))
                            .labelsHidden()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .padding(.vertical, 4)
            .card()

            Text(remoteFooter)
                .font(.footnote)
                .foregroundColor(runnerAdmin.notice == nil ? .secondary : .orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Remote access can also be switched from the runner's notification,
        // so keep it current while shown. Pairing is only ever started by the
        // switch itself. Over /rpc, `pairingRequestPolling` above re-reads
        // `config`, which carries the visibility too.
        .task(id: runnerAdmin.isPaired) {
            #if LOOPCTRL_ALL_IN_ONE
            while !Task.isCancelled {
                runnerAdmin.refreshInProcessVisibility()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            #endif
        }
    }

    private var remoteFooter: String {
        #if LOOPCTRL_ALL_IN_ONE
        // The runner is in this process: nothing to pair, nothing to approve.
        return remoteOn ? L10n.ui(.remoteAccessOnFooter) : L10n.ui(.remoteAccessOffFooter)
        #else
        if let notice = runnerAdmin.notice { return notice }
        if !runnerAdmin.isPaired || runnerAdmin.pairing { return L10n.ui(.remoteAccessApproveFooter) }
        return remoteOn ? L10n.ui(.remoteAccessOnFooter) : L10n.ui(.remoteAccessOffFooter)
        #endif
    }

    /// Changing who can reach the runner is a `config` call, which needs this
    /// app paired with it: the first time, that asks for the user's approval.
    /// The all-in-one runner shares this process and is told directly.
    private func setRemoteAccess(_ on: Bool) async {
        #if LOOPCTRL_ALL_IN_ONE
        await runnerAdmin.setRemoteAccessInProcess(on)
        return
        #endif
        if !runnerAdmin.isPaired {
            await runnerAdmin.connect()
            guard runnerAdmin.isPaired else { return }
        }
        if on {
            // Keep nearby discovery if it was already on.
            if !remoteOn { await runnerAdmin.setVisibility(.lan) }
        } else {
            await runnerAdmin.setVisibility(.local)
        }
    }

    // MARK: - Primary action

    /// One button, whichever step is next: mount the image, start, or stop.
    @ViewBuilder private var primaryButton: some View {
        if runner.isRunning {
            Button(role: .destructive) {
                stopRunner()
            } label: {
                primaryLabel(L10n.t(.stopServerButton), systemImage: "stop.fill")
            }
            .primaryAction(.red)
        } else if !ddi.isMounted {
            Button {
                showMountSheet = true
            } label: {
                primaryLabel(L10n.ui(.mountDiskImage), systemImage: "externaldrive.badge.plus")
            }
            .primaryAction(.accentColor)
        } else {
            Button {
                startRunner()
            } label: {
                primaryLabel(L10n.t(.startServer), systemImage: "play.fill")
            }
            .primaryAction(.green)
        }
    }

    private func primaryLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity)
    }

    /// One short line under the button: what went wrong, or what it does.
    @ViewBuilder private var hint: some View {
        if launchFailed {
            Label {
                #if LOOPCTRL_ALL_IN_ONE
                Text(L10n.ui(.runnerStartFailed))
                #else
                Text(L10n.ui(.runnerOpenFailed))
                #endif
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundColor(.orange)
            .multilineTextAlignment(.center)
        } else if let text = hintText {
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hintText: String? {
        if runner.isRunning { return L10n.t(.serverRunningFooter) }
        if !ddi.isMounted { return L10n.t(.mountFirstFooter) }
        #if LOOPCTRL_ALL_IN_ONE
        return nil
        #else
        return L10n.t(.startOpensRunnerFooter)
        #endif
    }

    private func stopRunner() {
        #if LOOPCTRL_ALL_IN_ONE
        // The server's test lives in this process: it drops its listener and
        // stays parked, so LoopCtrl stays open and Start works again.
        InProcessRunner.stop()
        Task { await recheckAfterStop() }
        return
        #endif
        Task {
            // Paired: stop over /rpc, without leaving this screen.
            if await runnerAdmin.stopServer() {
                await recheckAfterStop()
                return
            }
            // Otherwise opening the runner's scheme brings it to the front,
            // where it stops its server and ends the test. It bounces back here
            // afterwards, but the probe is what settles the displayed state.
            UIApplication.shared.open(Self.runnerStopURL) { _ in
                Task { await recheckAfterStop() }
            }
        }
    }

    /// Give the server a moment to actually tear the listener down; probing
    /// instantly would still see it up and flip back to "Running" for a cycle.
    private func recheckAfterStop() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await runner.check()
    }

    private func startRunner() {
        launchFailed = false
        #if LOOPCTRL_ALL_IN_ONE
        do {
            try InProcessRunner.start()
        } catch {
            loopctrlLog("In-process start failed: \(error.localizedDescription)")
            launchFailed = true
        }
        return
        #endif
        UIApplication.shared.open(runnerURL) { ok in
            // The usual cause is the runner simply not being installed — the two
            // IPAs ship separately, so having this app is no guarantee.
            launchFailed = !ok
        }
    }
}

/// An address a client connects to, with a copy button; nil when there is none.
private struct AddressRow: View {
    let title: String
    let address: String?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            if let address {
                Text(verbatim: address)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Button {
                    UIPasteboard.general.string = address
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? L10n.ui(.copied) : address)
            } else {
                Text(L10n.ui(.noWiFi)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The browser's address of the control page, and the two things a person does
/// with it: copy it, or hand it to another device. The URL gets a line of its
/// own because the address is the thing to read — squeezed onto the title line
/// it truncates in the middle, which is the one part of a URL nobody can guess.
/// Same word and same affordances as the relay's row, so 「网页控制」 means one
/// thing in this app (docs/relay-enrollment.md).
private struct ControlPageRow: View {
    let url: URL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.ui(.controlPage))
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.url = url
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 20)
                }
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 20)
                }
                .accessibilityLabel(L10n.ui(.shareControlPage))
            }
            .buttonStyle(.borderless)
            Text(verbatim: url.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// One line of the status card: icon, name, and a coloured dot with the state.
private struct StatusRow: View {
    enum Tone { case good, warning, idle, busy }

    let icon: String
    let title: String
    let value: String
    let tone: Tone
    /// Shown under the value, selectable (the server address).
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundColor(.secondary)
                .frame(width: 22)
            Text(title)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    if tone == .busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle().fill(color).frame(width: 8, height: 8)
                    }
                    Text(value).foregroundColor(.secondary)
                }
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .good: return .green
        case .warning: return .orange
        case .idle, .busy: return .secondary
        }
    }
}
