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
        case controlPage, shareControlPage
        case broadcastToggle, broadcastFooter, broadcastStart, broadcastRunning
        case remoteAccess, remoteAccessOnFooter, remoteAccessOffFooter, remoteAccessApproveFooter
        case portLabel, portFooter, portRunningFooter, portInvalid, portReset, portApply
        // Settings sheet
        case connectionSection, setupSection, clientsSection, diagnosticsSection
        case visibilityThisDevice, visibilityLAN, visibilityNearby
        case visibilityNearbyFooter, visibilityNearbyPendingFooter, visibilityStoppedFooter
        case stepsDone, diskImageMounted
        case clientsNeedService, clientsSwipeFooter, showAllClients
        case appLogs, serviceInfo, serviceStoppedInfo, license, thirdPartyNotices
        // Pairing & Disk Image
        case stepsLeft, oneStepLeft, mounting
        case stepPairing, stepTunnel, stepMount
        case pairingInProgress, pairOnThisIPhone, pairAgainOnDevice
        case importPairingFileShort, replacePairingFileShort, importPairingDetail
        case downloading, notDownloaded
        case tunnelConnected, tunnelNotConnected, tunnelNotInstalled, tunnelLocalNetworkDenied, tunnelNotDevice
        case phaseConnecting, phaseQuerying, phaseFinalizing
        case troubleshooting, remount, stikDebugDetail, localDevVPNDetail, openApp, appStore
        // Authorization
        case authorizationTitle, authorizedCount, missedRequests
        case pendingSection, recentSection, recentFooter, noRecentRequests
        case pairKeyHint, pairNoKeyHint, pairSecondsLeft
        case outcomePending, outcomeAllowed, outcomeDenied, outcomeTimedOut, outcomeAllowedOnRetry
        case allowThisClient, grantArmed, grantUsed, noKeyCannotAllow
        case revokeAll, viaTailnet
        // Logs
        case noLogsYet, noMatches, currentRun, share, shareCurrentLog, refresh, unreadable
        case deleteAllLogs, deleteAllLogsConfirm, deleteAllLogsBody, deleteAll
    }

    static func ui(_ key: UI) -> String {
        let row = uiTable[key] ?? [:]
        return row[lang] ?? row[.en] ?? ""
    }

    private static let uiTable: [UI: [Lang: String]] = [
        .authorizationTitle: [.en: "Authorization", .zhHans: "授权管理", .zhHant: "授權管理"],
        .authorizedCount: [.en: "%d Authorized Clients", .zhHans: "已授权 %d 个客户端", .zhHant: "已授權 %d 個用戶端"],
        .missedRequests: [.en: "%d missed requests can still be allowed",
                          .zhHans: "%d 个错过的请求仍可允许",
                          .zhHant: "%d 個錯過的請求仍可允許"],
        .pendingSection: [.en: "Waiting for Approval", .zhHans: "待处理", .zhHant: "待處理"],
        .recentSection: [.en: "Recent Requests", .zhHans: "最近请求", .zhHant: "最近請求"],
        .recentFooter: [.en: "Requests stay here for 10 minutes. Allowing a client lets its next request with the same key in once, without asking; any other key is asked about as usual. A request without a key (plain USB pairing) can only be answered while it waits.",
                        .zhHans: "请求会在这里保留 10 分钟。允许某个客户端后，它下次用同一密钥发起的请求会直接通过一次，不再询问；其他密钥照常询问。没有密钥的请求（USB 明文配对）只能在等待期间处理。",
                        .zhHant: "請求會在這裡保留 10 分鐘。允許某個用戶端後，它下次用同一金鑰發起的請求會直接通過一次，不再詢問；其他金鑰照常詢問。沒有金鑰的請求（USB 明文配對）只能在等待期間處理。"],
        .noRecentRequests: [.en: "No requests in the last 10 minutes", .zhHans: "最近 10 分钟没有请求", .zhHant: "最近 10 分鐘沒有請求"],
        .pairKeyHint: [.en: "Allow only if the client shows the same key.",
                       .zhHans: "客户端上显示的密钥一致才允许。",
                       .zhHant: "用戶端上顯示的金鑰一致才允許。"],
        .pairNoKeyHint: [.en: "No key: anything on this device or a computer over USB could have sent this.",
                         .zhHans: "没有密钥：本机上的任何 App 或通过 USB 连接的电脑都可能发出此请求。",
                         .zhHant: "沒有金鑰：本機上的任何 App 或透過 USB 連接的電腦都可能發出此請求。"],
        .pairSecondsLeft: [.en: "%d seconds left", .zhHans: "剩余 %d 秒", .zhHant: "剩餘 %d 秒"],
        .outcomePending: [.en: "Waiting", .zhHans: "等待中", .zhHant: "等待中"],
        .outcomeAllowed: [.en: "Allowed", .zhHans: "已允许", .zhHant: "已允許"],
        .outcomeDenied: [.en: "Denied", .zhHans: "已拒绝", .zhHant: "已拒絕"],
        .outcomeTimedOut: [.en: "Timed out", .zhHans: "已超时", .zhHant: "已逾時"],
        .outcomeAllowedOnRetry: [.en: "Allowed on retry", .zhHans: "重试已通过", .zhHant: "重試已通過"],
        .allowThisClient: [.en: "Allow This Client", .zhHans: "允许此客户端", .zhHant: "允許此用戶端"],
        .grantArmed: [.en: "Allowed — waiting for the client to retry (%@)",
                      .zhHans: "已允许，等待客户端重试（%@）",
                      .zhHant: "已允許，等待用戶端重試（%@）"],
        .grantUsed: [.en: "The client came back and was let in", .zhHans: "客户端已重试并通过", .zhHant: "用戶端已重試並通過"],
        .noKeyCannotAllow: [.en: "No key to bind an approval to — ask the client to try again.",
                            .zhHans: "没有可绑定的密钥，请让客户端重新发起请求。",
                            .zhHant: "沒有可綁定的金鑰，請讓用戶端重新發起請求。"],
        .revokeAll: [.en: "Revoke All", .zhHans: "吊销全部", .zhHant: "撤銷全部"],
        .viaTailnet: [.en: "Tailscale", .zhHans: "Tailscale", .zhHant: "Tailscale"],
        .settingsTitle: [.en: "Settings", .zhHans: "设置", .zhHant: "設定"],
        .localAddress: [.en: "This device", .zhHans: "本机", .zhHant: "本機"],
        .lanAddress: [.en: "Wi-Fi", .zhHans: "局域网", .zhHant: "區域網路"],
        .noWiFi: [.en: "Not on Wi-Fi", .zhHans: "未连接 Wi-Fi", .zhHant: "未連接 Wi-Fi"],
        .controlPage: [.en: "Control page", .zhHans: "网页控制", .zhHant: "網頁控制"],
        .broadcastToggle: [.en: "System Broadcast", .zhHans: "系统录屏推流", .zhHant: "系統錄影推流"],
        .broadcastFooter: [.en: "The remote screen comes from iOS screen recording instead of screenshots: up to 60 fps, less delay, cooler phone. Start it on the home screen each time; it shows the red recording indicator, and screenshots take over again when it ends.",
                           .zhHans: "远程画面改由 iOS 系统录屏提供，不再逐帧截图：最高 60 帧、延迟更低、手机更凉。每次需在首页点一下开始；运行时会显示红色录屏标记，结束后自动回到截图。",
                           .zhHant: "遠端畫面改由 iOS 系統錄影提供，不再逐格截圖：最高 60 格、延遲更低、手機更涼。每次需在首頁點一下開始；執行時會顯示紅色錄影標記，結束後自動回到截圖。"],
        .broadcastStart: [.en: "Start", .zhHans: "开始", .zhHant: "開始"],
        .broadcastRunning: [.en: "Broadcasting", .zhHans: "推流中", .zhHant: "推流中"],
        .shareControlPage: [.en: "Share the control page link",
                            .zhHans: "分享网页控制链接", .zhHant: "分享網頁控制連結"],
        .copied: [.en: "Copied", .zhHans: "已复制", .zhHant: "已複製"],
        .portLabel: [.en: "Port", .zhHans: "端口", .zhHant: "連接埠"],
        .portFooter: [.en: "The port automation clients connect to. Default %d. Don't share it with another automation app.",
                      .zhHans: "自动化客户端连接的端口，默认 %d。不要和其他自动化 App 使用同一个端口。",
                      .zhHant: "自動化用戶端連線的連接埠，預設 %d。不要和其他自動化 App 使用同一個連接埠。"],
        .portRunningFooter: [.en: "The service restarts on the new port; connected clients reconnect to the new address.",
                             .zhHans: "服务会在新端口上重启，已连接的客户端需要改用新地址重新连接。",
                             .zhHant: "服務會在新連接埠上重新啟動，已連線的用戶端需要改用新位址重新連線。"],
        .portInvalid: [.en: "Use a port from %d to %d.",
                       .zhHans: "端口需在 %d 到 %d 之间。",
                       .zhHant: "連接埠需在 %d 到 %d 之間。"],
        .portReset: [.en: "Restore Default", .zhHans: "恢复默认", .zhHant: "恢復預設"],
        .portApply: [.en: "Move Service to Port %@", .zhHans: "将服务切换到端口 %@", .zhHant: "將服務切換到連接埠 %@"],
        .remoteAccess: [.en: "LAN Access", .zhHans: "局域网访问", .zhHant: "區域網路存取"],
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
        .thirdPartyNotices: [.en: "Open-Source Licenses", .zhHans: "开源许可", .zhHant: "開放原始碼授權"],

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
