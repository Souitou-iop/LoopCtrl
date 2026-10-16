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
    @StateObject private var runner = RunnerStatus(port: 8200)
    @EnvironmentObject private var runnerAdmin: RunnerAdmin

    /// The runner registers this scheme; opening it starts the automation server.
    ///
    /// `callback` asks the runner to bounce back to us once it has decided
    /// whether the server came up, appending `status` and `address`. Without it
    /// the user is left in the runner — a blank XCTest app with nothing to show
    /// — wondering whether anything happened.
    private static let runnerURL = URL(string: "loopctrl://start?callback=loopctrl-app://started")!

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
                        statusCard
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
        }
        .onDisappear { runner.stopPolling() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: PairingFileStore.didImport)) { _ in refresh() }
        .onOpenURL { url in
            // The runner bounced back: loopctrl-app://started?status=…&address=…
            guard url.scheme == "loopctrl-app" else { return }
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
                      value: L10n.t(.running), tone: .good,
                      detail: "127.0.0.1:\(appState.serverPort)")
        case .stopped:
            StatusRow(icon: "bolt.horizontal", title: L10n.ui(.serviceLabel),
                      value: L10n.t(.stopped), tone: .idle)
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
        // Same URL, same handler — but the test it ends lives in this process,
        // and XCTest exit()s when its test returns: Stop closes LoopCtrl. Starting
        // again is a fresh launch (XCTest bootstraps once per process).
        InProcessRunner.handle(Self.runnerStopURL)
        return
        #endif
        // Opening the runner's scheme brings it to the front, where it stops its
        // server and ends the test. It bounces back here afterwards, but the
        // probe is what settles the displayed state.
        UIApplication.shared.open(Self.runnerStopURL) { _ in
            Task {
                // Give the runner a moment to actually tear the listener down;
                // probing instantly would still see it up and flip back to
                // "Running" for one cycle.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await runner.check()
            }
        }
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
        UIApplication.shared.open(Self.runnerURL) { ok in
            // The usual cause is the runner simply not being installed — the two
            // IPAs ship separately, so having this app is no guarantee.
            launchFailed = !ok
        }
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
