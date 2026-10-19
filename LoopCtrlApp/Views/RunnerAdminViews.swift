import SwiftUI
import UIKit

// MARK: - Connecting

/// List rows shown in place of runner data until this app holds a key: what
/// the one-time approval is for, and the button that asks for it.
struct RunnerConnectRows: View {
    @EnvironmentObject var admin: RunnerAdmin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(L10n.t(.connectRunnerBody))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "person.badge.key")
                    .foregroundColor(.accentColor)
            }
            Button {
                Task { await admin.connect() }
            } label: {
                if admin.pairing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t(.waitingApproval))
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label(L10n.t(.connectButton), systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(admin.pairing)
            if let notice = admin.notice {
                NoticeLabel(text: notice)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Clients

/// One client holding a key: where it last came from, how recently, and —
/// in its context menu — when it was paired and its session id.
struct ClientRow: View {
    let client: RunnerAdmin.Client
    let isSelf: Bool

    /// The app ships no .lproj, so Foundation formats in English by default;
    /// follow the language the rest of the UI is shown in instead.
    private static let locale: Locale = {
        switch L10n.lang {
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .zhHant: return Locale(identifier: "zh-Hant")
        default: return Locale.current
        }
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        f.locale = locale
        return f
    }()

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.sourceIcon(client.lastVia))
                .font(.body.weight(.medium))
                .foregroundColor(Self.sourceColor(client.lastVia))
                .frame(width: 36, height: 36)
                .background(Self.sourceColor(client.lastVia).opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(client.name)
                        .lineLimit(1)
                    if isSelf {
                        Text(L10n.t(.thisApp))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundColor(.accentColor)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "LAN · 192.168.1.20 · 2 min ago". Loopback says nothing useful
    /// ("127.0.0.1"); the source does.
    private var subtitle: String {
        var parts = [String]()
        if let via = client.lastVia {
            parts.append(Self.sourceName(via))
            if let address = client.lastAddress, via != PeerSource.local.rawValue {
                parts.append(address)
            }
        }
        if let active = client.lastActiveAt {
            // Clamp: the runner's clock reading can be a moment ahead of ours.
            let now = Date()
            parts.append(Self.relative.localizedString(for: min(active, now), relativeTo: now))
        } else if let granted = client.grantedAt {
            parts.append(String(format: L10n.t(.pairedAt), Self.absolute.string(from: granted)))
        }
        return parts.isEmpty ? client.id : parts.joined(separator: " · ")
    }

    /// Details that don't fit the row, as context-menu entries.
    @ViewBuilder var details: some View {
        if let granted = client.grantedAt {
            Text(String(format: L10n.t(.pairedAt), Self.absolute.string(from: granted)))
        }
        if let active = client.lastActiveAt {
            let now = Date()
            Text(String(format: L10n.t(.lastActive),
                        Self.relative.localizedString(for: min(active, now), relativeTo: now)))
        }
        if let address = client.lastAddress {
            Button {
                UIPasteboard.general.string = address
            } label: {
                Label(address, systemImage: "doc.on.doc")
            }
        }
        Button {
            UIPasteboard.general.string = client.id
        } label: {
            Label(client.id, systemImage: "number")
        }
    }

    private static func sourceName(_ via: String) -> String {
        switch PeerSource(rawValue: via) {
        case .local: return L10n.t(.viaLocal)
        case .lan: return L10n.t(.viaLAN)
        case .nearby: return L10n.t(.viaNearby)
        case .vpn: return L10n.t(.viaVPN)
        case .tailnet: return L10n.t(.viaTailnet)
        case .cellular: return L10n.t(.viaCellular)
        case .other, nil: return L10n.t(.viaOther)
        }
    }

    private static func sourceIcon(_ via: String?) -> String {
        switch via.flatMap(PeerSource.init(rawValue:)) {
        case .local: return "iphone"
        case .lan: return "wifi"
        case .nearby: return "dot.radiowaves.left.and.right"
        case .vpn: return "lock.shield"
        case .tailnet: return "point.3.connected.trianglepath.dotted"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .other, nil: return "network"
        }
    }

    private static func sourceColor(_ via: String?) -> Color {
        switch via.flatMap(PeerSource.init(rawValue:)) {
        case .lan: return .blue
        case .nearby: return .purple
        case .vpn: return .orange
        case .tailnet: return .teal
        case .cellular: return .green
        default: return .gray
        }
    }
}

/// The client rows, with swipe and context-menu actions, shared by the
/// Settings sheet and the full clients screen. Revoking another client and
/// disconnecting this app both go through the confirmations of
/// `clientConfirmations`.
struct ClientRows: View {
    @EnvironmentObject var admin: RunnerAdmin
    let clients: [RunnerAdmin.Client]
    @Binding var pendingRevoke: RunnerAdmin.Client?
    @Binding var confirmDisconnect: Bool

    var body: some View {
        ForEach(clients) { client in
            let isSelf = client.id == admin.ownSessionID
            let row = ClientRow(client: client, isSelf: isSelf)
            row
                .swipeActions {
                    if isSelf {
                        Button(L10n.t(.disconnectThisApp)) { confirmDisconnect = true }
                            .tint(.gray)
                    } else {
                        Button(L10n.t(.revokeButton), role: .destructive) { pendingRevoke = client }
                    }
                }
                .contextMenu {
                    Section { row.details }
                    if isSelf {
                        Button(role: .destructive) { confirmDisconnect = true } label: {
                            Label(L10n.t(.disconnectThisApp), systemImage: "personalhotspot.slash")
                        }
                    } else {
                        Button(role: .destructive) { pendingRevoke = client } label: {
                            Label(L10n.t(.revokeButton), systemImage: "xmark.circle")
                        }
                    }
                }
        }
    }
}

extension View {
    /// The confirmations behind revoking one client, every other client, or
    /// this app's own key.
    ///
    /// Alerts, not confirmation dialogs: newer iOS draws a dialog as a
    /// popover pointing at its anchor, which from a list points at the wrong
    /// row — and one attached to a row is not shown after a swipe.
    func clientConfirmations(admin: RunnerAdmin,
                             pendingRevoke: Binding<RunnerAdmin.Client?>,
                             confirmRevokeOthers: Binding<Bool>,
                             confirmDisconnect: Binding<Bool>) -> some View {
        self
            .alert(String(format: L10n.t(.revokeConfirmTitle), pendingRevoke.wrappedValue?.name ?? ""),
                   isPresented: Binding(get: { pendingRevoke.wrappedValue != nil },
                                        set: { if !$0 { pendingRevoke.wrappedValue = nil } }),
                   presenting: pendingRevoke.wrappedValue) { client in
                Button(L10n.t(.cancelButton), role: .cancel) {}
                Button(L10n.t(.revokeButton), role: .destructive) {
                    Task { await admin.revoke(client.id) }
                }
            } message: { _ in
                Text(L10n.t(.revokeConfirmBody))
            }
            .alert(String(format: L10n.t(.revokeOthersConfirm), admin.otherClients.count),
                   isPresented: confirmRevokeOthers) {
                Button(L10n.t(.cancelButton), role: .cancel) {}
                Button(L10n.t(.revokeOthers), role: .destructive) {
                    Task { await admin.revokeOthers() }
                }
            } message: {
                Text(L10n.t(.revokeConfirmBody))
            }
            .alert(L10n.t(.disconnectThisApp), isPresented: confirmDisconnect) {
                Button(L10n.t(.cancelButton), role: .cancel) {}
                Button(L10n.t(.disconnectThisApp), role: .destructive) {
                    Task { await admin.disconnect() }
                }
            } message: {
                Text(L10n.t(.disconnectConfirmBody))
            }
    }
}

/// Every client holding a key to the runner, with revocation.
struct RunnerClientsView: View {
    @EnvironmentObject var admin: RunnerAdmin
    @State private var pendingRevoke: RunnerAdmin.Client?
    @State private var confirmRevokeOthers = false
    @State private var confirmDisconnect = false

    var body: some View {
        List {
            if admin.isPaired {
                Section {
                    if !admin.clientsLoaded && admin.notice == nil {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if admin.clients.isEmpty {
                        Text(L10n.t(.noClients)).foregroundColor(.secondary)
                    }
                    ClientRows(clients: admin.clients,
                               pendingRevoke: $pendingRevoke,
                               confirmDisconnect: $confirmDisconnect)
                    if let notice = admin.notice {
                        NoticeLabel(text: notice)
                    }
                } footer: {
                    Text(L10n.t(.clientsFooter))
                }

                Section {
                    if !admin.otherClients.isEmpty {
                        Button(role: .destructive) { confirmRevokeOthers = true } label: {
                            Label(L10n.t(.revokeOthers), systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                    Button(role: .destructive) { confirmDisconnect = true } label: {
                        Label(L10n.t(.disconnectThisApp), systemImage: "personalhotspot.slash")
                    }
                }
            } else {
                Section { RunnerConnectRows() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t(.authorizedClients))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await admin.loadClients() }
        .clientConfirmations(admin: admin,
                             pendingRevoke: $pendingRevoke,
                             confirmRevokeOthers: $confirmRevokeOthers,
                             confirmDisconnect: $confirmDisconnect)
        // A new client can pair while this screen is open; keep it current.
        .task(id: admin.isPaired) {
            while !Task.isCancelled && admin.isPaired {
                await admin.loadClients()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}

// MARK: - Log console

/// Log lines in a monospaced console: filterable, following the newest line
/// while `follow` is on, with warnings and errors tinted.
struct LogConsole: View {
    let lines: [String]
    let loading: Bool
    var follow = true
    @Binding var filter: String

    private var shown: [String] {
        filter.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        let shown = shown
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        Group {
                            if loading {
                                ProgressView()
                            } else {
                                Label(filter.isEmpty ? L10n.t(.noLogLines) : L10n.ui(.noMatches),
                                      systemImage: filter.isEmpty ? "text.alignleft" : "magnifyingglass")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                        Text(verbatim: line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Self.tint(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 3)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color(.secondarySystemBackground).opacity(0.6))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
            .searchable(text: $filter, prompt: L10n.t(.filterPlaceholder))
            .onChange(of: lines) { _ in
                // Follow the newest line while live; a paused log stays where
                // the reader left it.
                guard follow, filter.isEmpty else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private static func tint(for line: String) -> Color {
        let lower = line.lowercased()
        if line.contains("🔴") || lower.contains("error") || lower.contains("failed") { return .red }
        if line.contains("⚠️") || lower.contains("warning") { return .orange }
        return .primary
    }
}

/// `sheet(item:)` wants Identifiable.
struct ShareText: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Runner log

/// The runner's recent log, pulled every 2 seconds while on screen.
struct RunnerLogsView: View {
    @EnvironmentObject var admin: RunnerAdmin
    @State private var live = true
    @State private var filter = ""
    @State private var refreshing = false
    @State private var shareItem: ShareText?

    private static let pollInterval: UInt64 = 2_000_000_000

    private var shownLines: [String] {
        filter.isEmpty ? admin.logLines : admin.logLines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        Group {
            if admin.isPaired {
                LogConsole(lines: admin.logLines,
                           loading: !admin.logsLoaded && admin.notice == nil,
                           follow: live,
                           filter: $filter)
                    .refreshable { await refresh() }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let notice = admin.notice {
                            NoticeLabel(text: notice)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.bar)
                        }
                    }
            } else {
                List { Section { RunnerConnectRows() } }
                    .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(L10n.t(.runnerLogs))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if admin.isPaired {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        live.toggle()
                    } label: {
                        StateChip(text: live ? L10n.t(.liveLabel) : L10n.t(.pausedLabel),
                                  tone: live ? .good : .idle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(live ? L10n.t(.pausedLabel) : L10n.t(.liveLabel))
                    Menu {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label(L10n.ui(.refresh), systemImage: "arrow.clockwise")
                        }
                        .disabled(refreshing)
                        Button {
                            UIPasteboard.general.string = shownLines.joined(separator: "\n")
                        } label: {
                            Label(L10n.t(.copyButton), systemImage: "doc.on.doc")
                        }
                        Button {
                            shareItem = ShareText(text: shownLines.joined(separator: "\n"))
                        } label: {
                            Label(L10n.ui(.share), systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.text]) }
        // Pull on entry, then keep pulling while the screen is visible. `.task`
        // is cancelled when the view goes away, which ends the polling.
        .task(id: admin.isPaired) {
            guard admin.isPaired else { return }
            await admin.loadLogs()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                if live && !Task.isCancelled { await admin.loadLogs() }
            }
        }
    }

    private func refresh() async {
        refreshing = true
        await admin.loadLogs()
        refreshing = false
    }
}
