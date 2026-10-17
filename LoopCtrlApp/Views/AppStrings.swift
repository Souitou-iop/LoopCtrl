import Foundation

/// Host-app strings added with the simplified home screen.
///
/// Same approach as `L10n.t` (an in-code table keyed by `L10n.lang`, English
/// fallback, English + Chinese filled in for host UI), kept on the app side so
/// the shared table in LoopCtrlUITests/Localized.swift — which the runner also
/// compiles — is not touched for strings only this app shows.
extension L10n {
    enum UI {
        case settingsTitle
        case pairingLabel, paired, notPaired
        case diskImageLabel, mounted, notMounted, unavailable
        case serviceLabel
        case mountDiskImage, setupRow
        case runnerOpenFailed, runnerStartFailed
        case localAddress, lanAddress, noWiFi, copied
        case remoteAccess, remoteAccessOnFooter, remoteAccessOffFooter, remoteAccessApproveFooter
        case portLabel, portFooter, portRunningFooter, portInvalid, portReset, portApply
        // Settings sheet
        case connectionSection, setupSection, clientsSection, diagnosticsSection
        case visibilityThisDevice, visibilityLAN, visibilityNearby
        case visibilityNearbyFooter, visibilityNearbyPendingFooter, visibilityStoppedFooter
        case stepsDone, diskImageMounted
        case clientsNeedService, clientsSwipeFooter, showAllClients
        case appLogs, serviceInfo, serviceStoppedInfo, license
        // Pairing & Disk Image
        case stepsLeft, oneStepLeft, mounting
        case stepPairing, stepTunnel, stepMount
        case pairingInProgress, pairOnThisIPhone, pairAgainOnDevice
        case importPairingFileShort, replacePairingFileShort, importPairingDetail
        case downloading, notDownloaded
        case tunnelConnected, tunnelNotConnected, tunnelNotInstalled, tunnelLocalNetworkDenied, tunnelNotDevice
        case phaseConnecting, phaseQuerying, phaseFinalizing
        case troubleshooting, remount, stikDebugDetail, localDevVPNDetail, openApp, appStore
        // Logs
        case noLogsYet, noMatches, currentRun, share, shareCurrentLog, refresh, unreadable
        case deleteAllLogs, deleteAllLogsConfirm, deleteAllLogsBody, deleteAll
    }

    static func ui(_ key: UI) -> String {
        let row = uiTable[key] ?? [:]
        return row[lang] ?? row[.en] ?? ""
    }

    private static let uiTable: [UI: [Lang: String]] = [
        .settingsTitle: [.en: "Settings", .zhHans: "设置", .zhHant: "設定"],
        .localAddress: [.en: "This device", .zhHans: "本机", .zhHant: "本機"],
        .lanAddress: [.en: "Wi-Fi", .zhHans: "局域网", .zhHant: "區域網路"],
        .noWiFi: [.en: "Not on Wi-Fi", .zhHans: "未连接 Wi-Fi", .zhHant: "未連接 Wi-Fi"],
        .copied: [.en: "Copied", .zhHans: "已复制", .zhHant: "已複製"],
        .portLabel: [.en: "Port", .zhHans: "端口", .zhHant: "連接埠"],
        .portFooter: [.en: "The port automation clients connect to. Default %d. Don't share it with another automation app such as iCTRL.",
                      .zhHans: "自动化客户端连接的端口，默认 %d。不要和 iCTRL 等其他自动化 App 使用同一个端口。",
                      .zhHant: "自動化用戶端連線的連接埠，預設 %d。不要和 iCTRL 等其他自動化 App 使用同一個連接埠。"],
        .portRunningFooter: [.en: "The service restarts on the new port; connected clients reconnect to the new address.",
                             .zhHans: "服务会在新端口上重启，已连接的客户端需要改用新地址重新连接。",
                             .zhHant: "服務會在新連接埠上重新啟動，已連線的用戶端需要改用新位址重新連線。"],
        .portInvalid: [.en: "Use a port from %d to %d.",
                       .zhHans: "端口需在 %d 到 %d 之间。",
                       .zhHant: "連接埠需在 %d 到 %d 之間。"],
        .portReset: [.en: "Restore Default", .zhHans: "恢复默认", .zhHant: "恢復預設"],
        .portApply: [.en: "Move Service to Port %@", .zhHans: "将服务切换到端口 %@", .zhHant: "將服務切換到連接埠 %@"],
        .remoteAccess: [.en: "Remote Access", .zhHans: "远程访问", .zhHant: "遠端存取"],
        .remoteAccessOnFooter: [.en: "Devices on the same Wi-Fi can reach the address above; each one still has to be approved before it can pair.",
                                .zhHans: "同一 Wi-Fi 下的设备可以访问上面的地址，每台设备仍需你批准才能配对。",
                                .zhHant: "同一 Wi-Fi 下的裝置可以存取上面的位址，每台裝置仍需你批准才能配對。"],
        .remoteAccessOffFooter: [.en: "Only apps on this iPhone can connect.",
                                 .zhHans: "只有这台 iPhone 上的 App 可以连接。",
                                 .zhHant: "只有這台 iPhone 上的 App 可以連線。"],
        .remoteAccessApproveFooter: [.en: "The first time, allow LoopCtrl in the prompt that appears so it can change this setting.",
                                     .zhHans: "首次使用时，请在弹出的提示中允许 LoopCtrl，才能更改此设置。",
                                     .zhHant: "首次使用時，請在跳出的提示中允許 LoopCtrl，才能變更此設定。"],
        .pairingLabel: [.en: "Pairing", .zhHans: "配对", .zhHant: "配對"],
        .paired: [.en: "Paired", .zhHans: "已配对", .zhHant: "已配對"],
        .notPaired: [.en: "Not paired", .zhHans: "未配对", .zhHant: "未配對"],
        .diskImageLabel: [.en: "Disk Image", .zhHans: "磁盘镜像", .zhHant: "磁碟映像"],
        .mounted: [.en: "Mounted", .zhHans: "已挂载", .zhHant: "已掛載"],
        .notMounted: [.en: "Not mounted", .zhHans: "未挂载", .zhHant: "未掛載"],
        .unavailable: [.en: "Unavailable", .zhHans: "不可用", .zhHant: "無法使用"],
        .serviceLabel: [.en: "Service", .zhHans: "服务", .zhHant: "服務"],
        .mountDiskImage: [.en: "Mount Disk Image", .zhHans: "挂载磁盘镜像", .zhHant: "掛載磁碟映像"],
        .setupRow: [.en: "Pairing & Disk Image", .zhHans: "配对与磁盘镜像", .zhHant: "配對與磁碟映像"],
        .runnerOpenFailed: [.en: "Couldn't open the runner. Install LoopCtrlUITests-Runner with SideStore (or your own signing), then try again.",
                            .zhHans: "无法打开 runner。请用 SideStore（或自己的签名）安装 LoopCtrlUITests-Runner 后重试。",
                            .zhHant: "無法開啟 runner。請用 SideStore（或自己的簽名）安裝 LoopCtrlUITests-Runner 後重試。"],
        .runnerStartFailed: [.en: "Couldn't start the runner. Logs in Settings have the details.",
                             .zhHans: "无法启动 runner，详情见设置中的日志。",
                             .zhHant: "無法啟動 runner，詳情見設定中的日誌。"],

        // Settings sheet
        .connectionSection: [.en: "Connection", .zhHans: "连接", .zhHant: "連線"],
        .setupSection: [.en: "Setup", .zhHans: "准备", .zhHant: "準備"],
        .clientsSection: [.en: "Clients", .zhHans: "客户端", .zhHant: "用戶端"],
        .diagnosticsSection: [.en: "Diagnostics", .zhHans: "诊断", .zhHant: "診斷"],
        .visibilityThisDevice: [.en: "This device", .zhHans: "仅本机", .zhHant: "僅本機"],
        .visibilityLAN: [.en: "LAN", .zhHans: "局域网", .zhHant: "區域網路"],
        .visibilityNearby: [.en: "LAN + Nearby", .zhHans: "局域网 + 近场", .zhHant: "區域網路 + 近場"],
        .visibilityNearbyFooter: [.en: "Devices on the same Wi-Fi can reach the address above, and nearby Apple devices can find this iPhone over AWDL. Each one still has to be approved before it can pair.",
                                  .zhHans: "同一 Wi-Fi 下的设备可以访问上面的地址，附近的 Apple 设备也能通过 AWDL 发现这台 iPhone。每台设备仍需你批准才能配对。",
                                  .zhHant: "同一 Wi-Fi 下的裝置可以存取上面的位址，附近的 Apple 裝置也能透過 AWDL 找到這台 iPhone。每台裝置仍需你批准才能配對。"],
        .visibilityNearbyPendingFooter: [.en: "Nearby discovery is on but not advertising yet: it waits for Wi-Fi and Local Network access.",
                                         .zhHans: "近场发现已开启但尚未广播：正在等待 Wi-Fi 和本地网络权限。",
                                         .zhHant: "近場探索已開啟但尚未廣播：正在等待 Wi-Fi 和區域網路權限。"],
        .visibilityStoppedFooter: [.en: "Start the service to change who can connect.",
                                   .zhHans: "启动服务后才能更改谁可以连接。",
                                   .zhHant: "啟動服務後才能變更誰可以連線。"],
        .stepsDone: [.en: "%d of %d done", .zhHans: "已完成 %d / %d", .zhHant: "已完成 %d / %d"],
        .diskImageMounted: [.en: "Disk image mounted", .zhHans: "磁盘镜像已挂载", .zhHant: "磁碟映像已掛載"],
        .clientsNeedService: [.en: "Start the service to see its clients.",
                              .zhHans: "启动服务后可查看客户端。",
                              .zhHant: "啟動服務後可查看用戶端。"],
        .clientsSwipeFooter: [.en: "Swipe a client to revoke its key. Revoking takes effect immediately.",
                              .zhHans: "左滑客户端可吊销其密钥，立即生效。",
                              .zhHant: "左滑用戶端可撤銷其金鑰，立即生效。"],
        .showAllClients: [.en: "Show All (%d)", .zhHans: "显示全部（%d）", .zhHant: "顯示全部（%d）"],
        .appLogs: [.en: "App Logs", .zhHans: "App 日志", .zhHant: "App 日誌"],
        .serviceInfo: [.en: "Service Info", .zhHans: "服务信息", .zhHant: "服務資訊"],
        .serviceStoppedInfo: [.en: "The service isn't running. Start it to see what it reports.",
                              .zhHans: "服务未运行。启动后可查看其信息。",
                              .zhHant: "服務未執行。啟動後可查看其資訊。"],
        .license: [.en: "License", .zhHans: "许可证", .zhHant: "授權條款"],

        // Pairing & Disk Image
        .stepsLeft: [.en: "%d steps left", .zhHans: "还剩 %d 步", .zhHant: "還剩 %d 步"],
        .oneStepLeft: [.en: "1 step left", .zhHans: "还剩 1 步", .zhHant: "還剩 1 步"],
        .mounting: [.en: "Mounting…", .zhHans: "正在挂载…", .zhHant: "正在掛載…"],
        .stepPairing: [.en: "Pair this iPhone", .zhHans: "配对这台 iPhone", .zhHant: "配對這台 iPhone"],
        .stepTunnel: [.en: "Connect the tunnel", .zhHans: "连接隧道", .zhHant: "連接通道"],
        .stepMount: [.en: "Mount the image", .zhHans: "挂载镜像", .zhHant: "掛載映像"],
        .pairingInProgress: [.en: "Pairing…", .zhHans: "正在配对…", .zhHant: "正在配對…"],
        .pairOnThisIPhone: [.en: "Pair on this iPhone", .zhHans: "在这台 iPhone 上配对", .zhHant: "在這台 iPhone 上配對"],
        .pairAgainOnDevice: [.en: "Pair again on this iPhone", .zhHans: "在这台 iPhone 上重新配对", .zhHant: "在這台 iPhone 上重新配對"],
        .importPairingFileShort: [.en: "Import pairing file", .zhHans: "导入配对文件", .zhHant: "匯入配對檔案"],
        .replacePairingFileShort: [.en: "Replace pairing file", .zhHans: "更换配对文件", .zhHant: "更換配對檔案"],
        .importPairingDetail: [.en: "A pairing file from a computer or iLoader.",
                               .zhHans: "来自电脑或 iLoader 的配对文件。",
                               .zhHant: "來自電腦或 iLoader 的配對檔案。"],
        .downloading: [.en: "Downloading", .zhHans: "正在下载", .zhHant: "正在下載"],
        .notDownloaded: [.en: "Not downloaded", .zhHans: "未下载", .zhHant: "未下載"],
        .tunnelConnected: [.en: "Connected", .zhHans: "已连接", .zhHant: "已連線"],
        .tunnelNotConnected: [.en: "Installed, not connected", .zhHans: "已安装，未连接", .zhHant: "已安裝，未連線"],
        .tunnelNotInstalled: [.en: "Not installed", .zhHans: "未安装", .zhHant: "未安裝"],
        .tunnelLocalNetworkDenied: [.en: "Local Network denied", .zhHans: "本地网络被拒绝", .zhHant: "區域網路遭拒"],
        .tunnelNotDevice: [.en: "Not this device", .zhHans: "不是本机", .zhHant: "不是本機"],
        .phaseConnecting: [.en: "Connecting through the tunnel…", .zhHans: "正在通过隧道连接…", .zhHant: "正在透過通道連線…"],
        .phaseQuerying: [.en: "Reading device identity…", .zhHans: "正在读取设备身份…", .zhHant: "正在讀取裝置身分…"],
        .phaseFinalizing: [.en: "Finalizing…", .zhHans: "正在完成…", .zhHant: "正在完成…"],
        .troubleshooting: [.en: "Troubleshooting", .zhHans: "疑难排解", .zhHant: "疑難排解"],
        .remount: [.en: "Mount again", .zhHans: "重新挂载", .zhHant: "重新掛載"],
        .stikDebugDetail: [.en: "An alternative mounter, if the in-app one fails. Sideload it from stikdebug.xyz — it isn't on the App Store.",
                           .zhHans: "内置挂载失败时的备选挂载工具。需从 stikdebug.xyz 侧载，App Store 上没有。",
                           .zhHant: "內建掛載失敗時的備選掛載工具。需從 stikdebug.xyz 側載，App Store 上沒有。"],
        .localDevVPNDetail: [.en: "Needed either way — it makes this device's debug service reachable.",
                             .zhHans: "两种方式都需要——它让本机的调试服务可以被访问。",
                             .zhHant: "兩種方式都需要——它讓本機的除錯服務可以被存取。"],
        .openApp: [.en: "Open", .zhHans: "打开", .zhHant: "開啟"],
        .appStore: [.en: "App Store", .zhHans: "App Store", .zhHant: "App Store"],

        // Logs
        .noLogsYet: [.en: "No logs yet.", .zhHans: "还没有日志。", .zhHant: "還沒有日誌。"],
        .noMatches: [.en: "No matching lines", .zhHans: "没有匹配的行", .zhHant: "沒有符合的行"],
        .currentRun: [.en: "Current", .zhHans: "当前", .zhHant: "目前"],
        .share: [.en: "Share", .zhHans: "分享", .zhHant: "分享"],
        .shareCurrentLog: [.en: "Share Current Log", .zhHans: "分享当前日志", .zhHant: "分享目前日誌"],
        .refresh: [.en: "Refresh", .zhHans: "刷新", .zhHant: "重新整理"],
        .unreadable: [.en: "(unreadable)", .zhHans: "（无法读取）", .zhHant: "（無法讀取）"],
        .deleteAllLogs: [.en: "Delete All Logs", .zhHans: "删除全部日志", .zhHant: "刪除全部日誌"],
        .deleteAllLogsConfirm: [.en: "Delete all logs?", .zhHans: "删除全部日志？", .zhHant: "刪除全部日誌？"],
        .deleteAllLogsBody: [.en: "This removes every saved run, including the current one.",
                             .zhHans: "这会删除所有已保存的运行记录，包括当前这次。",
                             .zhHant: "這會刪除所有已儲存的執行記錄，包括目前這次。"],
        .deleteAll: [.en: "Delete All", .zhHans: "全部删除", .zhHant: "全部刪除"],
    ]
}

extension DeveloperDiskImage.Status {
    /// `summary`, localized for display.
    var localizedSummary: String {
        if isMounted { return L10n.ui(.mounted) }
        return hasDeveloperDirectory ? L10n.ui(.notMounted) : L10n.ui(.unavailable)
    }
}
