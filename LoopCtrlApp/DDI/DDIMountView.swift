import SwiftUI
import UniformTypeIdentifiers

/// The five things a mount needs, in the order the flow walks through them.
///
/// Pairing first: it is the one step that may need another machine (on iOS
/// before 27), so surfacing it early avoids finishing the on-device steps only
/// to discover a Mac is required. The image before the tunnel: the tunnel
/// takes over local networking, so fetching ~100 MB afterwards is asking for a
/// stalled download. Wi-Fi before the tunnel, which rides the local interface
/// cellular doesn't provide.
enum SetupStep: Int, CaseIterable, Identifiable {
    case pairing, image, wifi, tunnel, mount

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .pairing: return L10n.ui(.stepPairing)
        case .image: return L10n.t(.ddiComponentTitle)
        case .wifi: return L10n.t(.wifiRequired)
        case .tunnel: return L10n.ui(.stepTunnel)
        case .mount: return L10n.ui(.stepMount)
        }
    }

    var systemImage: String {
        switch self {
        case .pairing: return "link"
        case .image: return "arrow.down.circle"
        case .wifi: return "wifi"
        case .tunnel: return "point.3.connected.trianglepath.dotted"
        case .mount: return "externaldrive.badge.plus"
        }
    }
}

/// The on-device DDI mounting flow, as a guided sequence.
///
/// A status header says where things stand; below it the steps form a
/// timeline: finished ones collapse to a check, the first unfinished one opens
/// with its one action, later ones wait dimmed. Any step can be reopened, e.g.
/// to replace the pairing file. A mount has preconditions the user must meet
/// in order, and a button that just said "failed" would leave them guessing
/// which one was missing — so each step says what it is waiting for.
struct DDIMountView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mounter = DDIMounter()
    @StateObject private var images = DeveloperDiskImageStore()
    @ObservedObject private var pairing = OnDevicePairing.shared

    @State private var showPairingPicker = false
    @State private var pairingError: String?
    @State private var hasPairingFile = PairingFileStore.exists
    @State private var imagesReady = DeveloperDiskImageStore.isComplete
    @State private var downloadError: String?
    @State private var vpnInstalled = false
    @State private var tunnelApp = TunnelApp.selected
    @State private var tunnelUp = false
    /// Last connection test through the tunnel, and the interfaces seen then.
    @State private var tunnelProbe: LocalDevVPN.TunnelProbe?
    @State private var interfacesSeen = ""
    @State private var probing = false
    @State private var onWiFi = false
    @State private var networkObserved = false
    /// What iOS reports as mounted, independent of this screen's own mount.
    @State private var ddiStatus = DeveloperDiskImage.status()

    /// Which step is open. Follows the first unfinished step until the user
    /// opens or closes one themselves; finishing a step hands it back.
    @State private var followCurrent = true
    @State private var chosenStep: SetupStep?
    @State private var showTroubleshooting = false

    /// StikDebug mounts the DDI on-device; the bare scheme just opens the app.
    private static let stikDebugURL = URL(string: "stikdebug://")!
    /// Sideload-only, so the fallback is its distribution site.
    private static let stikDebugSiteURL = URL(string: "https://stikdebug.xyz")!

    /// All prerequisites. The tunnel is included because it drops on every
    /// reboot — leaving it out let the mount fail with a socket error naming
    /// nothing the user could act on. Wi-Fi because the tunnel needs a local
    /// interface that cellular doesn't offer.
    private var canMount: Bool {
        hasPairingFile && imagesReady && onWiFi && tunnelUp && !mounter.isRunning
    }

    private var isMounted: Bool {
        if case .mounted = mounter.phase { return true }
        return ddiStatus.isMounted
    }

    private func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .pairing: return hasPairingFile
        case .image: return imagesReady
        case .wifi: return onWiFi
        case .tunnel: return tunnelUp
        case .mount: return isMounted
        }
    }

    /// The first unfinished step; nil once the image is mounted.
    private var currentStep: SetupStep? {
        if isMounted { return nil }
        return SetupStep.allCases.first { !isDone($0) }
    }

    private var stepsLeft: Int {
        isMounted ? 0 : SetupStep.allCases.filter { !isDone($0) }.count
    }

    private func isOpen(_ step: SetupStep) -> Bool {
        // A pairing or mount in progress keeps its own step in view.
        if step == .pairing && pairing.isRunning { return true }
        if step == .mount && mounter.isRunning { return true }
        return (followCurrent ? currentStep : chosenStep) == step
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusHeader
                    timeline
                    troubleshooting
                }
                .padding(.horizontal)
                .padding(.vertical, 20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .animation(.default, value: currentStep)
            .animation(.default, value: chosenStep)
            .animation(.default, value: followCurrent)
            .animation(.default, value: mounter.phase)
            .animation(.default, value: pairing.phase)
            .navigationTitle(L10n.ui(.setupRow))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t(.doneButton)) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                refreshVPNState()
                subscribeToNetworkOnce()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in
                refreshVPNState()
                ddiStatus = DeveloperDiskImage.status()
            }
            .onOpenURL { url in
                if !url.isFileURL { refreshVPNState() }   // LocalDevVPN bounced us back
            }
            .onReceive(NotificationCenter.default.publisher(for: PairingFileStore.didImport)) { _ in
                hasPairingFile = true
                pairingError = nil
            }
            // LocalDevVPN bounces back a fixed second after it starts
            // connecting, often before the tunnel is up: keep checking until it is.
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                if !tunnelUp { refreshVPNState() }
            }
            .onChange(of: currentStep) { _ in
                // A step just finished (or came undone): open the next one.
                followCurrent = true
                chosenStep = nil
            }
            .onChange(of: mounter.phase) { phase in
                if case .mounted = phase { ddiStatus = DeveloperDiskImage.status() }
            }
            .fileImporter(isPresented: $showPairingPicker,
                          allowedContentTypes: PairingFileStore.supportedContentTypes) { result in
                switch result {
                case .success(let url):
                    do {
                        try PairingFileStore.importFile(from: url)
                        hasPairingFile = true
                        pairingError = nil
                    } catch {
                        pairingError = error.localizedDescription
                    }
                case .failure(let error):
                    pairingError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Header

    private var statusHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                ProgressRing(fraction: Double(SetupStep.allCases.count - stepsLeft) / Double(SetupStep.allCases.count),
                             lineWidth: 6,
                             tint: isMounted ? .green : .accentColor)
                Image(systemName: isMounted ? "checkmark" : "externaldrive")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(isMounted ? .green : .accentColor)
            }
            .frame(width: 84, height: 84)

            Text(headerTitle)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(isMounted ? L10n.t(.mountNotPersistentFooter) : L10n.t(.mountIntro))
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var headerTitle: String {
        if isMounted { return L10n.ui(.diskImageMounted) }
        if mounter.isRunning { return L10n.ui(.mounting) }
        return stepsLeft == 1 ? L10n.ui(.oneStepLeft) : String(format: L10n.ui(.stepsLeft), stepsLeft)
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(spacing: 0) {
            ForEach(SetupStep.allCases) { step in
                stepCard(step, isLast: step == SetupStep.allCases.last)
            }
        }
    }

    private enum StepState { case done, current, upcoming }

    private func state(of step: SetupStep) -> StepState {
        if isDone(step) { return .done }
        return step == currentStep ? .current : .upcoming
    }

    private func toggle(_ step: SetupStep) {
        let open = isOpen(step)
        followCurrent = false
        chosenStep = open ? nil : step
    }

    private func stepCard(_ step: SetupStep, isLast: Bool) -> some View {
        let state = state(of: step)
        let open = isOpen(step)
        return HStack(alignment: .top, spacing: 14) {
            // The rail: badge, then a line down to the next step.
            VStack(spacing: 6) {
                stepBadge(step, state: state)
                if !isLast {
                    Rectangle()
                        .fill(state == .done ? Color.green.opacity(0.5) : Color(.separator))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    toggle(step)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(summary(of: step))
                                .font(.subheadline)
                                .foregroundColor(state == .done ? .green : .secondary)
                                .lineLimit(open ? nil : 1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Color(.tertiaryLabel))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(16)

                if open {
                    VStack(alignment: .leading, spacing: 14) {
                        stepContent(step)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: 18)
            .opacity(state == .upcoming && !open ? 0.55 : 1)
            .padding(.bottom, isLast ? 0 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stepBadge(_ step: SetupStep, state: StepState) -> some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Color.green)
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
            case .current:
                Circle().fill(Color.accentColor)
                Text(verbatim: "\(step.rawValue + 1)")
                    .font(.footnote.weight(.bold))
                    .foregroundColor(.white)
            case .upcoming:
                Circle().strokeBorder(Color(.tertiaryLabel), lineWidth: 1.5)
                Text(verbatim: "\(step.rawValue + 1)")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    /// The one line under a step's title.
    private func summary(of step: SetupStep) -> String {
        switch step {
        case .pairing:
            switch pairing.phase {
            case .waiting, .showPin: return L10n.ui(.pairingInProgress)
            default: break
            }
            guard hasPairingFile else { return L10n.ui(.notPaired) }
            return "\(L10n.t(.pairingImported))\(PairingFileStore.importedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")"
        case .image:
            if images.isDownloading { return "\(L10n.ui(.downloading)) \(Int(images.progress * 100))%" }
            return imagesReady
                ? "\(L10n.t(.ddiDownloaded)) · \(ByteCountFormatter.string(fromByteCount: DeveloperDiskImageStore.totalBytesOnDisk, countStyle: .file))"
                : L10n.ui(.notDownloaded)
        case .wifi:
            return onWiFi ? L10n.t(.wifiConnected) : L10n.t(.wifiMissing)
        case .tunnel:
            return "\(tunnelApp.displayName) · \(tunnelChip.text)"
        case .mount:
            switch mounter.phase {
            case .connecting, .queryingDevice, .finalizing: return phaseLabel
            case .uploading(let fraction): return "\(L10n.t(.uploadingImage)) \(Int(fraction * 100))%"
            case .failed: return L10n.t(.mountFailed)
            case .mounted: return L10n.ui(.mounted)
            case .idle: return ddiStatus.isMounted ? L10n.ui(.mounted) : L10n.ui(.notMounted)
            }
        }
    }

    @ViewBuilder private func stepContent(_ step: SetupStep) -> some View {
        switch step {
        case .pairing: pairingContent
        case .image: imageContent
        case .wifi: wifiContent
        case .tunnel: tunnelContent
        case .mount: mountContent
        }
    }

    // MARK: - ① Pairing

    /// The pairing file proves to lockdownd that we're a trusted host. Made on
    /// this iPhone (iOS 27's device-initiated pairing) or imported.
    @ViewBuilder private var pairingContent: some View {
        switch pairing.phase {
        case .waiting:
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                Text(L10n.t(.pairWaitingSteps))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            stopPairingButton

        case .showPin(let pin):
            VStack(spacing: 6) {
                Text(L10n.t(.pairEnterPin))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(verbatim: pin)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            stopPairingButton

        case .idle, .paired, .failed:
            if OnDevicePairing.isSupported {
                ChoiceCard(systemImage: "iphone.radiowaves.left.and.right",
                           title: hasPairingFile ? L10n.ui(.pairAgainOnDevice) : L10n.ui(.pairOnThisIPhone),
                           detail: L10n.t(.pairOnDeviceHint)) {
                    pairingError = nil
                    pairing.start()
                }
            }
            ChoiceCard(systemImage: "doc.badge.plus",
                       title: hasPairingFile ? L10n.ui(.replacePairingFileShort) : L10n.ui(.importPairingFileShort),
                       detail: L10n.ui(.importPairingDetail)) {
                showPairingPicker = true
            }
            if !hasPairingFile {
                Text(L10n.t(.pairingHint))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = pairing.phase {
                NoticeLabel(text: message)
            }
        }

        if let pairingError {
            NoticeLabel(text: pairingError)
        }
    }

    private var stopPairingButton: some View {
        Button(role: .destructive) {
            pairing.stop()
        } label: {
            Label(L10n.t(.pairStop), systemImage: "xmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - ② Image

    @ViewBuilder private var imageContent: some View {
        Text(L10n.t(.ddiDownloadHint))
            .font(.subheadline)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if images.isDownloading {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: images.progress)
                if let msg = images.statusMessage {
                    Text(msg).font(.caption).foregroundColor(.secondary)
                }
            }
        } else if !imagesReady {
            Button {
                Task {
                    do {
                        try await images.download()
                        imagesReady = DeveloperDiskImageStore.isComplete
                        downloadError = nil
                    } catch {
                        downloadError = error.localizedDescription
                    }
                }
            } label: {
                stepActionLabel(L10n.t(.downloadImageFiles), systemImage: "arrow.down")
            }
            .primaryAction(.accentColor)
        }

        if let downloadError {
            NoticeLabel(text: downloadError)
        }
    }

    // MARK: - ③ Wi-Fi

    /// The tunnel rides the local network interface, which cellular does not
    /// provide — so any Wi-Fi will do, but some Wi-Fi is required.
    @ViewBuilder private var wifiContent: some View {
        Label {
            Text(onWiFi ? L10n.t(.wifiConnected) : L10n.t(.wifiMissing))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: onWiFi ? "wifi" : "wifi.slash")
                .foregroundColor(onWiFi ? .green : .orange)
        }
        .font(.subheadline)
        Text(L10n.t(.wifiFooter))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - ④ Tunnel

    private var tunnelChip: (text: String, tone: StateChip.Tone) {
        if tunnelUp { return (L10n.ui(.tunnelConnected), .good) }
        switch tunnelProbe {
        case .localNetworkDenied?: return (L10n.ui(.tunnelLocalNetworkDenied), .bad)
        case .notDevice?: return (L10n.ui(.tunnelNotDevice), .warning)
        case .none where probing: return (L10n.t(.checking), .busy)
        default: break
        }
        return vpnInstalled ? (L10n.ui(.tunnelNotConnected), .warning) : (L10n.ui(.tunnelNotInstalled), .idle)
    }

    /// LocalDevVPN exposes localdevvpn://enable?scheme=…, so this can send the
    /// user straight into connecting and get them back; Shadowrocket has
    /// shadowrocket://connect but stays in front afterwards.
    @ViewBuilder private var tunnelContent: some View {
        Picker(L10n.t(.tunnelAppLabel), selection: $tunnelApp) {
            ForEach(TunnelApp.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: tunnelApp) { app in
            TunnelApp.selected = app
            refreshVPNState()
        }

        HStack {
            StateChip(text: tunnelChip.text, tone: tunnelChip.tone)
            Spacer()
            Text(verbatim: DDIMounter.tunnelAddress)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }

        Text(tunnelDetail)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if !tunnelUp, tunnelProbe == .localNetworkDenied {
            Button {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                stepActionLabel(L10n.t(.openSettings), systemImage: "gear")
            }
            .primaryAction(.accentColor)
        } else if !tunnelUp {
            Button {
                // The bare App Store link is the fallback when it isn't installed.
                UIApplication.shared.open(vpnInstalled ? tunnelApp.connectURL : tunnelApp.appStoreURL)
            } label: {
                stepActionLabel(String(format: vpnInstalled ? L10n.t(.openVPNAndConnect) : L10n.t(.getVPNFromAppStore),
                                       tunnelApp.displayName),
                                systemImage: vpnInstalled ? "arrow.up.forward.app" : "bag")
            }
            .primaryAction(.accentColor)
        }

        if tunnelApp == .shadowrocket {
            hint(L10n.t(.shadowrocketRouteHint), systemImage: "signpost.right")
        }
        if tunnelUp {
            hint(L10n.t(.tunnelDetectedFooter), systemImage: "checkmark.shield")
        } else {
            hint(L10n.t(.cannotStartVPNFooter), systemImage: "info.circle")
            if case .unreachable? = tunnelProbe, vpnInstalled {
                // Connected but still not found: show what is there, so a
                // changed tunnel address is visible at a glance.
                hint(L10n.t(.interfacesSeen) + " " + interfacesSeen, systemImage: "network")
            }
        }
    }

    private var tunnelDetail: String {
        if tunnelUp { return "\(L10n.t(.tunnelUpDetail)) (\(DDIMounter.tunnelAddress))" }
        if tunnelProbe == .localNetworkDenied { return L10n.t(.localNetworkDeniedDetail) }
        if tunnelProbe == .notDevice { return L10n.t(.tunnelNotDeviceDetail) }
        return vpnInstalled
            ? "\(L10n.t(.vpnInstalledDetail)) (\(DDIMounter.tunnelAddress))"
            : L10n.t(.vpnMissingDetail)
    }

    // MARK: - ⑤ Mount

    @ViewBuilder private var mountContent: some View {
        switch mounter.phase {
        case .idle, .failed:
            if case .failed(let message) = mounter.phase {
                VStack(alignment: .leading, spacing: 4) {
                    NoticeLabel(text: L10n.t(.mountFailed))
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if ddiStatus.isMounted, case .idle = mounter.phase {
                Label(L10n.t(.ddiReadyFooter), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    Task { await mounter.mount() }
                } label: {
                    stepActionLabel(L10n.t(.mountButton), systemImage: "externaldrive.badge.plus")
                }
                .primaryAction(.accentColor)
                .disabled(!canMount)

                Text(canMount ? L10n.t(.firstMountNetworkFooter)
                     : "\(L10n.t(.finishStepsFirst)) — \(missingPrerequisite).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .connecting, .queryingDevice, .finalizing:
            HStack(spacing: 10) {
                ProgressView()
                Text(phaseLabel).foregroundColor(.secondary)
            }

        case .uploading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text("\(L10n.t(.uploadingImage)) \(Int(fraction * 100))%")
                    .font(.caption).foregroundColor(.secondary)
            }

        case .mounted:
            Label(L10n.t(.mountedOK), systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Names the first unmet prerequisite, so a disabled button explains itself.
    private var missingPrerequisite: String {
        if !hasPairingFile { return L10n.t(.noPairingFile) }
        if !imagesReady { return L10n.t(.imagesNotDownloaded) }
        if !onWiFi { return L10n.t(.notOnWiFi) }
        if !tunnelUp {
            if tunnelProbe == .localNetworkDenied { return L10n.t(.localNetworkDeniedDetail) }
            if tunnelProbe == .notDevice { return L10n.t(.tunnelNotDeviceDetail) }
            return String(format: vpnInstalled ? L10n.t(.vpnNotConnected) : L10n.t(.vpnNotInstalled),
                          tunnelApp.displayName)
        }
        return "something is missing"
    }

    private var phaseLabel: String {
        switch mounter.phase {
        case .connecting:     return L10n.ui(.phaseConnecting)
        case .queryingDevice: return L10n.ui(.phaseQuerying)
        case .finalizing:     return L10n.ui(.phaseFinalizing)
        default:              return ""
        }
    }

    // MARK: - Troubleshooting

    private var troubleshooting: some View {
        DisclosureGroup(isExpanded: $showTroubleshooting) {
            VStack(alignment: .leading, spacing: 16) {
                troubleRow(L10n.t(.interfacesSeen), value: interfacesSeen.isEmpty ? "—" : interfacesSeen)
                troubleRow(L10n.t(.mountPoint), value: ddiStatus.layout?.rawValue ?? "—")
                if !ddiStatus.isMounted, let advice = ddiStatus.advice {
                    hint(advice, systemImage: "info.circle")
                }

                HStack(spacing: 10) {
                    // Same mount as step ⑤, for when the image is already up
                    // and the runner still won't start.
                    if isMounted {
                        Button {
                            Task { await mounter.mount() }
                        } label: {
                            Label(L10n.ui(.remount), systemImage: "arrow.clockwise")
                        }
                        .disabled(!canMount)
                    }
                    if hasPairingFile, !pairing.isRunning {
                        Button(role: .destructive) {
                            PairingFileStore.remove()
                            hasPairingFile = false
                        } label: {
                            Label(L10n.t(.removePairingFile), systemImage: "trash")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)

                Divider()

                AppLinkRow(title: "StikDebug",
                           detail: L10n.ui(.stikDebugDetail),
                           systemImage: "wrench.and.screwdriver",
                           actionTitle: L10n.ui(.openApp),
                           url: Self.stikDebugURL,
                           fallbackURL: Self.stikDebugSiteURL)
                AppLinkRow(title: "LocalDevVPN",
                           detail: L10n.ui(.localDevVPNDetail),
                           systemImage: "lock.shield",
                           actionTitle: L10n.ui(.appStore),
                           url: TunnelApp.localDevVPN.appStoreURL)

                hint(L10n.t(.ddiSourceFooter), systemImage: "shippingbox")
                hint(L10n.t(.alternativeFooter), systemImage: "arrow.triangle.2.circlepath")
            }
            .padding(.top, 14)
        } label: {
            Label(L10n.ui(.troubleshooting), systemImage: "stethoscope")
                .font(.headline)
                .foregroundColor(.primary)
        }
        .padding(16)
        .card(cornerRadius: 18)
    }

    private func troubleRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(verbatim: value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pieces

    private func stepActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity)
    }

    private func hint(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    // MARK: - State

    /// …and subscribe once for later changes.
    ///
    /// NWPathMonitor resolves asynchronously, so a single read at appear returns
    /// the pre-update default — which reported "not on Wi-Fi" on a device that
    /// plainly was. The observer fires immediately when the path is already
    /// known, and again whenever it changes. Guarded because refreshVPNState
    /// runs on every appear and return-to-foreground; subscribing there would
    /// stack observers that never go away.
    private func subscribeToNetworkOnce() {
        guard !networkObserved else { return }
        networkObserved = true
        NetworkTypeMonitor.shared.observe { type in
            Task { @MainActor in onWiFiChanged(type == .wifi) }
        }
    }

    /// Hop back to the main actor for the @State write.
    @MainActor private func onWiFiChanged(_ connected: Bool) { onWiFi = connected }

    private func refreshVPNState() {
        vpnInstalled = tunnelApp.isInstalled
        // Up means a connection through the tunnel worked — not that some
        // address looks right: another VPN can use the same range, and
        // LocalDevVPN's addresses are configurable. One probe at a time; the
        // timer fires faster than a failing probe returns.
        if !probing {
            probing = true
            Task { @MainActor in
                let result = await LocalDevVPN.probeTunnel()
                tunnelProbe = result
                interfacesSeen = LocalDevVPN.interfaceSummary()
                tunnelUp = result == .reachable
                probing = false
            }
        }
        // Read the current value on every refresh…
        onWiFi = NetworkTypeMonitor.shared.current == .wifi
    }
}

/// One way to complete a step: symbol, title, a line of explanation.
private struct ChoiceCard: View {
    let systemImage: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding(12)
            .background(Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
