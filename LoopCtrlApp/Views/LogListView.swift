import SwiftUI
import UIKit

/// Every log this app has written, one per run, newest first.
///
/// Exists so a failure that happened on a device with no debugger can leave with
/// the user: tap a run, read it, share it. The per-PID split is what makes that
/// useful — the run that crashed is still its own file after the relaunch.
/// The runner's own log is read live over its RPC instead (RunnerLogsView).
struct LogListView: View {
    @State private var files = AppLog.allFiles()
    @State private var shareURL: ShareItem?
    @State private var confirmClear = false

    /// `sheet(item:)` wants Identifiable, and URL isn't.
    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        List {
            Section {
                if files.isEmpty {
                    Label(L10n.ui(.noLogsYet), systemImage: "doc.text")
                        .foregroundColor(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    NavigationLink {
                        LogDetailView(url: url)
                    } label: {
                        row(url)
                    }
                    .swipeActions {
                        Button(L10n.ui(.share)) { shareURL = ShareItem(url: url) }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            shareURL = ShareItem(url: url)
                        } label: {
                            Label(L10n.ui(.share), systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } footer: {
                // The mount runs through a Rust FFI that aborts rather than
                // throws, so the log is often the only artifact besides a
                // crash report.
                Text(L10n.t(.logsFooter))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.ui(.appLogs))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if let current = AppLog.shared.fileURL {
                        Button {
                            shareURL = ShareItem(url: current)
                        } label: {
                            Label(L10n.ui(.shareCurrentLog), systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label(L10n.ui(.deleteAllLogs), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(L10n.ui(.deleteAllLogsConfirm), isPresented: $confirmClear) {
            Button(L10n.t(.cancelButton), role: .cancel) {}
            Button(L10n.ui(.deleteAll), role: .destructive) {
                AppLog.removeAll()
                files = AppLog.allFiles()
            }
        } message: {
            Text(L10n.ui(.deleteAllLogsBody))
        }
        .sheet(item: $shareURL) { item in
            ShareSheet(items: [item.url])
        }
        .onAppear { files = AppLog.allFiles() }
    }

    private func row(_ url: URL) -> some View {
        let isCurrent = url == AppLog.shared.fileURL
        return HStack(spacing: 12) {
            Image(systemName: isCurrent ? "doc.text.fill" : "doc.text")
                .font(.body.weight(.medium))
                .foregroundColor(isCurrent ? .accentColor : .secondary)
                .frame(width: 36, height: 36)
                .background((isCurrent ? Color.accentColor : Color.gray).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.title(for: url))
                    if isCurrent {
                        Text(L10n.ui(.currentRun))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundColor(.accentColor)
                    }
                }
                Text(Self.subtitle(for: url))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// "Aug 15, 1:42 PM" — when the run happened, which is how you'd look for it.
    private static func title(for url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        guard let date else { return url.lastPathComponent }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func subtitle(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let pid = url.lastPathComponent
            .split(separator: "-").last?
            .replacingOccurrences(of: ".log", with: "") ?? ""
        return "PID \(pid) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }
}

/// One log's contents, as a console: monospaced lines, filter, share.
private struct LogDetailView: View {
    let url: URL
    @State private var lines: [String] = []
    @State private var loaded = false
    @State private var filter = ""
    @State private var showShare = false

    var body: some View {
        LogConsole(lines: lines, loading: !loaded, follow: false, filter: $filter)
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showShare = true
                        } label: {
                            Label(L10n.ui(.share), systemImage: "square.and.arrow.up")
                        }
                        Button {
                            let shown = filter.isEmpty ? lines
                                : lines.filter { $0.localizedCaseInsensitiveContains(filter) }
                            UIPasteboard.general.string = shown.joined(separator: "\n")
                        } label: {
                            Label(L10n.t(.copyButton), systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
            .onAppear {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? L10n.ui(.unreadable)
                lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if lines.last?.isEmpty == true { lines.removeLast() }
                loaded = true
            }
    }
}

/// The system share sheet. Shares the file URL rather than its text, so the
/// receiving app gets a real .log attachment instead of a wall of pasted lines.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
