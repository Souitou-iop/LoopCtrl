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
    }

    static func ui(_ key: UI) -> String {
        let row = uiTable[key] ?? [:]
        return row[lang] ?? row[.en] ?? ""
    }

    private static let uiTable: [UI: [Lang: String]] = [
        .settingsTitle: [.en: "Settings", .zhHans: "设置", .zhHant: "設定"],
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
