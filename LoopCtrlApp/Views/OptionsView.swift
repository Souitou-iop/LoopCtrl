import SwiftUI
import UIKit

/// Everything that isn't the one thing the home screen does, in one sheet:
/// pairing and the disk image (with the tunnel choice inside that flow), the
/// running server's details and clients, this device, and the logs.
struct OptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runnerAdmin: RunnerAdmin
    @ObservedObject var runner: RunnerStatus

    @State private var ddi = DeveloperDiskImage.status()
    @State private var hasPairingFile = PairingFileStore.exists
    @State private var showMountSheet = false
    @State private var logCount = AppLog.allFiles().count
    @State private var portText = String(ServerPort.stored)

    /// Provides the local loopback tunnel the mount needs to reach lockdownd.
    /// An App Store link: LocalDevVPN registers no URL scheme of its own.
    private static let localDevVPNURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!
    /// StikDebug mounts the DDI on-device; bare scheme just opens the app.
    private static let stikDebugURL = URL(string: "stikdebug://")!
    /// Sideload-only, so the fallback is its distribution site.
    private static let stikDebugSiteURL = URL(string: "https://stikdebug.xyz")!

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        NavigationStack {
            List {
                setupSection
                portSection

                if case .running(let info) = runner.state {
                    serverSection(info)
                }

                // Fallback only: the in-app mount does the same job without
                // leaving LoopCtrl.
                if !ddi.isMounted {
                    alternativeSection
                }

                deviceSection
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
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: PairingFileStore.didImport)) { _ in refresh() }
            .sheet(isPresented: $showMountSheet, onDismiss: refresh) {
                DDIMountView()
            }
        }
    }

    private func refresh() {
        ddi = DeveloperDiskImage.status()
        hasPairingFile = PairingFileStore.exists
        logCount = AppLog.allFiles().count
    }

    // MARK: - Sections

    private var portIsValid: Bool {
        Int(portText).map(ServerPort.allowed.contains) ?? false
    }

    /// The server's port. Saved as soon as it is valid; the runner picks it up
    /// on the next start, so it can't change while the service is running.
    private var portSection: some View {
        Section {
            HStack {
                Text(L10n.ui(.portLabel))
                Spacer()
                TextField(String(ServerPort.defaultPort), text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(portIsValid ? .primary : .orange)
                    .frame(maxWidth: 120)
                    .disabled(runner.isRunning)
                    .onChange(of: portText) { text in
                        let digits = String(text.filter(\.isNumber).prefix(5))
                        if digits != text { portText = digits; return }
                        if let value = Int(digits), ServerPort.allowed.contains(value) {
                            appState.serverPort = value
                        }
                    }
            }
            if portText != String(ServerPort.defaultPort) && !runner.isRunning {
                Button(L10n.ui(.portReset)) {
                    portText = String(ServerPort.defaultPort)
                }
            }
        } footer: {
            if runner.isRunning {
                Text(L10n.ui(.portRunningFooter))
            } else if !portIsValid {
                Text(String(format: L10n.ui(.portInvalid),
                            ServerPort.allowed.lowerBound, ServerPort.allowed.upperBound))
                    .foregroundColor(.orange)
            } else {
                Text(String(format: L10n.ui(.portFooter), Int(ServerPort.defaultPort)))
            }
        }
    }

    /// Pairing, image download, Wi-Fi, tunnel app and the mount all live in
    /// DDIMountView; here it is one row that says where things stand.
    private var setupSection: some View {
        Section {
            Button {
                showMountSheet = true
            } label: {
                HStack {
                    Text(L10n.ui(.setupRow)).foregroundColor(.primary)
                    Spacer()
                    Text(ddi.isMounted ? L10n.ui(.mounted)
                         : hasPairingFile ? L10n.ui(.paired) : ddi.localizedSummary)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
            }
            if let layout = ddi.layout {
                LabeledRow(L10n.t(.mountPoint), layout.rawValue)
            }
        } footer: {
            if ddi.isMounted {
                Text(L10n.t(.ddiReadyFooter))
            } else if let advice = ddi.advice {
                Text(advice)
            }
        }
    }

    private func serverSection(_ info: RunnerStatus.Info) -> some View {
        Section {
            LabeledRow(L10n.t(.addressLabel), "127.0.0.1:\(appState.serverPort)")
            if let version = info.serverVersion {
                LabeledRow(L10n.t(.serverLabel), version)
            }
            if let proto = info.protocolVersion {
                LabeledRow(L10n.t(.protocolLabel), "v\(proto)")
            }
            if let methods = info.methodCount {
                LabeledRow(L10n.t(.methodsLabel), "\(methods)", monospaced: false)
            }
            if !info.capabilities.isEmpty {
                NavigationLink {
                    CapabilityListView(capabilities: info.capabilities)
                } label: {
                    LabeledRow(L10n.t(.capabilitiesLabel), "\(info.capabilities.count)", monospaced: false)
                }
            }
            if let visibility = runnerAdmin.visibility {
                RunnerVisibilityRow(visibility: visibility)
            }
            if runnerAdmin.localNetworkDenied {
                // Remote clients connecting in still work without it, so this
                // is the only sign of why nearby discovery cannot.
                Text(L10n.t(.runnerLocalNetworkDenied))
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            NavigationLink {
                RunnerClientsView()
            } label: {
                HStack {
                    Text(L10n.t(.authorizedClients))
                    Spacer()
                    if runnerAdmin.clientsLoaded {
                        Text(verbatim: "\(runnerAdmin.clients.count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            // Count and visibility kept current while shown (remote access and
            // nearby can be switched from the runner's notification at any
            // time). Only once paired: pairing is never started from here.
            .task(id: runnerAdmin.isPaired) {
                while !Task.isCancelled && runnerAdmin.isPaired {
                    await runnerAdmin.loadClients()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            NavigationLink {
                RunnerLogsView()
            } label: {
                Text(L10n.t(.runnerLogs))
            }
        } header: {
            Text(L10n.t(.serverSectionTitle))
        } footer: {
            Text(L10n.t(.serverRunningFooter))
        }
    }

    private var alternativeSection: some View {
        Section {
            LinkRow(title: "LocalDevVPN",
                    detail: "Required either way — it makes this device's debug service reachable.",
                    actionTitle: "App Store",
                    url: Self.localDevVPNURL)
            LinkRow(title: "StikDebug",
                    detail: "An alternative mounter, if the in-app one fails. Sideload from stikdebug.xyz — it isn't on the App Store.",
                    actionTitle: "Open",
                    url: Self.stikDebugURL,
                    fallbackURL: Self.stikDebugSiteURL)
        } header: {
            Text(L10n.t(.alternativeSection))
        } footer: {
            Text(L10n.t(.alternativeFooter))
        }
    }

    /// Read locally, not from the server: most useful precisely when the
    /// runner won't start.
    private var deviceSection: some View {
        Section {
            LabeledRow(L10n.t(.modelLabel), DeviceInfo.modelIdentifier)
            LabeledRow(L10n.t(.systemLabel), "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            LabeledRow(L10n.t(.screenLabel), DeviceInfo.screenDescription)
            LabeledRow(L10n.t(.nameLabel), UIDevice.current.name, monospaced: false)
        } header: {
            Text(L10n.t(.deviceSection))
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledRow(L10n.t(.versionLabel), Self.appVersion, monospaced: false)
            LabeledRow(L10n.t(.protocolLabel), "JSON-RPC 2.0", monospaced: false)
            NavigationLink {
                LogListView()
            } label: {
                LabeledRow(L10n.t(.logsLabel), "\(logCount)", monospaced: false)
            }
        } header: {
            Text(L10n.t(.aboutSection))
        } footer: {
            // The mount runs through a Rust FFI that aborts rather than throws,
            // so the log is often the only artifact besides a crash report.
            Text(L10n.t(.logsFooter))
        }
    }
}

/// Another app worth having: name, why, and a button that opens it.
private struct LinkRow: View {
    let title: String
    let detail: String
    let actionTitle: String
    let url: URL
    /// Opened when `url` uses a custom scheme and the app isn't installed.
    var fallbackURL: URL? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(actionTitle) {
                UIApplication.shared.open(url) { ok in
                    // A custom-scheme open fails when that app isn't installed;
                    // its download page turns a dead tap into a way forward.
                    guard !ok, let fallbackURL else { return }
                    UIApplication.shared.open(fallbackURL)
                }
            }
            .font(.subheadline.weight(.semibold))
            // .borderless keeps the tap on the button, not the whole row.
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

/// The capability tags the running server advertises, as a flat list: clients
/// feature-detect against them, so "is X there" is the useful question.
private struct CapabilityListView: View {
    let capabilities: [String]

    var body: some View {
        List(capabilities.sorted(), id: \.self) { tag in
            Text(verbatim: tag)
                .font(.system(.body, design: .monospaced))
        }
        .navigationTitle(L10n.t(.capabilitiesLabel))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A label with its value right-aligned.
private struct LabeledRow: View {
    let label: String
    let value: String
    var monospaced = true

    init(_ label: String, _ value: String, monospaced: Bool = true) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(verbatim: value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
