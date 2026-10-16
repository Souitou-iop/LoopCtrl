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
        case portLabel, portFooter, portRunningFooter, portInvalid, portReset
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
        .portRunningFooter: [.en: "Stop the service to change the port.",
                             .zhHans: "停止服务后才能修改端口。",
                             .zhHant: "停止服務後才能修改連接埠。"],
        .portInvalid: [.en: "Use a port from %d to %d.",
                       .zhHans: "端口需在 %d 到 %d 之间。",
                       .zhHant: "連接埠需在 %d 到 %d 之間。"],
        .portReset: [.en: "Restore Default", .zhHans: "恢复默认", .zhHant: "恢復預設"],
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
    ]
}

extension DeveloperDiskImage.Status {
    /// `summary`, localized for display.
    var localizedSummary: String {
        if isMounted { return L10n.ui(.mounted) }
        return hasDeveloperDirectory ? L10n.ui(.notMounted) : L10n.ui(.unavailable)
    }
}
