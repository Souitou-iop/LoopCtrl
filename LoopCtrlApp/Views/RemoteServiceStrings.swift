import Foundation

/// Strings for the 远程服务 screens. Same approach as `L10n.ui`: an in-code
/// table, English fallback, Simplified and Traditional Chinese filled in.
extension L10n {
    enum Remote {
        case title, subtitleEmpty, addConnection, connect, disconnect, unbind, cancel, retry, done
        case connecting, reconnecting, connectingTo, disconnectedState, failedState
        case operating, operatingSince, latency, viaRelay
        // Add sheet
        case addTitle, pasteInvite, pasteFooter, scanQR, scanQRDetail, pickPhoto, pickPhotoDetail
        case manualEntry, serverAddress, connectionCode, continueButton, manualFooter
        case noQRInPhoto, cameraUnavailable, scanHint, demoSection, demoWithOperators, demoTextForm, mockScenario
        // Confirm
        case confirmTitle, httpsLock, pinnedLock, insecureDebug, providedByServer, operatorsSection
        case matchesInvite, checkFingerprint, checkFingerprintFooter, capabilitiesSection
        case relayPromise, relayPromiseUnverified, checking, mismatchTitle, mismatchBody
        case stepCreateKey, stepRedeem, stepOpenRelay, stepPreApprove, connectedDone
        case capViewScreen, capControl, capLaunchApps, capReadText, codeExpires
        // Detail
        case connectionsSection, server, organization, deviceID, operators, connectedFor, reconnects24h
        case controlPage, shareControlPage
        case recentLog, noLog, advanced, certificateSPKI, pinnedSPKI, spkiMatches, spkiDiffers, loadSPKI
        case preApproved, preApprovalPending, preApprovalPendingFooter, syncNow, notPreApproved
        case unbindConfirm, unbindBody, disconnectFooter, mockSection, mockFooter
        case simulateOperator, simulateOperatorEnd, simulateDrop, simulateServerClose
        case mockEnabled, mockDisabled, relayOperatorsSection, relayOperatorsFooter
        case more, selectConnections, selectAll, deselectAll, selectedCount, disconnectAll, unbindAll
        case unbindManyConfirm, unbindManyBody
        // Errors
        case errInvalidCode, errExpiredCode, errCredential, errMismatch, errTLS, errPin, errUnreachable, errServerClosed, errResponse
        case parseNotInvite, parseVersion, parseMissingServer, parseInvalidServer, parseInsecure
        case parseMissingCode, parseInvalidCode, parseInvalidOperator, parseInvalidPin, parseExpired
        // Log
        case logEnrolled, logConnected, logReconnected, logDisconnected, logOperatorStarted, logOperatorEnded
        // Mock data
        case mockOrganization, mockOperatorA, mockOperatorB
        case mockActionScreen, mockActionLaunch, mockActionTap, mockActionType
    }

    static func rs(_ key: Remote) -> String {
        let row = remoteTable[key] ?? [:]
        return row[lang] ?? row[.en] ?? ""
    }

    private static let remoteTable: [Remote: [Lang: String]] = [
        .title: [.en: "Remote Service", .zhHans: "远程服务", .zhHant: "遠端服務"],
        .subtitleEmpty: [.en: "Connect to a service provider or your own server",
                         .zhHans: "连接到服务提供商或自建服务器",
                         .zhHant: "連線到服務供應商或自架伺服器"],
        .addConnection: [.en: "Add Connection", .zhHans: "添加连接", .zhHant: "新增連線"],
        .connect: [.en: "Connect", .zhHans: "连接", .zhHant: "連線"],
        .disconnect: [.en: "Disconnect", .zhHans: "断开", .zhHant: "中斷連線"],
        .unbind: [.en: "Unbind", .zhHans: "解除绑定", .zhHant: "解除綁定"],
        .cancel: [.en: "Cancel", .zhHans: "取消", .zhHant: "取消"],
        .retry: [.en: "Try Again", .zhHans: "重试", .zhHant: "重試"],
        .done: [.en: "Done", .zhHans: "完成", .zhHant: "完成"],
        .connecting: [.en: "Connecting…", .zhHans: "正在连接…", .zhHant: "正在連線…"],
        .reconnecting: [.en: "Reconnecting (attempt %d)…", .zhHans: "正在重新连接（第 %d 次）…", .zhHant: "正在重新連線（第 %d 次）…"],
        .connectingTo: [.en: "Connecting to %@", .zhHans: "正在连接 %@", .zhHant: "正在連線 %@"],
        .disconnectedState: [.en: "Disconnected", .zhHans: "已断开", .zhHant: "已中斷"],
        .failedState: [.en: "Connection failed", .zhHans: "连接失败", .zhHant: "連線失敗"],
        .operating: [.en: "%@ is operating", .zhHans: "%@ 正在操作", .zhHant: "%@ 正在操作"],
        .operatingSince: [.en: "Since %@", .zhHans: "开始于 %@", .zhHant: "開始於 %@"],
        .latency: [.en: "%d ms", .zhHans: "%d 毫秒", .zhHant: "%d 毫秒"],
        .viaRelay: [.en: "Relay", .zhHans: "中继", .zhHant: "中繼"],

        .addTitle: [.en: "Add Connection", .zhHans: "添加连接", .zhHant: "新增連線"],
        .pasteInvite: [.en: "Paste Connection Invite", .zhHans: "粘贴连接邀请", .zhHant: "貼上連線邀請"],
        .pasteFooter: [.en: "Copy the invite link or text your provider sent, then tap Paste.",
                       .zhHans: "复制服务商发来的邀请链接或文字，再点「粘贴」。",
                       .zhHant: "拷貝服務商傳來的邀請連結或文字，再點「貼上」。"],
        .scanQR: [.en: "Scan QR Code", .zhHans: "扫描二维码", .zhHant: "掃描 QR 碼"],
        .scanQRDetail: [.en: "Shown on your provider's page or on another screen",
                        .zhHans: "服务商页面或另一块屏幕上显示的二维码",
                        .zhHant: "服務商頁面或另一個螢幕上顯示的 QR 碼"],
        .pickPhoto: [.en: "Choose QR Code from Photos", .zhHans: "从相册选择二维码", .zhHant: "從相簿選擇 QR 碼"],
        .pickPhotoDetail: [.en: "A screenshot or a saved picture of the invite",
                           .zhHans: "邀请的截图或保存的图片",
                           .zhHant: "邀請的截圖或儲存的圖片"],
        .manualEntry: [.en: "Enter Manually", .zhHans: "手动输入", .zhHant: "手動輸入"],
        .serverAddress: [.en: "Server address", .zhHans: "服务器地址", .zhHant: "伺服器位址"],
        .connectionCode: [.en: "Connection code", .zhHans: "连接码", .zhHant: "連線碼"],
        .continueButton: [.en: "Continue", .zhHans: "继续", .zhHant: "繼續"],
        .manualFooter: [.en: "Without a link the app can't check the operators for you: compare their fingerprints on the next screen.",
                        .zhHans: "手动输入时 App 无法替你核对操作员，下一步请自行核对操作员指纹。",
                        .zhHant: "手動輸入時 App 無法替你核對操作員，下一步請自行核對操作員指紋。"],
        .noQRInPhoto: [.en: "No QR code found in that picture.", .zhHans: "这张图片里没有找到二维码。", .zhHant: "這張圖片裡沒有找到 QR 碼。"],
        .cameraUnavailable: [.en: "The camera isn't available on this device. Choose the QR code from Photos or paste the invite instead.",
                             .zhHans: "此设备无法使用相机。请从相册选择二维码，或粘贴邀请。",
                             .zhHant: "此裝置無法使用相機。請從相簿選擇 QR 碼，或貼上邀請。"],
        .scanHint: [.en: "Point the camera at the invite's QR code", .zhHans: "将相机对准邀请二维码", .zhHant: "將相機對準邀請 QR 碼"],
        .demoSection: [.en: "Demo (mock data)", .zhHans: "演示（模拟数据）", .zhHant: "示範（模擬資料）"],
        .demoWithOperators: [.en: "Demo invite link (with operator)", .zhHans: "演示邀请链接（含操作员）", .zhHant: "示範邀請連結（含操作員）"],
        .demoTextForm: [.en: "Demo invite text (no operator)", .zhHans: "演示邀请文字（无操作员）", .zhHant: "示範邀請文字（無操作員）"],
        .mockScenario: [.en: "Mock outcome", .zhHans: "模拟结果", .zhHant: "模擬結果"],

        .confirmTitle: [.en: "Confirm Connection", .zhHans: "确认连接", .zhHant: "確認連線"],
        .httpsLock: [.en: "Encrypted connection (HTTPS)", .zhHans: "加密连接（HTTPS）", .zhHant: "加密連線（HTTPS）"],
        .pinnedLock: [.en: "Certificate pinned by the invite", .zhHans: "证书已由邀请固定", .zhHant: "憑證已由邀請固定"],
        .insecureDebug: [.en: "Not encrypted (debug, loopback only)", .zhHans: "未加密（调试，仅本机回环）", .zhHant: "未加密（除錯，僅本機回送）"],
        .providedByServer: [.en: "Provided by the server", .zhHans: "由服务器提供", .zhHant: "由伺服器提供"],
        .operatorsSection: [.en: "Operators", .zhHans: "操作员", .zhHant: "操作員"],
        .matchesInvite: [.en: "Matches the invite", .zhHans: "与邀请一致", .zhHant: "與邀請一致"],
        .checkFingerprint: [.en: "Check the operator fingerprint", .zhHans: "请核对操作员指纹", .zhHant: "請核對操作員指紋"],
        .checkFingerprintFooter: [.en: "This invite didn't name its operators, so the app couldn't check them. Compare each fingerprint with what your provider shows. Nobody is pre-approved: the first time an operator connects, this phone asks you.",
                                  .zhHans: "这份邀请没有附带操作员，App 无法替你核对。请把每个指纹与服务商提供的对照。不会预先授权任何人：操作员第一次连接时，手机会请你批准。",
                                  .zhHant: "這份邀請沒有附帶操作員，App 無法替你核對。請把每個指紋與服務商提供的對照。不會預先授權任何人：操作員第一次連線時，手機會請你批准。"],
        .capabilitiesSection: [.en: "The operator will be able to", .zhHans: "操作员将可以", .zhHant: "操作員將可以"],
        .relayPromise: [.en: "The server only forwards traffic and can't see what is done; only the operator above can control this phone.",
                        .zhHans: "服务器只负责转发，看不到你的操作内容；只有上面这位操作员能控制这台手机",
                        .zhHant: "伺服器只負責轉送，看不到你的操作內容；只有上面這位操作員能控制這支手機"],
        .relayPromiseUnverified: [.en: "The server only forwards traffic and can't see what is done; each operator needs your approval on this phone before controlling it.",
                                  .zhHans: "服务器只负责转发，看不到你的操作内容；每位操作员都要先经你在手机上批准，才能控制这台手机",
                                  .zhHant: "伺服器只負責轉送，看不到你的操作內容；每位操作員都要先經你在手機上批准，才能控制這支手機"],
        .checking: [.en: "Checking the invite with the server…", .zhHans: "正在向服务器核对邀请…", .zhHant: "正在向伺服器核對邀請…"],
        .mismatchTitle: [.en: "Connection refused", .zhHans: "已拒绝连接", .zhHant: "已拒絕連線"],
        .mismatchBody: [.en: "The operators the server returned don't match the invite. Someone may be trying to take over this phone. Ask your provider for a new invite.",
                        .zhHans: "服务器返回的操作员与邀请不一致，可能有人试图接管这台手机。请向服务商索取新的邀请。",
                        .zhHant: "伺服器回傳的操作員與邀請不一致，可能有人試圖接管這支手機。請向服務商索取新的邀請。"],
        .stepCreateKey: [.en: "Create this phone's key", .zhHans: "生成本机密钥", .zhHant: "產生本機金鑰"],
        .stepRedeem: [.en: "Redeem the connection code", .zhHans: "兑换连接码", .zhHant: "兌換連線碼"],
        .stepOpenRelay: [.en: "Open the relay", .zhHans: "建立中继通道", .zhHant: "建立中繼通道"],
        .stepPreApprove: [.en: "Pre-approve the invite's operators", .zhHans: "预先授权邀请中的操作员", .zhHant: "預先授權邀請中的操作員"],
        .connectedDone: [.en: "Connected", .zhHans: "已连接", .zhHant: "已連線"],
        .capViewScreen: [.en: "See the screen", .zhHans: "查看屏幕画面", .zhHant: "查看螢幕畫面"],
        .capControl: [.en: "Tap, swipe and type", .zhHans: "点击、滑动和输入文字", .zhHant: "點擊、滑動和輸入文字"],
        .capLaunchApps: [.en: "Open apps and links", .zhHans: "打开 App 和链接", .zhHant: "開啟 App 和連結"],
        .capReadText: [.en: "Read text on screen", .zhHans: "读取屏幕上的文字", .zhHant: "讀取螢幕上的文字"],
        .codeExpires: [.en: "Code %@ · expires %@", .zhHans: "连接码 %@ · %@过期", .zhHant: "連線碼 %@ · %@過期"],

        .connectionsSection: [.en: "Connections", .zhHans: "连接", .zhHant: "連線"],
        .server: [.en: "Server", .zhHans: "服务器", .zhHant: "伺服器"],
        .organization: [.en: "Organization", .zhHans: "组织", .zhHant: "組織"],
        .deviceID: [.en: "Device ID", .zhHans: "设备 ID", .zhHant: "裝置 ID"],
        .controlPage: [.en: "Control page", .zhHans: "网页控制", .zhHant: "網頁控制"],
        .shareControlPage: [.en: "Share", .zhHans: "分享", .zhHant: "分享"],
        .operators: [.en: "Authorized Operators", .zhHans: "已授权操作员", .zhHant: "已授權操作員"],
        .connectedFor: [.en: "Connected for", .zhHans: "已连接时长", .zhHant: "已連線時長"],
        .reconnects24h: [.en: "Reconnects (24 h)", .zhHans: "24 小时内重连", .zhHant: "24 小時內重連"],
        .recentLog: [.en: "Recent Activity", .zhHans: "最近操作记录", .zhHant: "最近操作記錄"],
        .noLog: [.en: "Nothing yet", .zhHans: "暂无记录", .zhHant: "暫無記錄"],
        .advanced: [.en: "Advanced", .zhHans: "高级", .zhHant: "進階"],
        .certificateSPKI: [.en: "Current certificate (SPKI SHA-256)", .zhHans: "当前证书（SPKI SHA-256）", .zhHant: "目前憑證（SPKI SHA-256）"],
        .pinnedSPKI: [.en: "Pinned", .zhHans: "已固定", .zhHant: "已固定"],
        .spkiMatches: [.en: "Matches the pinned certificate", .zhHans: "与固定的证书一致", .zhHant: "與固定的憑證一致"],
        .spkiDiffers: [.en: "Differs from the pinned certificate", .zhHans: "与固定的证书不一致", .zhHant: "與固定的憑證不一致"],
        .loadSPKI: [.en: "Show Current Certificate", .zhHans: "显示当前证书", .zhHant: "顯示目前憑證"],
        .preApproved: [.en: "Pre-approved", .zhHans: "已预先授权", .zhHant: "已預先授權"],
        .preApprovalPending: [.en: "Waiting for the service", .zhHans: "等待服务启动", .zhHant: "等待服務啟動"],
        .preApprovalPendingFooter: [.en: "The pre-approval reaches the service once it is running. Until then these operators would be asked about like anyone else.",
                                    .zhHans: "服务运行后才会收到预先授权。在此之前，这些操作员会像其他人一样需要你批准。",
                                    .zhHant: "服務執行後才會收到預先授權。在此之前，這些操作員會像其他人一樣需要你批准。"],
        .syncNow: [.en: "Send to Service Now", .zhHans: "立即同步到服务", .zhHant: "立即同步到服務"],
        .notPreApproved: [.en: "Asks on first use", .zhHans: "首次需批准", .zhHant: "首次需批准"],
        .unbindConfirm: [.en: "Unbind this connection?", .zhHans: "解除绑定此连接？", .zhHant: "解除綁定此連線？"],
        .unbindBody: [.en: "This phone's key for %@ is deleted, its operators lose their pre-approval and their keys are revoked, and the server is told. You'll need a new invite to connect again.",
                      .zhHans: "将删除本机在 %@ 的密钥、撤销操作员的预先授权并吊销其密钥，同时通知服务器。之后需要新的邀请才能再连接。",
                      .zhHant: "將刪除本機在 %@ 的金鑰、撤銷操作員的預先授權並撤銷其金鑰，同時通知伺服器。之後需要新的邀請才能再連線。"],
        .disconnectFooter: [.en: "Disconnect keeps this phone's key, so it can connect again without an invite. Unbind deletes it.",
                            .zhHans: "「断开」会保留本机密钥，之后无需邀请即可重新连接；「解除绑定」会删除密钥。",
                            .zhHant: "「中斷連線」會保留本機金鑰，之後無需邀請即可重新連線；「解除綁定」會刪除金鑰。"],
        .mockSection: [.en: "Mock Relay", .zhHans: "模拟中继", .zhHant: "模擬中繼"],
        .mockFooter: [.en: "Mock data: no real server is contacted. The outcome applies to the next invite.",
                      .zhHans: "模拟数据：不会连接真实服务器。「模拟结果」作用于下一次添加连接。",
                      .zhHant: "模擬資料：不會連線真實伺服器。「模擬結果」作用於下一次新增連線。"],
        .simulateOperator: [.en: "Operator Starts", .zhHans: "模拟操作员开始操作", .zhHant: "模擬操作員開始操作"],
        .simulateOperatorEnd: [.en: "Operator Stops", .zhHans: "模拟操作员结束操作", .zhHant: "模擬操作員結束操作"],
        .simulateDrop: [.en: "Network Drop", .zhHans: "模拟网络中断后重连", .zhHant: "模擬網路中斷後重連"],
        .simulateServerClose: [.en: "Server Disconnects", .zhHans: "模拟服务器断开", .zhHant: "模擬伺服器中斷"],
        .mockEnabled: [.en: "Mock relay on", .zhHans: "已开启模拟中继", .zhHant: "已開啟模擬中繼"],
        .mockDisabled: [.en: "Mock relay off", .zhHans: "已关闭模拟中继", .zhHant: "已關閉模擬中繼"],
        .relayOperatorsSection: [.en: "Pre-approved via Remote Service", .zhHans: "远程服务预先授权", .zhHant: "遠端服務預先授權"],
        .relayOperatorsFooter: [.en: "These operators pair through the relay without a prompt, with exactly these keys. Any other key, or these keys from elsewhere, still needs your approval.",
                                .zhHans: "这些操作员通过中继、且使用与此完全一致的密钥时可直接配对。其他密钥，或同一密钥从别处连接，仍需你批准。",
                                .zhHant: "這些操作員透過中繼、且使用與此完全一致的金鑰時可直接配對。其他金鑰，或同一金鑰從別處連線，仍需你批准。"],

        .more: [.en: "More", .zhHans: "更多", .zhHant: "更多"],
        .selectConnections: [.en: "Select Connections", .zhHans: "选择连接", .zhHant: "選擇連線"],
        .selectAll: [.en: "Select All", .zhHans: "全选", .zhHant: "全選"],
        .deselectAll: [.en: "Deselect All", .zhHans: "取消全选", .zhHant: "取消全選"],
        .selectedCount: [.en: "%d Selected", .zhHans: "已选择 %d 项", .zhHant: "已選擇 %d 項"],
        .disconnectAll: [.en: "Disconnect All", .zhHans: "全部断开", .zhHant: "全部中斷"],
        .unbindAll: [.en: "Unbind All", .zhHans: "全部解除绑定", .zhHant: "全部解除綁定"],
        .unbindManyConfirm: [.en: "Unbind %d connections?", .zhHans: "解除绑定 %d 个连接？", .zhHant: "解除綁定 %d 個連線？"],
        .unbindManyBody: [.en: "This phone's keys for them are deleted, their operators lose their pre-approval and their keys are revoked, and each server is told. You'll need new invites to connect again.",
                          .zhHans: "将删除本机在这些服务器上的密钥、撤销其操作员的预先授权并吊销其密钥，同时通知各服务器。之后需要新的邀请才能再连接。",
                          .zhHant: "將刪除本機在這些伺服器上的金鑰、撤銷其操作員的預先授權並撤銷其金鑰，同時通知各伺服器。之後需要新的邀請才能再連線。"],
        .errInvalidCode: [.en: "The connection code isn't valid. Check it, or ask for a new invite.",
                          .zhHans: "连接码无效。请检查，或索取新的邀请。",
                          .zhHant: "連線碼無效。請檢查，或索取新的邀請。"],
        .errExpiredCode: [.en: "This invite has expired or was already used. Ask for a new one.",
                          .zhHans: "这份邀请已过期或已被使用，请索取新的邀请。",
                          .zhHant: "這份邀請已過期或已被使用，請索取新的邀請。"],
        .errMismatch: [.en: "The server's operators don't match the invite. Connection refused.",
                       .zhHans: "服务器返回的操作员与邀请不一致，已拒绝连接。",
                       .zhHant: "伺服器回傳的操作員與邀請不一致，已拒絕連線。"],
        .errTLS: [.en: "The server's certificate couldn't be verified (TLS).",
                  .zhHans: "无法验证服务器证书（TLS 错误）。",
                  .zhHant: "無法驗證伺服器憑證（TLS 錯誤）。"],
        .errPin: [.en: "The server's certificate doesn't match the one pinned in the invite.",
                  .zhHans: "服务器证书与邀请中固定的证书不一致。",
                  .zhHant: "伺服器憑證與邀請中固定的憑證不一致。"],
        .errUnreachable: [.en: "Can't reach the server. Check the address and your network.",
                          .zhHans: "无法连接服务器，请检查地址和网络。",
                          .zhHant: "無法連線伺服器，請檢查位址和網路。"],
        .errCredential: [.en: "This phone's key for this connection is missing. Unbind it and add it again with a new invite.",
                         .zhHans: "本机在此连接的密钥已丢失。请解除绑定，再用新的邀请重新添加。",
                         .zhHant: "本機在此連線的金鑰已遺失。請解除綁定，再用新的邀請重新新增。"],
        .errServerClosed: [.en: "The server ended the connection.", .zhHans: "服务器断开了连接。", .zhHant: "伺服器中斷了連線。"],
        .errResponse: [.en: "The server sent something unexpected.", .zhHans: "服务器返回了无法识别的内容。", .zhHant: "伺服器回傳了無法辨識的內容。"],
        .parseNotInvite: [.en: "That isn't a LoopCtrl connection invite.", .zhHans: "这不是 LoopCtrl 连接邀请。", .zhHant: "這不是 LoopCtrl 連線邀請。"],
        .parseVersion: [.en: "This invite needs a newer version of LoopCtrl.", .zhHans: "这份邀请需要更新版本的 LoopCtrl。", .zhHant: "這份邀請需要更新版本的 LoopCtrl。"],
        .parseMissingServer: [.en: "The invite has no server address.", .zhHans: "邀请中缺少服务器地址。", .zhHant: "邀請中缺少伺服器位址。"],
        .parseInvalidServer: [.en: "The server address isn't valid.", .zhHans: "服务器地址无效。", .zhHant: "伺服器位址無效。"],
        .parseInsecure: [.en: "Only HTTPS servers are allowed.", .zhHans: "只允许 HTTPS 服务器。", .zhHant: "只允許 HTTPS 伺服器。"],
        .parseMissingCode: [.en: "The invite has no connection code.", .zhHans: "邀请中缺少连接码。", .zhHant: "邀請中缺少連線碼。"],
        .parseInvalidCode: [.en: "A connection code is 8 letters and digits, like 7K3M-9QX2.",
                            .zhHans: "连接码由 8 位字母和数字组成，例如 7K3M-9QX2。",
                            .zhHant: "連線碼由 8 位字母和數字組成，例如 7K3M-9QX2。"],
        .parseInvalidOperator: [.en: "An operator fingerprint in the invite is malformed.", .zhHans: "邀请中的操作员指纹格式不正确。", .zhHant: "邀請中的操作員指紋格式不正確。"],
        .parseInvalidPin: [.en: "The certificate pin in the invite is malformed.", .zhHans: "邀请中的证书固定值格式不正确。", .zhHant: "邀請中的憑證固定值格式不正確。"],
        .parseExpired: [.en: "This invite has expired. Ask for a new one.", .zhHans: "这份邀请已过期，请索取新的邀请。", .zhHant: "這份邀請已過期，請索取新的邀請。"],

        .logEnrolled: [.en: "Bound to %@", .zhHans: "已绑定 %@", .zhHant: "已綁定 %@"],
        .logConnected: [.en: "Connected", .zhHans: "已连接", .zhHant: "已連線"],
        .logReconnected: [.en: "Reconnected", .zhHans: "已重新连接", .zhHant: "已重新連線"],
        .logDisconnected: [.en: "Disconnected", .zhHans: "已断开", .zhHant: "已中斷"],
        .logOperatorStarted: [.en: "%@ started operating", .zhHans: "%@ 开始操作", .zhHant: "%@ 開始操作"],
        .logOperatorEnded: [.en: "%@ stopped operating", .zhHans: "%@ 结束操作", .zhHant: "%@ 結束操作"],

        .mockOrganization: [.en: "Demo Provider (mock)", .zhHans: "演示服务商（模拟）", .zhHant: "示範服務商（模擬）"],
        .mockOperatorA: [.en: "Alex Chen", .zhHans: "陈工", .zhHant: "陳工"],
        .mockOperatorB: [.en: "Sam Li", .zhHans: "李工", .zhHant: "李工"],
        .mockActionScreen: [.en: "Viewed the screen", .zhHans: "查看了屏幕", .zhHant: "查看了螢幕"],
        .mockActionLaunch: [.en: "Opened Settings", .zhHans: "打开了「设置」", .zhHant: "開啟了「設定」"],
        .mockActionTap: [.en: "Tapped (196, 512)", .zhHans: "点击 (196, 512)", .zhHant: "點擊 (196, 512)"],
        .mockActionType: [.en: "Typed 6 characters", .zhHans: "输入了 6 个字符", .zhHant: "輸入了 6 個字元"],
    ]
}

/// Messages for the remote service's errors.
enum RemoteServiceText {
    static func error(_ error: RemoteServiceError) -> String {
        switch error {
        case .invalidCode: return L10n.rs(.errInvalidCode)
        case .expiredCode: return L10n.rs(.errExpiredCode)
        case .fingerprintMismatch: return L10n.rs(.errMismatch)
        case .tlsFailure: return L10n.rs(.errTLS)
        case .pinMismatch: return L10n.rs(.errPin)
        case .serverUnreachable: return L10n.rs(.errUnreachable)
        case .disconnectedByServer: return L10n.rs(.errServerClosed)
        case .invalidResponse: return L10n.rs(.errResponse)
        case .credentialMissing: return L10n.rs(.errCredential)
        }
    }

    static func parse(_ error: RemoteInvite.ParseError) -> String {
        switch error {
        case .notAnInvite: return L10n.rs(.parseNotInvite)
        case .unsupportedVersion: return L10n.rs(.parseVersion)
        case .missingServer: return L10n.rs(.parseMissingServer)
        case .invalidServer: return L10n.rs(.parseInvalidServer)
        case .insecureServer: return L10n.rs(.parseInsecure)
        case .missingCode: return L10n.rs(.parseMissingCode)
        case .invalidCode: return L10n.rs(.parseInvalidCode)
        case .invalidOperator: return L10n.rs(.parseInvalidOperator)
        case .invalidPin: return L10n.rs(.parseInvalidPin)
        case .expired: return L10n.rs(.parseExpired)
        }
    }

    static func capability(_ raw: String) -> (String, String)? {
        switch RemoteCapability(rawValue: raw) {
        case .viewScreen: return (L10n.rs(.capViewScreen), "eye")
        case .control: return (L10n.rs(.capControl), "hand.tap")
        case .launchApps: return (L10n.rs(.capLaunchApps), "square.grid.2x2")
        case .readText: return (L10n.rs(.capReadText), "text.viewfinder")
        case nil: return nil
        }
    }

    static func scenario(_ s: MockRemoteServiceClient.Scenario) -> String {
        switch s {
        case .success: return lang("Success", "成功", "成功")
        case .invalidCode: return lang("Invalid code", "连接码无效", "連線碼無效")
        case .expiredCode: return lang("Expired code", "连接码过期", "連線碼過期")
        case .fingerprintMismatch: return lang("Fingerprint mismatch", "指纹不一致", "指紋不一致")
        case .tlsFailure: return lang("TLS failure", "TLS 失败", "TLS 失敗")
        case .pinMismatch: return lang("Pin mismatch", "证书固定不一致", "憑證固定不一致")
        case .serverUnreachable: return lang("Server unreachable", "服务器不可达", "伺服器無法連線")
        case .disconnectedByServer: return lang("Server disconnects", "服务器主动断开", "伺服器主動中斷")
        }
    }

    /// The app ships no .lproj, so formatters would fall back to English:
    /// give them the language the in-code tables picked.
    static var locale: Locale {
        switch L10n.lang {
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .zhHant: return Locale(identifier: "zh-Hant")
        default: return Locale(identifier: "en")
        }
    }

    private static func lang(_ en: String, _ hans: String, _ hant: String) -> String {
        switch L10n.lang {
        case .zhHans: return hans
        case .zhHant: return hant
        default: return en
        }
    }
}
