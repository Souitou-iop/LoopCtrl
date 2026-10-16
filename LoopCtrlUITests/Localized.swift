import Foundation

/// Lightweight, dependency-free localization for the on-device notifications and
/// their action buttons. LoopCtrl ships as a re-signed IPA without a .lproj bundle,
/// so instead of NSLocalizedString we key a small in-code table by the system
/// language and fall back to English. Notification action titles are plain text;
/// their SF Symbols are set where the actions are registered.
///
/// Supported: English, 简体中文, 繁體中文, 日本語, 한국어, Español, Deutsch, Русский.
enum L10n {
    enum Lang { case en, zhHans, zhHant, ja, ko, es, de, ru }

    /// The active language bucket, from the user's preferred languages.
    static let lang: Lang = {
        guard let first = Locale.preferredLanguages.first?.lowercased() else { return .en }
        if first.hasPrefix("zh") {
            if first.contains("hant") || first.contains("tw") || first.contains("hk") || first.contains("mo") {
                return .zhHant
            }
            return .zhHans
        }
        if first.hasPrefix("ja") { return .ja }
        if first.hasPrefix("ko") { return .ko }
        if first.hasPrefix("es") { return .es }
        if first.hasPrefix("de") { return .de }
        if first.hasPrefix("ru") { return .ru }
        return .en
    }()

    /// Look up a key; returns the string for the active language (English fallback).
    static func t(_ key: Key) -> String {
        let row = table[key] ?? [:]
        return row[lang] ?? row[.en] ?? ""
    }

    enum Key {
        // ── Notifications (posted by the runner) ──
        //
        // Title "LoopCtrl"; state and address in the subtitle; the body only for
        // what matters next. Words match the app's (服务, 远程访问, 本机, 局域网, 近场).
        case allow, deny, enableRemote, disableRemote, enableNearby, disableNearby, stopServer, copyLogs
        // Status notification: subtitle, then body lines.
        case statusRunning          // %@ = address:port
        case statusLocal, statusLAN, statusNoLAN
        case statusNearby           // %@ = the name nearby clients see
        case nearbyStarting, nearbyNeedsWiFi, nearbyNeedsPermission, nearbyNotReady
        case statusUptime           // %d = connected clients, %@ = uptime
        case remoteDisabledNote
        // The other server notifications.
        case serverFailedSubtitle   // %@ = port
        case serverStoppedSubtitle, longPressCopyLogs
        case remoteFailedSubtitle   // %@ = address:port
        case remoteFailedBody
        // Pairing request.
        case authRequestTitle
        case authFromLAN, authFromNearby, authFromLocal   // %@ = client name
        case authKeyLine            // %@ = key fingerprint the client also prints
        case authRequestBody

        // ── Host app UI ──
        //
        // Only English and Chinese are filled in for these: the rest fall back to
        // English, which is the point of having a fallback. Technical strings the
        // user would search for or paste into a bug report (FFI errors, HTTP
        // status, bundle ids) are deliberately NOT here — translating them makes
        // them harder to look up, not easier.
        case runtimeRequirements, developerDiskImage, mountPoint
        case mountWithoutMac, remount
        case ddiReadyFooter
        case serverSectionTitle, statusLabel, addressLabel, checking, running, stopped
        case startServer, stopServerButton, serverLabel, protocolLabel, methodsLabel, capabilitiesLabel
        case serverRunningFooter, mountFirstFooter, startOpensRunnerFooter
        case deviceSection, modelLabel, systemLabel, screenLabel, nameLabel
        case aboutSection, versionLabel, logsLabel, logsFooter
        case alternativeSection, alternativeFooter
        case mountTitle, doneButton, prerequisiteHeader
        case startLocalDevVPN, tunnelUpDetail, vpnInstalledDetail, vpnMissingDetail
        case openVPNAndConnect, getVPNFromAppStore, tunnelDetectedFooter, cannotStartVPNFooter
        case tunnelAppLabel, shadowrocketRouteHint, tunnelNotDeviceDetail
        case importPairingFile, choosePairingFile, replacePairingFile, removePairingFile
        case pairingHint, pairingImported, pairingReceivedTitle, pairingReceivedBody, pairingRejectedTitle
        case pairOnDevice, pairOnDeviceHint, pairWaitingSteps, pairEnterPin, pairStop, pairOrImport
        case pairPinTitle, pairPinBody, pairDoneTitle, pairDoneBody, pairWaitingSubtitle
        case ddiComponentTitle, ddiDownloadHint, ddiDownloaded, downloadImageFiles, ddiSourceFooter
        case mountButton, mountedOK, mountFailed, mountNotPersistentFooter, firstMountNetworkFooter
        case finishStepsFirst, vpnNotConnected, vpnNotInstalled, noPairingFile, imagesNotDownloaded
        case localNetworkDeniedDetail, openSettings, interfacesSeen
        case networkPermissionTitle, networkPermissionBody, networkDataPermission, localNetworkPermission, laterButton
        case wifiRequired, wifiConnected, wifiMissing, wifiFooter, notOnWiFi
        case mountIntro, uploadingImage
        case authorizedClients, runnerLogs, appLogsSection, runnerSection
        case connectRunnerTitle, connectRunnerBody, connectButton, waitingApproval
        case runnerNotRunningHint, keyRejectedHint, pairDeniedHint, retryInSeconds
        case thisApp, revokeButton, revokeOthers, revokeConfirmTitle, revokeConfirmBody
        case revokeOthersConfirm, disconnectThisApp, disconnectConfirmBody
        case noClients, pairedAt, lastActive, clientsFooter
        case liveLabel, pausedLabel, filterPlaceholder, noLogLines, copyButton, runnerLogsCaption, cancelButton
        case viaLocal, viaLAN, viaNearby, viaVPN, viaCellular, viaOther
        case visibilityLabel, visibilityLocal, visibilityLAN, visibilityLANNearby, visibilityNearbyPending, runnerLocalNetworkDenied
    }

    // key → (lang → text). English is the required fallback for every key.
    private static let table: [Key: [Lang: String]] = [
        // ── Notification actions (each has an SF Symbol, set in setupNotifications) ──
        .allow: [.en: "Allow", .zhHans: "允许", .zhHant: "允許", .ja: "許可",
                 .ko: "허용", .es: "Permitir", .de: "Zulassen", .ru: "Разрешить"],
        .deny: [.en: "Deny", .zhHans: "拒绝", .zhHant: "拒絕", .ja: "拒否",
                .ko: "거부", .es: "Denegar", .de: "Ablehnen", .ru: "Отклонить"],
        .enableRemote: [.en: "Turn On Remote Access", .zhHans: "开启远程访问", .zhHant: "開啟遠端存取", .ja: "リモートアクセスをオン",
                        .ko: "원격 접속 켜기", .es: "Activar acceso remoto", .de: "Fernzugriff einschalten", .ru: "Включить удалённый доступ"],
        .disableRemote: [.en: "Turn Off Remote Access", .zhHans: "关闭远程访问", .zhHant: "關閉遠端存取", .ja: "リモートアクセスをオフ",
                         .ko: "원격 접속 끄기", .es: "Desactivar acceso remoto", .de: "Fernzugriff ausschalten", .ru: "Выключить удалённый доступ"],
        .enableNearby: [.en: "Turn On Nearby", .zhHans: "开启近场发现", .zhHant: "開啟近場探索", .ja: "近距離検出をオン",
                        .ko: "근거리 검색 켜기", .es: "Activar detección cercana", .de: "Nahbereich einschalten", .ru: "Включить поиск поблизости"],
        .disableNearby: [.en: "Turn Off Nearby", .zhHans: "关闭近场发现", .zhHant: "關閉近場探索", .ja: "近距離検出をオフ",
                         .ko: "근거리 검색 끄기", .es: "Desactivar detección cercana", .de: "Nahbereich ausschalten", .ru: "Выключить поиск поблизости"],
        .stopServer: [.en: "Stop Service", .zhHans: "停止服务", .zhHant: "停止服務", .ja: "サービスを停止",
                      .ko: "서비스 중지", .es: "Detener servicio", .de: "Dienst stoppen", .ru: "Остановить сервис"],
        .copyLogs: [.en: "Copy Logs", .zhHans: "复制日志", .zhHant: "複製日誌", .ja: "ログをコピー",
                    .ko: "로그 복사", .es: "Copiar registros", .de: "Logs kopieren", .ru: "Копировать логи"],

        // ── Status notification ──
        .statusRunning: [.en: "Running · %@", .zhHans: "运行中 · %@", .zhHant: "執行中 · %@", .ja: "稼働中 · %@",
                         .ko: "실행 중 · %@", .es: "En ejecución · %@", .de: "Läuft · %@", .ru: "Работает · %@"],
        .statusLocal: [.en: "Only this device can connect", .zhHans: "仅本机可连接", .zhHant: "僅本機可連線", .ja: "この端末からのみ接続可能",
                       .ko: "이 기기에서만 연결 가능", .es: "Solo este dispositivo puede conectarse", .de: "Nur dieses Gerät kann sich verbinden", .ru: "Подключиться можно только с этого устройства"],
        .statusLAN: [.en: "Devices on this Wi-Fi can connect", .zhHans: "同一 Wi-Fi 下的设备可连接", .zhHant: "同一 Wi-Fi 下的裝置可連線", .ja: "同じ Wi-Fi の端末から接続可能",
                     .ko: "같은 Wi-Fi의 기기에서 연결 가능", .es: "Los dispositivos de esta Wi-Fi pueden conectarse", .de: "Geräte in diesem WLAN können sich verbinden", .ru: "Подключиться можно из этой сети Wi-Fi"],
        .statusNoLAN: [.en: "Not on Wi-Fi · only this device can connect", .zhHans: "未连接 Wi-Fi · 仅本机可连接", .zhHant: "未連接 Wi-Fi · 僅本機可連線", .ja: "Wi-Fi 未接続 · この端末からのみ接続可能",
                       .ko: "Wi-Fi 미연결 · 이 기기에서만 연결 가능", .es: "Sin Wi-Fi · solo este dispositivo puede conectarse", .de: "Kein WLAN · nur dieses Gerät kann sich verbinden", .ru: "Нет Wi-Fi · подключиться можно только с этого устройства"],
        .statusNearby: [.en: "Nearby as “%@”", .zhHans: "近场可发现：“%@”", .zhHant: "近場可探索：「%@」", .ja: "近距離で「%@」として検出可能",
                        .ko: "근거리에서 “%@”(으)로 표시", .es: "Visible cerca como «%@»", .de: "In der Nähe sichtbar als „%@“", .ru: "Виден поблизости как «%@»"],
        .nearbyStarting: [.en: "Nearby starting…", .zhHans: "近场发现启动中…", .zhHant: "近場探索啟動中…", .ja: "近距離検出を開始中…",
                          .ko: "근거리 검색 시작 중…", .es: "Iniciando detección cercana…", .de: "Nahbereich startet…", .ru: "Запуск поиска поблизости…"],
        .nearbyNeedsWiFi: [.en: "Nearby needs Wi-Fi turned on", .zhHans: "近场发现需要打开 Wi-Fi", .zhHant: "近場探索需要開啟 Wi-Fi", .ja: "近距離検出には Wi-Fi をオンにしてください",
                           .ko: "근거리 검색에는 Wi-Fi가 켜져 있어야 함", .es: "La detección cercana necesita el Wi-Fi activado", .de: "Nahbereich braucht eingeschaltetes WLAN", .ru: "Для поиска поблизости включите Wi-Fi"],
        .nearbyNeedsPermission: [.en: "Nearby needs Local Network access", .zhHans: "近场发现需要允许本地网络", .zhHant: "近場探索需要允許區域網路", .ja: "近距離検出にはローカルネットワークの許可が必要",
                                 .ko: "근거리 검색에는 로컬 네트워크 허용이 필요", .es: "La detección cercana necesita permiso de Red local", .de: "Nahbereich braucht Zugriff auf das lokale Netzwerk", .ru: "Для поиска поблизости разрешите локальную сеть"],
        .nearbyNotReady: [.en: "Nearby not ready · retrying", .zhHans: "近场发现未就绪 · 正在重试", .zhHant: "近場探索未就緒 · 正在重試", .ja: "近距離検出は準備中 · 再試行中",
                          .ko: "근거리 검색 준비 안 됨 · 재시도 중", .es: "Detección cercana no lista · reintentando", .de: "Nahbereich nicht bereit · neuer Versuch", .ru: "Поиск поблизости не готов · повтор"],
        .statusUptime: [.en: "%d connected · up %@", .zhHans: "已连接 %d 个 · 已运行 %@", .zhHant: "已連線 %d 個 · 已執行 %@", .ja: "接続 %d 件 · 稼働 %@",
                        .ko: "연결 %d개 · 실행 %@", .es: "%d conectados · activo %@", .de: "%d verbunden · läuft seit %@", .ru: "Подключено: %d · работает %@"],
        .remoteDisabledNote: [.en: "Remote access turned off", .zhHans: "远程访问已关闭", .zhHant: "遠端存取已關閉", .ja: "リモートアクセスをオフにしました",
                              .ko: "원격 접속을 껐습니다", .es: "Acceso remoto desactivado", .de: "Fernzugriff ausgeschaltet", .ru: "Удалённый доступ выключен"],

        // ── Server failed / stopped, remote access failed ──
        .serverFailedSubtitle: [.en: "Couldn't start · port %@", .zhHans: "服务启动失败 · 端口 %@", .zhHant: "服務啟動失敗 · 連接埠 %@", .ja: "起動できません · ポート %@",
                                .ko: "시작할 수 없음 · 포트 %@", .es: "No se pudo iniciar · puerto %@", .de: "Start fehlgeschlagen · Port %@", .ru: "Не удалось запустить · порт %@"],
        .serverStoppedSubtitle: [.en: "Service stopped", .zhHans: "服务已停止", .zhHant: "服務已停止", .ja: "サービスを停止しました",
                                 .ko: "서비스가 중지됨", .es: "Servicio detenido", .de: "Dienst gestoppt", .ru: "Сервис остановлен"],
        .longPressCopyLogs: [.en: "Long-press to copy the logs.", .zhHans: "长按可复制日志。", .zhHant: "長按可複製日誌。", .ja: "長押しでログをコピーできます。",
                             .ko: "길게 눌러 로그를 복사할 수 있습니다.", .es: "Mantén pulsado para copiar los registros.", .de: "Lang drücken, um die Logs zu kopieren.", .ru: "Удерживайте, чтобы скопировать логи."],
        .remoteFailedSubtitle: [.en: "Remote access unreachable · %@", .zhHans: "远程访问不可用 · %@", .zhHant: "遠端存取無法使用 · %@", .ja: "リモートアクセス不可 · %@",
                                .ko: "원격 접속 불가 · %@", .es: "Acceso remoto inaccesible · %@", .de: "Fernzugriff nicht erreichbar · %@", .ru: "Удалённый доступ недоступен · %@"],
        .remoteFailedBody: [.en: "Allow Local Network: open LoopCtrl, accept the prompt, then reconnect. 127.0.0.1 still works.",
                            .zhHans: "请允许本地网络：打开 LoopCtrl，在弹出的提示中允许，然后重新连接。本机 127.0.0.1 仍可用。",
                            .zhHant: "請允許區域網路：開啟 LoopCtrl，在跳出的提示中允許，然後重新連線。本機 127.0.0.1 仍可使用。",
                            .ja: "ローカルネットワークを許可してください：LoopCtrl を開いて許可し、再接続します。127.0.0.1 は引き続き使えます。",
                            .ko: "로컬 네트워크를 허용하세요: LoopCtrl을 열어 허용한 뒤 다시 연결합니다. 127.0.0.1은 계속 사용할 수 있습니다.",
                            .es: "Permite la Red local: abre LoopCtrl, acepta el aviso y vuelve a conectar. 127.0.0.1 sigue funcionando.",
                            .de: "Lokales Netzwerk erlauben: LoopCtrl öffnen, die Abfrage bestätigen, dann neu verbinden. 127.0.0.1 funktioniert weiterhin.",
                            .ru: "Разрешите локальную сеть: откройте LoopCtrl, подтвердите запрос и переподключитесь. 127.0.0.1 по-прежнему работает."],

        // ── Pairing request ──
        .authRequestTitle: [.en: "New connection request", .zhHans: "新的连接请求", .zhHant: "新的連線請求", .ja: "新しい接続リクエスト",
                            .ko: "새 연결 요청", .es: "Nueva solicitud de conexión", .de: "Neue Verbindungsanfrage", .ru: "Новый запрос на подключение"],
        .authFromLAN: [.en: "“%@” · LAN", .zhHans: "“%@” · 局域网", .zhHant: "「%@」 · 區域網路", .ja: "「%@」 · LAN",
                       .ko: "“%@” · LAN", .es: "«%@» · LAN", .de: "„%@“ · LAN", .ru: "«%@» · LAN"],
        .authFromNearby: [.en: "“%@” · nearby", .zhHans: "“%@” · 近场", .zhHant: "「%@」 · 近場", .ja: "「%@」 · 近距離",
                          .ko: "“%@” · 근거리", .es: "«%@» · cercano", .de: "„%@“ · in der Nähe", .ru: "«%@» · поблизости"],
        .authFromLocal: [.en: "“%@” · this device", .zhHans: "“%@” · 本机", .zhHant: "「%@」 · 本機", .ja: "「%@」 · この端末",
                         .ko: "“%@” · 이 기기", .es: "«%@» · este dispositivo", .de: "„%@“ · dieses Gerät", .ru: "«%@» · это устройство"],
        .authKeyLine: [.en: "Key %@ — allow only if your computer shows the same",
                       .zhHans: "密钥 %@ — 与电脑上显示的一致才允许",
                       .zhHant: "金鑰 %@ — 與電腦上顯示的一致才允許",
                       .ja: "キー %@ — コンピュータの表示と一致する場合のみ許可",
                       .ko: "키 %@ — 컴퓨터에 표시된 것과 같을 때만 허용",
                       .es: "Clave %@ — permite solo si tu ordenador muestra la misma",
                       .de: "Schlüssel %@ — nur erlauben, wenn dein Computer denselben zeigt",
                       .ru: "Ключ %@ — разрешайте, только если компьютер показывает такой же"],
        // Tapping the banner approves (the default action), so say so.
        .authRequestBody: [.en: "Wants to control this device. Tap to allow · long-press to deny.", .zhHans: "请求控制此设备。轻点即允许 · 长按可拒绝。", .zhHant: "請求控制此裝置。輕點即允許 · 長按可拒絕。", .ja: "このデバイスの操作を求めています。タップで許可 · 長押しで拒否。",
                           .ko: "이 기기의 제어를 요청합니다. 탭하면 허용 · 길게 눌러 거부.", .es: "Quiere controlar este dispositivo. Toca para permitir · mantén pulsado para denegar.", .de: "Möchte dieses Gerät steuern. Tippen zum Erlauben · lang drücken zum Ablehnen.", .ru: "Хочет управлять этим устройством. Нажмите, чтобы разрешить · удерживайте, чтобы отклонить."],

        // ── Host app UI (English base, Chinese translations) ──
        .runtimeRequirements: [.en: "Runtime Requirements", .zhHans: "运行环境要求", .zhHant: "執行環境需求"],
        .developerDiskImage: [.en: "Developer Disk Image", .zhHans: "开发者磁盘镜像", .zhHant: "開發者磁碟映像"],
        .mountPoint: [.en: "Mount point", .zhHans: "挂载位置", .zhHant: "掛載位置"],
        .mountWithoutMac: [.en: "Start local mount…", .zhHans: "开始本地挂载…", .zhHant: "開始本地掛載…"],
        .remount: [.en: "Re-mount…", .zhHans: "重新挂载…", .zhHant: "重新掛載…"],
        .ddiReadyFooter: [.en: "The automation runner can launch on this device. The image is dropped by a reboot — re-mount if the runner stops starting.",
                          .zhHans: "自动化 runner 可以在这台设备上启动。镜像会在重启后丢失——如果 runner 起不来，重新挂载即可。",
                          .zhHant: "自動化 runner 可以在這台裝置上啟動。映像會在重新開機後遺失——如果 runner 起不來，重新掛載即可。"],

        .serverSectionTitle: [.en: "LoopCtrl Server (Local)", .zhHans: "LoopCtrl 服务（本机）", .zhHant: "LoopCtrl 服務（本機）"],
        .statusLabel: [.en: "Status", .zhHans: "状态", .zhHant: "狀態"],
        .addressLabel: [.en: "Address", .zhHans: "地址", .zhHant: "位址"],
        .checking: [.en: "Checking…", .zhHans: "检测中…", .zhHant: "檢測中…"],
        .running: [.en: "Running", .zhHans: "运行中", .zhHant: "執行中"],
        .stopped: [.en: "Stopped", .zhHans: "已停止", .zhHant: "已停止"],
        .startServer: [.en: "Start Server", .zhHans: "启动服务", .zhHant: "啟動服務"],
        .stopServerButton: [.en: "Stop Server", .zhHans: "停止服务", .zhHant: "停止服務"],
        .serverLabel: [.en: "Server", .zhHans: "服务版本", .zhHant: "服務版本"],
        .protocolLabel: [.en: "Protocol", .zhHans: "协议", .zhHant: "協定"],
        .methodsLabel: [.en: "Methods", .zhHans: "方法数", .zhHant: "方法數"],
        .capabilitiesLabel: [.en: "Capabilities", .zhHans: "能力", .zhHant: "能力"],
        .serverRunningFooter: [.en: "Automation clients connect here; every request is encrypted.",
                               .zhHans: "自动化客户端连接到这里；每个请求都是加密的。",
                               .zhHant: "自動化用戶端連線到這裡；每個請求都是加密的。"],
        .mountFirstFooter: [.en: "Mount the Developer Disk Image first — without it the runner can't launch.",
                            .zhHans: "请先挂载开发者磁盘镜像——没有它 runner 无法启动。",
                            .zhHant: "請先掛載開發者磁碟映像——沒有它 runner 無法啟動。"],
        .startOpensRunnerFooter: [.en: "The server runs inside the automation runner. Starting it opens that app.",
                                  .zhHans: "服务运行在自动化 runner 里。启动会打开那个 App。",
                                  .zhHant: "服務執行在自動化 runner 裡。啟動會開啟那個 App。"],

        .deviceSection: [.en: "Device", .zhHans: "设备", .zhHant: "裝置"],
        .modelLabel: [.en: "Model", .zhHans: "型号", .zhHant: "型號"],
        .systemLabel: [.en: "System", .zhHans: "系统", .zhHant: "系統"],
        .screenLabel: [.en: "Screen", .zhHans: "屏幕", .zhHant: "螢幕"],
        .nameLabel: [.en: "Name", .zhHans: "名称", .zhHant: "名稱"],

        .aboutSection: [.en: "About", .zhHans: "关于", .zhHant: "關於"],
        .versionLabel: [.en: "Version", .zhHans: "版本", .zhHant: "版本"],
        .logsLabel: [.en: "Logs", .zhHans: "日志", .zhHant: "日誌"],
        .logsFooter: [.en: "One log per run, kept for the last 20. Tap to read or share one.",
                      .zhHans: "每次运行一份日志，保留最近 20 份。点击可查看或分享。",
                      .zhHant: "每次執行一份日誌，保留最近 20 份。點擊可檢視或分享。"],

        .alternativeSection: [.en: "Alternative", .zhHans: "备选方案", .zhHant: "備選方案"],
        .alternativeFooter: [.en: "The Developer Disk Image doesn't survive a reboot, so mounting has to be repeated after each restart — by either route.",
                             .zhHans: "开发者磁盘镜像重启后会丢失，所以每次重启都要重新挂载——两种方式都一样。",
                             .zhHant: "開發者磁碟映像重新開機後會遺失，所以每次重啟都要重新掛載——兩種方式都一樣。"],

        .mountTitle: [.en: "Mount DDI", .zhHans: "挂载 DDI", .zhHant: "掛載 DDI"],
        .doneButton: [.en: "Done", .zhHans: "完成", .zhHant: "完成"],
        .prerequisiteHeader: [.en: "Prerequisite", .zhHans: "前置条件", .zhHant: "前置條件"],
        .startLocalDevVPN: [.en: "Start %@", .zhHans: "启动 %@", .zhHant: "啟動 %@"],
        .tunnelUpDetail: [.en: "Tunnel is up — this device's debug service is reachable.",
                          .zhHans: "隧道已连接——本机调试服务可达。",
                          .zhHant: "通道已連線——本機除錯服務可達。"],
        .vpnInstalledDetail: [.en: "Installed. Connect it so this device's debug service becomes reachable.",
                              .zhHans: "已安装。连接后本机调试服务才可达。",
                              .zhHant: "已安裝。連線後本機除錯服務才可達。"],
        .vpnMissingDetail: [.en: "Not installed. It makes this device's debug service reachable — LoopCtrl then talks to it the same way Xcode on a Mac would.",
                            .zhHans: "未安装。它让本机的调试服务变得可达——LoopCtrl 随后以 Mac 上 Xcode 的同样方式与之通信。",
                            .zhHant: "未安裝。它讓本機的除錯服務變得可達——LoopCtrl 隨後以 Mac 上 Xcode 的同樣方式與之通訊。"],
        .openVPNAndConnect: [.en: "Open %@ & connect", .zhHans: "打开 %@ 并连接", .zhHant: "開啟 %@ 並連線"],
        .getVPNFromAppStore: [.en: "Get %@ on the App Store", .zhHans: "在 App Store 获取 %@", .zhHant: "在 App Store 取得 %@"],
        .tunnelAppLabel: [.en: "Tunnel app", .zhHans: "隧道 App", .zhHant: "通道 App"],
        .shadowrocketRouteHint: [.en: "In Shadowrocket, turn on Settings › Other › “Include Route 10.7.0.1/32”. Your proxy stays on; no VPN switching. Shadowrocket doesn't return here by itself — switch back after connecting. Use Wi-Fi: on cellular this route is unreliable.",
                                 .zhHans: "在 Shadowrocket 的 设置 › 其它 中打开“包含路由 10.7.0.1/32”。代理照常使用，不用切换 VPN。Shadowrocket 连接后不会自动跳回，请手动切回 LoopCtrl。请使用 Wi-Fi，蜂窝网络下这条路由不稳定。",
                                 .zhHant: "在 Shadowrocket 的 設定 › 其他 中打開「包含路由 10.7.0.1/32」。代理照常使用，不用切換 VPN。Shadowrocket 連線後不會自動跳回，請手動切回 LoopCtrl。請使用 Wi-Fi，行動網路下這條路由不穩定。"],
        .tunnelNotDeviceDetail: [.en: "Something answered at 10.7.0.1, but not this device's debug service — usually a proxy capturing the address without routing it back. In Shadowrocket, turn on “Include Route 10.7.0.1/32”.",
                                 .zhHans: "10.7.0.1 有应答，但不是本机调试服务——通常是代理接管了这个地址却没把它路由回本机。如用 Shadowrocket，请打开“包含路由 10.7.0.1/32”。",
                                 .zhHant: "10.7.0.1 有回應，但不是本機除錯服務——通常是代理接管了這個位址卻沒把它路由回本機。如用 Shadowrocket，請打開「包含路由 10.7.0.1/32」。"],
        .tunnelDetectedFooter: [.en: "Detected by connecting to this device's debug service through the tunnel.",
                                .zhHans: "依据能否经隧道连上本机调试服务来判断。",
                                .zhHant: "依據能否經通道連上本機除錯服務來判斷。"],
        .cannotStartVPNFooter: [.en: "LoopCtrl can't connect the VPN for you — tapping above opens it to do that. If mounting still fails to connect, check it there first.",
                                .zhHans: "LoopCtrl 无法替你连接 VPN——点击上面会打开它去连接。如果挂载仍然连不上，请先去那里检查。",
                                .zhHant: "LoopCtrl 無法替你連線 VPN——點擊上面會開啟它去連線。如果掛載仍然連不上，請先去那裡檢查。"],

        .importPairingFile: [.en: "Import a pairing file", .zhHans: "导入配对文件", .zhHant: "匯入配對檔案"],
        .choosePairingFile: [.en: "Choose pairing file…", .zhHans: "选择配对文件…", .zhHant: "選擇配對檔案…"],
        .replacePairingFile: [.en: "Replace pairing file…", .zhHans: "更换配对文件…", .zhHant: "更換配對檔案…"],
        .removePairingFile: [.en: "Remove pairing file", .zhHans: "删除配对文件", .zhHant: "刪除配對檔案"],
        .pairingHint: [.en: "Use a pairing file from StikPair, or one iLoader exported on iOS 17.4 or later (it holds both halves). A file from `idevicepair` alone won't mount. If the picker can't reach the file, share it to LoopCtrl from the app that has it.",
                       .zhHans: "可使用 StikPair 生成的配对文件，或 iOS 17.4 及以上由 iLoader 导出的配对文件（两种格式都包含）。仅由 `idevicepair` 生成的文件无法挂载。如果选择器找不到文件，可在文件所在的 App 里直接“分享”到 LoopCtrl。",
                       .zhHant: "可使用 StikPair 產生的配對檔案，或 iOS 17.4 以上由 iLoader 匯出的配對檔案（兩種格式都包含）。僅由 `idevicepair` 產生的檔案無法掛載。如果選擇器找不到檔案，可在檔案所在的 App 裡直接「分享」到 LoopCtrl。"],
        .pairOnDevice: [.en: "Pair on this device", .zhHans: "在本机配对", .zhHant: "在本機配對"],
        .pairOnDeviceHint: [.en: "No computer or other app needed: iOS pairs with LoopCtrl from Developer Mode settings.",
                            .zhHans: "无需电脑或其他 App：在“开发者模式”设置里让 iOS 直接与 LoopCtrl 配对。",
                            .zhHant: "無需電腦或其他 App：在「開發者模式」設定裡讓 iOS 直接與 LoopCtrl 配對。"],
        .pairWaitingSteps: [.en: "Open Settings › Privacy & Security › Developer Mode, scroll down and tap “Pair with LoopCtrl”. Enter the code LoopCtrl shows (also sent as a notification).",
                            .zhHans: "打开 设置 › 隐私与安全性 › 开发者模式，下拉点“与 LoopCtrl 配对”，输入 LoopCtrl 显示的配对码（也会以通知发送）。",
                            .zhHant: "打開 設定 › 隱私權與安全性 › 開發者模式，往下滑點「與 LoopCtrl 配對」，輸入 LoopCtrl 顯示的配對碼（也會以通知傳送）。"],
        .pairEnterPin: [.en: "Enter this code in Settings:", .zhHans: "在设置中输入此配对码：", .zhHant: "在設定中輸入此配對碼："],
        .pairStop: [.en: "Stop pairing", .zhHans: "停止配对", .zhHant: "停止配對"],
        .pairOrImport: [.en: "Or import a file", .zhHans: "或导入文件", .zhHant: "或匯入檔案"],
        .pairPinTitle: [.en: "LoopCtrl pairing code", .zhHans: "LoopCtrl 配对码", .zhHant: "LoopCtrl 配對碼"],
        .pairPinBody: [.en: "Enter %@ in Settings to pair.", .zhHans: "在设置中输入 %@ 完成配对。", .zhHant: "在設定中輸入 %@ 完成配對。"],
        .pairDoneTitle: [.en: "Pairing complete", .zhHans: "配对完成", .zhHant: "配對完成"],
        .pairDoneBody: [.en: "Return to LoopCtrl to mount the Developer Disk Image.",
                        .zhHans: "回到 LoopCtrl 挂载开发者磁盘镜像。", .zhHant: "回到 LoopCtrl 掛載開發者磁碟映像。"],
        .pairWaitingSubtitle: [.en: "Waiting for Settings to connect…", .zhHans: "等待设置连接…", .zhHant: "等待設定連線…"],
        .pairingImported: [.en: "Imported", .zhHans: "已导入", .zhHant: "已匯入"],
        .pairingReceivedTitle: [.en: "Pairing File Received", .zhHans: "已接收配对文件", .zhHant: "已接收配對檔案"],
        .pairingReceivedBody: [.en: "“%@” has been stored. You can mount the Developer Disk Image now.",
                               .zhHans: "已保存“%@”，现在可以挂载开发者磁盘镜像。",
                               .zhHant: "已儲存「%@」，現在可以掛載開發者磁碟映像。"],
        .pairingRejectedTitle: [.en: "Not a Usable Pairing File", .zhHans: "不是可用的配对文件", .zhHant: "不是可用的配對檔案"],

        .ddiComponentTitle: [.en: "Developer Disk Image", .zhHans: "开发者磁盘镜像", .zhHant: "開發者磁碟映像"],
        .ddiDownloadHint: [.en: "About 100 MB up to iOS 26.3, about 17 MB from iOS 26.4. Downloaded once and reused — only the mount has to be repeated after a reboot.",
                           .zhHans: "iOS 26.3 及以下约 100 MB，iOS 26.4 起约 17 MB。只需下载一次并重复使用——重启后只需重新挂载。",
                           .zhHant: "iOS 26.3 及以下約 100 MB，iOS 26.4 起約 17 MB。只需下載一次並重複使用——重新開機後只需重新掛載。"],
        .ddiDownloaded: [.en: "Downloaded", .zhHans: "已下载", .zhHant: "已下載"],
        .downloadImageFiles: [.en: "Download image files", .zhHans: "下载镜像文件", .zhHant: "下載映像檔案"],
        .ddiSourceFooter: [.en: "Fetched from the DeveloperDiskImage mirror maintained by the pymobiledevice3 author. Apple doesn't publish these for direct download; the same files ship inside Xcode.",
                           .zhHans: "取自 pymobiledevice3 作者维护的 DeveloperDiskImage 镜像源。苹果不提供直接下载；相同文件随 Xcode 一起分发。",
                           .zhHant: "取自 pymobiledevice3 作者維護的 DeveloperDiskImage 鏡像源。蘋果不提供直接下載；相同檔案隨 Xcode 一起分發。"],

        .mountButton: [.en: "Mount Developer Disk Image", .zhHans: "挂载开发者磁盘镜像", .zhHant: "掛載開發者磁碟映像"],
        .mountedOK: [.en: "Mounted — the automation runner can launch now", .zhHans: "已挂载——自动化 runner 现在可以启动了", .zhHant: "已掛載——自動化 runner 現在可以啟動了"],
        .mountFailed: [.en: "Mount failed", .zhHans: "挂载失败", .zhHant: "掛載失敗"],
        .mountNotPersistentFooter: [.en: "The image is not persistent — after a reboot, run this again. The pairing file and downloaded image are kept, so it's one tap.",
                                    .zhHans: "镜像不会持久保留——重启后需要再来一次。配对文件和已下载的镜像会保留，所以只需点一下。",
                                    .zhHant: "映像不會持久保留——重新開機後需要再來一次。配對檔案和已下載的映像會保留，所以只需點一下。"],
        .firstMountNetworkFooter: [.en: "The first mount asks Apple's signing service for a ticket unique to this device, so it needs internet access.",
                                   .zhHans: "首次挂载会向苹果签名服务申请本机专属的票据，因此需要联网。",
                                   .zhHant: "首次掛載會向蘋果簽名服務申請本機專屬的票據，因此需要連網。"],

        .finishStepsFirst: [.en: "Finish the steps above first", .zhHans: "请先完成上面的步骤", .zhHant: "請先完成上面的步驟"],
        .vpnNotConnected: [.en: "%@ isn't connected", .zhHans: "%@ 未连接", .zhHant: "%@ 未連線"],
        .vpnNotInstalled: [.en: "%@ isn't installed", .zhHans: "%@ 未安装", .zhHant: "%@ 未安裝"],
        .noPairingFile: [.en: "no pairing file imported", .zhHans: "尚未导入配对文件", .zhHant: "尚未匯入配對檔案"],
        .imagesNotDownloaded: [.en: "the image files aren't downloaded", .zhHans: "镜像文件尚未下载", .zhHant: "映像檔案尚未下載"],
        .wifiRequired: [.en: "Connect to Wi-Fi", .zhHans: "连接 Wi-Fi", .zhHant: "連線 Wi-Fi"],
        .wifiConnected: [.en: "Connected. Any network will do.", .zhHans: "已连接。任意 Wi-Fi 均可。", .zhHant: "已連線。任意 Wi-Fi 均可。"],
        .wifiMissing: [.en: "Not on Wi-Fi. Mounting needs it — cellular alone won't do.",
                       .zhHans: "当前不在 Wi-Fi 下。挂载需要 Wi-Fi——仅蜂窝网络不行。",
                       .zhHant: "目前不在 Wi-Fi 下。掛載需要 Wi-Fi——僅行動網路不行。"],
        .wifiFooter: [.en: "Any Wi-Fi network works. The tunnel runs over the local interface, which cellular doesn't provide.",
                      .zhHans: "任意 Wi-Fi 都可以。隧道走本地网络接口，蜂窝网络不提供这个。",
                      .zhHant: "任意 Wi-Fi 都可以。通道走本機網路介面，行動網路不提供這個。"],
        .notOnWiFi: [.en: "not connected to Wi-Fi", .zhHans: "未连接 Wi-Fi", .zhHant: "未連線 Wi-Fi"],
        .uploadingImage: [.en: "Uploading image…", .zhHans: "正在上传镜像…", .zhHant: "正在上傳映像…"],
        .mountIntro: [.en: "Mount the Developer Disk Image locally, on this device. iOS needs it before the automation runner can launch, and it does not survive a reboot.",
                      .zhHans: "在本机直接挂载开发者磁盘镜像。iOS 要求先有它，自动化 runner 才能启动；且它在重启后会丢失。",
                      .zhHant: "在本機直接掛載開發者磁碟映像。iOS 要求先有它，自動化 runner 才能啟動；且它在重新開機後會遺失。"],
        .localNetworkDeniedDetail: [.en: "The tunnel is blocked: Local Network access is off for LoopCtrl. Turn it on in Settings, then come back.",
                                    .zhHans: "隧道被拦截：LoopCtrl 的“本地网络”权限已关闭。请在设置中打开后再回来。",
                                    .zhHant: "通道被攔截：LoopCtrl 的「區域網路」權限已關閉。請在設定中開啟後再回來。"],
        .openSettings: [.en: "Open Settings", .zhHans: "打开设置", .zhHant: "開啟設定"],
        .interfacesSeen: [.en: "Addresses on this device:", .zhHans: "本机地址：", .zhHant: "本機位址："],
        .networkPermissionTitle: [.en: "Network access is off", .zhHans: "网络权限未开启", .zhHant: "網路權限未開啟"],
        .networkPermissionBody: [.en: "LoopCtrl can't work without: %@. Turn it on in Settings → LoopCtrl.",
                                 .zhHans: "LoopCtrl 需要以下权限才能工作：%@。请在 设置 → LoopCtrl 中打开。",
                                 .zhHant: "LoopCtrl 需要以下權限才能運作：%@。請在 設定 → LoopCtrl 中開啟。"],
        .networkDataPermission: [.en: "Wireless Data", .zhHans: "无线数据", .zhHant: "無線資料"],
        .localNetworkPermission: [.en: "Local Network", .zhHans: "本地网络", .zhHant: "區域網路"],
        .laterButton: [.en: "Later", .zhHans: "稍后", .zhHant: "稍後"],
        .authorizedClients: [.en: "Authorized Clients", .zhHans: "已授权客户端", .zhHant: "已授權用戶端"],
        .runnerLogs: [.en: "Runner Logs", .zhHans: "Runner 日志", .zhHant: "Runner 日誌"],
        .appLogsSection: [.en: "This App", .zhHans: "本 App", .zhHant: "本 App"],
        .runnerSection: [.en: "Runner", .zhHans: "Runner", .zhHant: "Runner"],
        .connectRunnerTitle: [.en: "Connect to the Runner", .zhHans: "连接 Runner", .zhHant: "連接 Runner"],
        .connectRunnerBody: [.en: "Managing clients and reading the runner's log need its approval once. Tap Connect, then long-press the LoopCtrl notification and choose Allow.",
                             .zhHans: "管理客户端和查看 Runner 日志需要 Runner 授权一次。点击“连接”，然后长按 LoopCtrl 通知并选择“允许”。",
                             .zhHant: "管理用戶端和查看 Runner 日誌需要 Runner 授權一次。點擊「連接」，然後長按 LoopCtrl 通知並選擇「允許」。"],
        .connectButton: [.en: "Connect", .zhHans: "连接", .zhHant: "連接"],
        .waitingApproval: [.en: "Waiting for Allow in the LoopCtrl notification…", .zhHans: "等待在 LoopCtrl 通知中允许…", .zhHant: "等待在 LoopCtrl 通知中允許…"],
        .runnerNotRunningHint: [.en: "The runner is not running. Start the server first.", .zhHans: "Runner 未运行，请先启动服务。", .zhHant: "Runner 未運行，請先啟動服務。"],
        .keyRejectedHint: [.en: "The runner no longer accepts this app (revoked or expired). Connect again.",
                           .zhHans: "Runner 已不再接受本 App（已吊销或过期），请重新连接。",
                           .zhHant: "Runner 已不再接受本 App（已撤銷或過期），請重新連接。"],
        .pairDeniedHint: [.en: "Not allowed, or no answer within 60 seconds.", .zhHans: "未被允许，或 60 秒内未响应。", .zhHant: "未被允許，或 60 秒內未回應。"],
        .retryInSeconds: [.en: "Try again in %d s.", .zhHans: "请 %d 秒后重试。", .zhHant: "請 %d 秒後重試。"],
        .thisApp: [.en: "This app", .zhHans: "本 App", .zhHant: "本 App"],
        .revokeButton: [.en: "Revoke", .zhHans: "吊销", .zhHant: "撤銷"],
        .revokeOthers: [.en: "Revoke All Others", .zhHans: "吊销其他全部", .zhHant: "撤銷其他全部"],
        .revokeConfirmTitle: [.en: "Revoke “%@”?", .zhHans: "吊销“%@”？", .zhHant: "撤銷「%@」？"],
        .revokeConfirmBody: [.en: "Its key stops working at once. To come back it must pair again, approved on this device.",
                             .zhHans: "其密钥立即失效。如需再次使用，必须重新配对并在本机允许。",
                             .zhHant: "其金鑰立即失效。如需再次使用，必須重新配對並在本機允許。"],
        .revokeOthersConfirm: [.en: "Revoke %d clients?", .zhHans: "吊销 %d 个客户端？", .zhHant: "撤銷 %d 個用戶端？"],
        .disconnectThisApp: [.en: "Disconnect This App", .zhHans: "断开本 App", .zhHant: "中斷本 App"],
        .disconnectConfirmBody: [.en: "This app's key is revoked. Viewing clients and logs again needs a new approval.",
                                 .zhHans: "本 App 的密钥将被吊销，再次查看客户端和日志需要重新允许。",
                                 .zhHant: "本 App 的金鑰將被撤銷，再次查看用戶端和日誌需要重新允許。"],
        .noClients: [.en: "No authorized clients.", .zhHans: "没有已授权的客户端。", .zhHant: "沒有已授權的用戶端。"],
        .pairedAt: [.en: "Paired %@", .zhHans: "授权于 %@", .zhHant: "授權於 %@"],
        .lastActive: [.en: "active %@", .zhHans: "最近活动 %@", .zhHant: "最近活動 %@"],
        .clientsFooter: [.en: "Computers, agents and browsers holding a key to this runner. Revoking takes effect immediately.",
                         .zhHans: "持有本 Runner 密钥的电脑、Agent 和浏览器。吊销立即生效。",
                         .zhHant: "持有本 Runner 金鑰的電腦、Agent 和瀏覽器。撤銷立即生效。"],
        .liveLabel: [.en: "Live", .zhHans: "实时", .zhHant: "即時"],
        .pausedLabel: [.en: "Paused", .zhHans: "已暂停", .zhHant: "已暫停"],
        .filterPlaceholder: [.en: "Filter", .zhHans: "筛选", .zhHant: "篩選"],
        .noLogLines: [.en: "No log lines.", .zhHans: "没有日志。", .zhHant: "沒有日誌。"],
        .copyButton: [.en: "Copy", .zhHans: "复制", .zhHant: "拷貝"],
        .runnerLogsCaption: [.en: "The runner's most recent 500 log lines, refreshed every 2 seconds while this screen is open.",
                            .zhHans: "Runner 最近 500 行日志，停留在本页时每 2 秒刷新一次。",
                            .zhHant: "Runner 最近 500 行日誌，停留在本頁時每 2 秒重新整理一次。"],
        .cancelButton: [.en: "Cancel", .zhHans: "取消", .zhHant: "取消"],
        .viaLocal: [.en: "This device / USB", .zhHans: "本机 / USB", .zhHant: "本機 / USB"],
        .viaLAN: [.en: "LAN", .zhHans: "局域网", .zhHant: "區域網路"],
        .viaNearby: [.en: "Nearby (AWDL)", .zhHans: "近场 (AWDL)", .zhHant: "近場 (AWDL)"],
        .viaVPN: [.en: "VPN", .zhHans: "VPN", .zhHant: "VPN"],
        .viaCellular: [.en: "Cellular", .zhHans: "蜂窝网络", .zhHant: "行動網路"],
        .viaOther: [.en: "Other", .zhHans: "其他", .zhHant: "其他"],
        .visibilityLabel: [.en: "Visibility", .zhHans: "可见性", .zhHant: "可見性"],
        .visibilityNearbyPending: [.en: "🟡 LAN · nearby not ready", .zhHans: "🟡 局域网 · 近场未就绪", .zhHant: "🟡 區域網路 · 近場未就緒"],
        .runnerLocalNetworkDenied: [.en: "⚠️ The runner has no Local Network access, so nearby discovery cannot work. Allow it in Settings › Privacy & Security › Local Network › LoopCtrlUITests-Runner.",
                                    .zhHans: "⚠️ Runner 没有本地网络权限，近场发现无法使用。请在 设置 › 隐私与安全 › 本地网络 中打开 LoopCtrlUITests-Runner。",
                                    .zhHant: "⚠️ Runner 沒有本地網路權限，近場探索無法使用。請在 設定 › 隱私權與安全性 › 本地網路 中開啟 LoopCtrlUITests-Runner。"],
        .visibilityLocal: [.en: "🟢 This device only · safe", .zhHans: "🟢 仅本机 · 安全", .zhHant: "🟢 僅本機 · 安全"],
        .visibilityLAN: [.en: "🟡 LAN", .zhHans: "🟡 局域网", .zhHant: "🟡 區域網路"],
        .visibilityLANNearby: [.en: "🟡 LAN + Nearby (AWDL)", .zhHans: "🟡 局域网 + 近场 (AWDL)", .zhHant: "🟡 區域網路 + 近場 (AWDL)"],
    ]
}
