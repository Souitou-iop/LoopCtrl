import SwiftUI
import UIKit

// MARK: - Pending request

/// A pairing request waiting for an answer: who, from where, the key to
/// compare with the client's, and how long until it is refused. Allow and
/// Deny settle the same request the runner's notification does, so the card
/// still works after that notification was swiped away or never seen.
struct PairRequestCard: View {
    @EnvironmentObject var admin: RunnerAdmin
    let request: RunnerAdmin.PairRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SourceStyle.badge(request.source, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t(.authRequestTitle))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    Text(verbatim: request.clientName)
                        .font(.headline)
                        .lineLimit(2)
                    Text(verbatim: PairRequestText.origin(request))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                PairCountdown(deadline: request.deadline)
            }

            if let fingerprint = request.fingerprint {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: PairRequestText.groupedFingerprint(fingerprint))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Text(L10n.ui(.pairKeyHint))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Label(L10n.ui(.pairNoKeyHint), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    Task { await admin.respond(to: request, allow: false) }
                } label: {
                    Text(L10n.t(.deny)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await admin.respond(to: request, allow: true) }
                } label: {
                    Text(L10n.t(.allow)).fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .disabled(admin.answering)
        }
        .padding(16)
        .card()
        .accessibilityElement(children: .contain)
    }
}

/// Seconds left before an unanswered request is refused, as a small ring.
struct PairCountdown: View {
    let deadline: Date?
    var total: TimeInterval = AuthManager.approvalTimeout

    var body: some View {
        if let deadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, deadline.timeIntervalSince(context.date))
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(min(1, left / total)))
                        .stroke(left > 10 ? Color.accentColor : Color.orange,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: left)
                    Text(verbatim: "\(Int(left.rounded(.up)))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                .frame(width: 36, height: 36)
                .accessibilityLabel(String(format: L10n.ui(.pairSecondsLeft), Int(left.rounded(.up))))
            }
        }
    }
}

/// Text shared by the card and the list rows.
enum PairRequestText {
    /// "LAN · 192.168.1.20"; this device has no useful address.
    static func origin(_ request: RunnerAdmin.PairRequest) -> String {
        var parts = [SourceStyle.name(request.source)]
        if let address = request.address, request.source != PeerSource.local.rawValue {
            parts.append(address)
        }
        return parts.joined(separator: " · ")
    }

    /// "a1b2 c3d4": easier to compare against the client's output.
    static func groupedFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count == 8 else { return fingerprint }
        return "\(fingerprint.prefix(4)) \(fingerprint.suffix(4))"
    }

    static func outcome(_ request: RunnerAdmin.PairRequest) -> (text: String, tone: StateChip.Tone) {
        if request.autoApproved { return (L10n.ui(.outcomeAllowedOnRetry), .good) }
        switch request.outcome {
        case .pending: return (L10n.ui(.outcomePending), .busy)
        case .allowed: return (L10n.ui(.outcomeAllowed), .good)
        case .denied: return (L10n.ui(.outcomeDenied), .bad)
        case .timedOut: return (L10n.ui(.outcomeTimedOut), .warning)
        }
    }
}

// MARK: - Home screen entry

/// 「已授权 N 个客户端 >」 under the home screen's cards, opening the
/// authorization page; it also says when a missed request can still be allowed.
struct AuthorizationEntryRow: View {
    @EnvironmentObject var admin: RunnerAdmin

    private var allowable: Int { admin.recentRequests.filter(\.canAllow).count }

    var body: some View {
        NavigationLink {
            AuthorizationView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.body.weight(.medium))
                    .foregroundColor(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L10n.ui(.authorizedCount), admin.clients.count))
                        .foregroundColor(.primary)
                    if allowable > 0 {
                        Text(String(format: L10n.ui(.missedRequests), allowable))
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
    }
}

// MARK: - Authorization page

/// Everything about who may control this device: the request waiting now,
/// requests from the last ten minutes (a missed one can be allowed here), and
/// the clients holding a key, with revocation.
struct AuthorizationView: View {
    @EnvironmentObject var admin: RunnerAdmin
    @State private var pendingRevoke: RunnerAdmin.Client?
    @State private var confirmRevokeOthers = false
    @State private var confirmDisconnect = false

    var body: some View {
        List {
            if admin.isPaired {
                if !admin.pendingRequests.isEmpty {
                    Section {
                        ForEach(admin.pendingRequests) { request in
                            PairRequestCard(request: request)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } header: {
                        Text(L10n.ui(.pendingSection))
                    }
                }

                Section {
                    if admin.recentRequests.isEmpty {
                        Text(L10n.ui(.noRecentRequests)).foregroundColor(.secondary)
                    }
                    ForEach(admin.recentRequests) { request in
                        RecentRequestRow(request: request)
                    }
                } header: {
                    Text(L10n.ui(.recentSection))
                } footer: {
                    Text(L10n.ui(.recentFooter))
                }

                Section {
                    if !admin.clientsLoaded && admin.notice == nil {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if admin.clients.isEmpty {
                        Text(L10n.t(.noClients)).foregroundColor(.secondary)
                    }
                    ClientRows(clients: admin.clients,
                               pendingRevoke: $pendingRevoke,
                               confirmDisconnect: $confirmDisconnect,
                               showsGrantTime: true)
                    if let notice = admin.notice {
                        NoticeLabel(text: notice)
                    }
                } header: {
                    Text(L10n.t(.authorizedClients))
                } footer: {
                    Text(L10n.t(.clientsFooter))
                }

                Section {
                    if !admin.otherClients.isEmpty {
                        Button(role: .destructive) { confirmRevokeOthers = true } label: {
                            Label(admin.ownSessionID == nil ? L10n.ui(.revokeAll) : L10n.t(.revokeOthers),
                                  systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                    if admin.ownSessionID != nil {
                        Button(role: .destructive) { confirmDisconnect = true } label: {
                            Label(L10n.t(.disconnectThisApp), systemImage: "personalhotspot.slash")
                        }
                    }
                }
            } else {
                Section { RunnerConnectRows() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.ui(.authorizationTitle))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await admin.loadClients() }
        .animation(.default, value: admin.pendingRequests)
        .animation(.default, value: admin.recentRequests)
        .animation(.default, value: admin.clients)
        .clientConfirmations(admin: admin,
                             pendingRevoke: $pendingRevoke,
                             confirmRevokeOthers: $confirmRevokeOthers,
                             confirmDisconnect: $confirmDisconnect)
        .pairingRequestPolling(admin: admin)
    }
}

/// One finished request: who, from where, what became of it, and — while it
/// still can — the button that lets the client in on its next try.
struct RecentRequestRow: View {
    @EnvironmentObject var admin: RunnerAdmin
    let request: RunnerAdmin.PairRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SourceStyle.badge(request.source)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: request.clientName).lineLimit(1)
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                let outcome = PairRequestText.outcome(request)
                StateChip(text: outcome.text, tone: outcome.tone)
            }
            grantLine
        }
        .padding(.vertical, 2)
    }

    /// "LAN · 192.168.1.20 · a1b2 c3d4 · 3 min ago"
    private var subtitle: String {
        var parts = [PairRequestText.origin(request)]
        if let fp = request.fingerprint { parts.append(PairRequestText.groupedFingerprint(fp)) }
        if let at = request.resolvedAt ?? request.requestedAt {
            let now = Date()
            parts.append(ClientRow.relative.localizedString(for: min(at, now), relativeTo: now))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var grantLine: some View {
        switch request.grant {
        case .armed(let until):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(until.timeIntervalSince(context.date)))
                Label(String(format: L10n.ui(.grantArmed), String(format: "%d:%02d", left / 60, left % 60)),
                      systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundColor(.accentColor)
            }
        case .used:
            Label(L10n.ui(.grantUsed), systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundColor(.green)
        case .none:
            if request.canAllow {
                Button {
                    Task { await admin.allowAfterTheFact(request) }
                } label: {
                    Label(L10n.ui(.allowThisClient), systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(admin.answering)
            } else if request.fingerprint == nil, request.outcome != .allowed {
                Text(L10n.ui(.noKeyCannotAllow))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Polling

extension View {
    /// Keep the runner's pending and recent requests current while shown:
    /// in-process, as soon as the runner says they changed; over /rpc, every
    /// few seconds.
    func pairingRequestPolling(admin: RunnerAdmin, active: Bool = true) -> some View {
        modifier(PairingRequestPolling(admin: admin, active: active))
    }
}

private struct PairingRequestPolling: ViewModifier {
    @ObservedObject var admin: RunnerAdmin
    let active: Bool

    #if LOOPCTRL_ALL_IN_ONE
    private static let interval: UInt64 = 2_000_000_000
    #else
    private static let interval: UInt64 = 3_000_000_000
    #endif

    func body(content: Content) -> some View {
        content
            .task(id: active && admin.isPaired) {
                guard active && admin.isPaired else { return }
                while !Task.isCancelled {
                    await admin.loadClients()
                    try? await Task.sleep(nanoseconds: Self.interval)
                }
            }
            #if LOOPCTRL_ALL_IN_ONE
            // The runner shares this process: AuthManager says when a request
            // arrives or is settled, so the card shows at once.
            .onReceive(NotificationCenter.default.publisher(for: AuthManager.pairingRequestsDidChange)
                        .receive(on: DispatchQueue.main)) { _ in
                guard active else { return }
                Task { await admin.loadClients() }
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in
                guard active && admin.isPaired else { return }
                Task { await admin.loadClients() }
            }
    }
}
