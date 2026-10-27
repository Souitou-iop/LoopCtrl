import XCTest
import UserNotifications
import UIKit
import Network

final class LoopCtrlUITests: XCTestCase, UNUserNotificationCenterDelegate {
    private var server: JSONRPCServer?
    private var app: XCUIApplication!
    private var actionHandler: ActionHandler?
    private var pendingAuthCompletions: [String: (Bool) -> Void] = [:]
    /// Notification id of the pairing request awaiting an answer (at most one).
    private var currentAuthRequestID: String?
    private let authLock = NSLock()

    static let authCategoryID = "AUTH_REQUEST"
    static let allowActionID = "AUTH_ALLOW"
    static let denyActionID = "AUTH_DENY"

    static let serverReadyCategoryID = "SERVER_READY"
    static let serverRemoteCategoryID = "SERVER_REMOTE"
    static let serverNearbyCategoryID = "SERVER_NEARBY"
    static let serverStoppedCategoryID = "SERVER_STOPPED"
    static let enableRemoteActionID = "ENABLE_REMOTE"
    static let disableRemoteActionID = "DISABLE_REMOTE"
    static let enableNearbyActionID = "ENABLE_NEARBY"
    static let disableNearbyActionID = "DISABLE_NEARBY"
    static let stopServerActionID = "STOP_SERVER"
    static let copyLogsActionID = "COPY_LOGS"
    /// Remote viewing/control in progress, and paused by the owner.
    static let remoteCategoryID = "REMOTE_SESSION"
    static let remotePausedCategoryID = "REMOTE_PAUSED"
    static let pauseRemoteActionID = "REMOTE_PAUSE"
    static let resumeRemoteActionID = "REMOTE_RESUME"
    static let remoteNotificationID = "loopctrl.remote"

    static let logBuffer = LogBuffer(capacity: 1000)
    /// Longest one accessibility message to an app may take (see setAXTimeout).
    static let axTimeoutSeconds = 5.0

    /// Persisted preference key. Defaults to false (localhost-only) on a fresh install.
    static let allowRemoteAccessKey = "allowRemoteAccess"

    private var remoteAccessEnabled = false
    private var keepRunning = true
    /// All-in-one: Start is re-enabling Automation Mode (restartParkedService).
    private var reacquiringAutomation = false

    /// Reads the persisted remote-access preference. Absent key → false (local only).
    private static var persistedRemoteAccess: Bool {
        get { UserDefaults.standard.bool(forKey: allowRemoteAccessKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowRemoteAccessKey) }
    }

    /// Nearby discovery (peer-to-peer advertising). Only meaningful while
    /// remote access is on; turning remote access off turns it off too.
    static let nearbyDiscoveryKey = "nearbyDiscovery"
    private static var persistedNearby: Bool {
        get { UserDefaults.standard.bool(forKey: nearbyDiscoveryKey) }
        set { UserDefaults.standard.set(newValue, forKey: nearbyDiscoveryKey) }
    }
    private var nearbyEnabled = false

    /// Persisted listen port, as chosen in the LoopCtrl app (ServerPort).
    private static var persistedPort: UInt16 {
        get { ServerPort.stored }
        set { ServerPort.stored = newValue }
    }

    override func setUpWithError() throws {
        // Signal the bootstrap watchdog that XCTest actually reached the test —
        // so it never re-kicks runTestsInBackground: (which would re-enter XCTest
        // and crash). Only a bootstrap that never reaches setUp gets recovered.
        EarlyURLHook.markSetUpEntered()
        Self.logBuffer.append("🧩 setUpWithError begin")
        Self.observeAppLifecycle()
        _ = NetworkTypeMonitor.shared  // start network-type monitoring early
        // Make the test "failure-proof" — like WebDriverAgent's FBFailureProofTestCase.
        // A hung/slow XCUITest call (tap/snapshot on an animating page) makes XCTest
        // record a failure and tear the test down, which kills the server. We keep
        // running through failures and swallow the failure reporting so XCTest never
        // decides to stop the long-running server test.
        continueAfterFailure = true
        // Don't halt when XCTest signals control interruptions (see appium#13949).
        if responds(to: Selector(("setShouldSetShouldHaltWhenReceivesControl:"))) {
            setValue(false, forKey: "shouldSetShouldHaltWhenReceivesControl")
        }
        if responds(to: Selector(("setShouldHaltWhenReceivesControl:"))) {
            setValue(false, forKey: "shouldHaltWhenReceivesControl")
        }

        // Construct the app reference but DO NOT activate() here. WebDriverAgent's
        // setUp never touches XCUIApplication. If the device is on the lock/passcode
        // screen (first launch after a URL wake), activate() blocks waiting for
        // SpringBoard to reach a foreground/quiescent state it can't reach behind
        // the passcode UI — which stalls setUp and the runner exits silently. We
        // only hold the reference; the first real action reads app.frame lazily
        // (well after unlock).
        app = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        URLSchemeHandler.installURLHandler()
        setupNotifications()
        Self.logBuffer.append("🧩 setUpWithError done (no app.activate)")
    }

    /// JPEG quality asked of the capture side. Appium/WDA ship 0.25 by default
    /// and it is visually fine for a control stream, so the bandwidth and the
    /// decode both stay small.
    private static let captureJPEGQuality = 0.25
    /// nil = not probed yet, false = unavailable on this OS, true = usable.
    private static var jpegCaptureAvailable: Bool?
    /// Asking testmanagerd directly (see ObjCException.daemonScreenshot)
    /// instead of going through XCUIScreen. nil = not tried, true = working;
    /// off after `daemonCaptureMaxFailures` failures in a row.
    private static var daemonCaptureWorks: Bool?
    private static var daemonCaptureFailures = 0
    private static let daemonCaptureMaxFailures = 3

    /// Capture a frame that the system compressed for us, or nil if this OS
    /// doesn't expose the private encoding-aware capture path.
    ///
    /// Every step is probed: the selectors are private, and a wrong assumption
    /// here is a launch-time crash rather than a slow stream.
    private static func grabJPEGFrame(quality: Double = captureJPEGQuality) -> (image: UIImage, jpeg: Data)? {
        if jpegCaptureAvailable == false { return nil }

        // These selectors were read out of a current Xcode SDK; an older OS
        // (iOS 16 shipped in 2022) may not have them, or may have them with a
        // different shape. `responds(to:)` covers "missing", but a mismatched
        // implementation raises an NSException, which `try?` does NOT catch —
        // it would abort the runner. So the whole probe runs inside an ObjC
        // @try, and any failure disables this path permanently.
        var result: (image: UIImage, jpeg: Data)?
        var sizeKB = 0
        var failStep = "unknown"
        let raised = ObjCException.catching {
            // Stepwise so the log names the exact link that failed — a single
            // guard chain only ever reports "not supported", which is useless
            // when the point is to find out which private API is missing.
            let screen = XCUIScreen.main
            let initSel = Selector(("initWithUniformTypeIdentifier:compressionQuality:"))
            let newShape = screen.responds(to: Selector(("screenshotWithPreferredEncoding:rect:error:")))
            guard newShape || screen.responds(to: Selector(("screenshotWithPreferredEncoding:rect:options:error:"))) else {
                failStep = "XCUIScreen lacks screenshotWithPreferredEncoding:rect:(options:)error:"; return
            }
            guard let encodingClass = NSClassFromString("XCTImageEncoding") as? NSObject.Type else {
                failStep = "XCTImageEncoding class not found"; return
            }
            guard encodingClass.instancesRespond(to: initSel) else {
                failStep = "XCTImageEncoding lacks initWithUniformTypeIdentifier:compressionQuality:"; return
            }
            var diag: NSString?
            guard let encoding = ObjCException.makeImageEncoding(encodingClass,
                                                                 uti: "public.jpeg",
                                                                 quality: quality,
                                                                 diagnosis: &diag) else {
                failStep = "makeImageEncoding returned nil [\(diag ?? "no diagnosis")]"; return
            }
            _ = newShape
            // The direct request first: same capture, a fraction of the time.
            if daemonCaptureWorks != false {
                var why: NSString?
                if let data = ObjCException.daemonScreenshot(withEncoding: encoding, timeout: 2, why: &why),
                   let img = UIImage(data: data), img.cgImage != nil {
                    if daemonCaptureWorks == nil {
                        logBuffer.append("📷 direct testmanagerd capture active (\(data.count / 1024) KB/frame)")
                    }
                    daemonCaptureWorks = true
                    daemonCaptureFailures = 0
                    result = (img, data)
                    sizeKB = data.count / 1024
                    return
                }
                daemonCaptureFailures += 1
                if daemonCaptureWorks == nil || daemonCaptureFailures >= daemonCaptureMaxFailures {
                    daemonCaptureWorks = false
                    logBuffer.append("📷 direct testmanagerd capture off: \(why ?? "no image") — using XCUIScreen")
                }
            }
            // Through objc_msgSend, not a Swift protocol cast: on Xcode 27 the
            // encoding object no longer bridges to XCTImageEncoding, so the
            // cast failed and every frame took the slow bitmap path.
            let raw = ObjCException.screenshot(of: screen, encoding: encoding)
            // Xcode 27 returns the XCTImage itself; older SDKs wrap it in an
            // XCUIScreenshot.
            let xctImageAny: AnyObject?
            if let shot = raw as? XCUIScreenshot, shot.responds(to: Selector(("internalImage"))) {
                xctImageAny = shot.internalImage()
            } else if let obj = raw as AnyObject?, obj.responds(to: Selector(("data"))) {
                xctImageAny = obj
            } else {
                xctImageAny = nil
            }
            guard let xctImage = xctImageAny else {
                failStep = "screenshotWithPreferredEncoding returned \(raw.map { String(describing: type(of: $0)) } ?? "nil") " +
                    "(encoding \((encoding as AnyObject).description ?? ""))"; return
            }
            guard xctImage.responds(to: Selector(("data"))) else {
                failStep = "XCTImage lacks data"; return
            }
            // A private class: no Swift cast (it doesn't link), just the call.
            guard let data = xctImage.perform(Selector(("data")))?.takeUnretainedValue() as? Data else {
                failStep = "XCTImage.data was nil (frame kept as a bitmap, not encoded)"; return
            }
            guard let img = UIImage(data: data), img.cgImage != nil else {
                failStep = "UIImage(data:) failed on \(data.count) bytes"; return
            }
            result = (img, data)
            sizeKB = data.count / 1024
        }

        if let frame = result {
            if jpegCaptureAvailable == nil {
                jpegCaptureAvailable = true
                logBuffer.append("📷 JPEG capture active (q=\(quality), \(sizeKB) KB/frame)")
            }
            return frame
        }
        if jpegCaptureAvailable == nil {
            jpegCaptureAvailable = false
            logBuffer.append("📷 JPEG capture unavailable — using bitmap path. "
                             + "Stopped at: \(raised ?? failStep)")
        }
        return nil
    }

    /// nil = not tried yet, true = the JPEG capture works off the main thread,
    /// false = off for now (until `offMainRetryAt`).
    private static var offMainCaptureWorks: Bool?
    private static var offMainFailures = 0
    private static var offMainRetryAt: TimeInterval = 0
    private static let offMainLock = NSLock()

    /// A stream frame captured on the caller's thread, so it does not queue
    /// behind an action holding the main thread (a drag blocks it for its
    /// whole duration, which froze the stream for as long). Tried once the
    /// capture path has been probed on the main thread.
    ///
    /// Three failures in a row turn it off, for a minute, then it is tried
    /// again. It used to be one failure, for good: a single missed frame while
    /// a touch was being synthesized was enough, and from then on every frame
    /// waited behind every action on the main thread — with quick taps the
    /// picture stopped while the taps went on.
    static func offMainFrame(jpegQuality: Double) -> (image: UIImage, jpeg: Data?)? {
        guard jpegCaptureAvailable != nil else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        offMainLock.lock()
        let off = offMainCaptureWorks == false && now < offMainRetryAt
        offMainLock.unlock()
        if off { return nil }
        var frame: (image: UIImage, jpeg: Data?)?
        let raised = ObjCException.catching { frame = captureFrame(jpegQuality: jpegQuality) }
        offMainLock.lock()
        defer { offMainLock.unlock() }
        if frame != nil {
            if offMainCaptureWorks != true { logBuffer.append("📷 stream capture runs off the main thread") }
            offMainCaptureWorks = true
            offMainFailures = 0
            return frame
        }
        offMainFailures += 1
        if offMainFailures >= 3 {
            if offMainCaptureWorks != false {
                logBuffer.append("📷 off-main capture failed 3 times (\(raised ?? "no frame")) — "
                                 + "the stream captures on the main thread for a minute")
            }
            offMainCaptureWorks = false
            offMainRetryAt = now + 60
            offMainFailures = 0
        }
        return nil
    }

    /// One screen frame, cheapest path first: a JPEG the capture side
    /// compressed for us, else the bitmap without the PNG round-trip, else the
    /// public API. Main thread only. Used by the post-action settle check.
    static func captureFrame() -> UIImage? {
        captureFrame(jpegQuality: captureJPEGQuality)?.image
    }

    /// The same, at a chosen JPEG quality, with the JPEG bytes when the fast
    /// path produced them (the screen stream compares them to skip frames
    /// that did not change).
    static func captureFrame(jpegQuality: Double) -> (image: UIImage, jpeg: Data?)? {
        // Fast path: ask the capture side to hand back a JPEG. The
        // default `screenshot()` produces a full-resolution bitmap
        // (~6 MB at 828x1792) that we then copy again; capture and
        // that copy are what degrade 15-20x under thermal pressure,
        // while encoding barely moves. Compressing at the source
        // keeps the big buffer out of this process entirely.
        if let frame = Self.grabJPEGFrame(quality: jpegQuality) { return (frame.image, frame.jpeg) }
        // Otherwise take the bitmap directly, still skipping the
        // PNG round-trip that `.image` would do. Also private, and
        // also behind an ObjC @try: on an OS where the selector
        // exists but behaves differently, an NSException here would
        // abort the runner rather than fall through.
        let shot = XCUIScreen.main.screenshot()
        var fast: UIImage?
        _ = ObjCException.catching {
            guard shot.responds(to: Selector(("internalImage"))),
                  let xctImage = shot.internalImage(),
                  xctImage.responds(to: Selector(("platformImage"))),
                  let img = xctImage.platformImage(),
                  img.cgImage != nil else { return }  // encoder needs CGImage
            fast = img
        }
        if let img = fast { return (img, nil) }
        return (shot.image, nil)
    }

    private static var lifecycleObserved = false

    /// Log foreground/background transitions — a silent exit often correlates with
    /// the runner being backgrounded/resigned right before it's reclaimed.
    private static func observeAppLifecycle() {
        guard !lifecycleObserved else { return }
        lifecycleObserved = true
        let nc = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didFinishLaunchingNotification, "app didFinishLaunching"),
            (UIApplication.didBecomeActiveNotification, "app didBecomeActive"),
            (UIApplication.willResignActiveNotification, "app willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "app didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "app willEnterForeground"),
            (UIApplication.willTerminateNotification, "app willTerminate"),
        ]
        for (name, label) in events {
            nc.addObserver(forName: name, object: nil, queue: nil) { _ in
                logBuffer.append("🔄 \(label)")
            }
        }
        // Scene lifecycle (the runner uses scenes).
        let sceneEvents: [(Notification.Name, String)] = [
            (UIScene.willConnectNotification, "scene willConnect"),
            (UIScene.didActivateNotification, "scene didActivate"),
            (UIScene.willDeactivateNotification, "scene willDeactivate"),
            (UIScene.didEnterBackgroundNotification, "scene didEnterBackground"),
            (UIScene.willEnterForegroundNotification, "scene willEnterForeground"),
            (UIScene.didDisconnectNotification, "scene didDisconnect"),
        ]
        for (name, label) in sceneEvents {
            nc.addObserver(forName: name, object: nil, queue: nil) { _ in
                logBuffer.append("🔄 \(label)")
            }
        }
    }

    /// Swallow XCTest failure reports so a slow/hung interaction can't tear the
    /// test (and the server) down. (WebDriverAgent overrides the same path.)
    override func record(_ issue: XCTIssue) {
        Self.logBuffer.append("⚠️ XCTest issue swallowed: \(issue.compactDescription.prefix(120))")
        // Intentionally NOT calling super — do not propagate the failure.
    }

    private static var exitHandlersInstalled = false

    /// Register atexit + fatal-signal handlers that append to the persisted log
    /// file, so a silent process exit/kill is still recorded. Signal handlers must
    /// be async-signal-safe, so they write straight to the log file (no ObjC).
    private static func installExitHandlers() {
        guard !exitHandlersInstalled else { return }
        exitHandlersInstalled = true

        atexit {
            LoopCtrlUITests.logBuffer.appendDirectToFile("🚪 atexit — process exiting normally")
        }
        // Fatal signals — write a minimal marker, then re-raise the default handler.
        let signals: [(Int32, String)] = [
            (SIGTERM, "SIGTERM"), (SIGINT, "SIGINT"), (SIGABRT, "SIGABRT"),
            (SIGSEGV, "SIGSEGV"), (SIGILL, "SIGILL"), (SIGBUS, "SIGBUS"),
            (SIGKILL, "SIGKILL"),  // can't actually be caught, but harmless to try
        ]
        for (sig, name) in signals {
            signal(sig) { received in
                LogBuffer.signalName = LogBuffer.nameForSignal(received)
                LoopCtrlUITests.logBuffer.appendDirectToFile("💥 received signal \(LogBuffer.signalName ?? "\(received)")")
                signal(received, SIG_DFL)
                raise(received)
            }
        }
        Self.logBuffer.append("🪝 exit/signal handlers installed")
    }

    override func tearDownWithError() throws {
        // Record WHY the test is ending — this is the main place a silent exit
        // shows up (XCTest tears the test down → server stops).
        Self.logBuffer.append("🚪 tearDownWithError — test ending, stopping server. keepRunning=\(keepRunning)")
        server?.stop()
        server = nil
        actionHandler = nil
    }

    func testStartServer() throws {
        // Tell the bootstrap watchdog the test actually began, so it won't re-kick
        // runTestsInBackground: (the watchdog covers the case where the first-launch
        // passcode prompt interrupted the XCTest bootstrap). Do this FIRST so a
        // watchdog timer that's about to fire sees the flag and stays a no-op.
        EarlyURLHook.markTestStarted()


        // Bound XCTest's application-state wait now that bootstrap is behind us.
        // Doing this any earlier also bounds -[XCUIDevice enableAutomationMode:],
        // which waits for the accessibility server to come up; that wait exceeds
        // the cap on a cold start, and XCTest responds by exiting the process
        // ("Timed out while enabling automation mode"). Reaching this line proves
        // automation mode is already enabled, so the cap is safe here.
        QuiescenceDisabler.applyInteractionStateTimeout()

        // Bound each accessibility message to an app. Unbounded, a walk of a
        // large accessibility tree can run for minutes, holding the serial
        // UI queue the whole time. A walk past this now fails fast instead,
        // and the slow-tree paths take over. Set here, after bootstrap, for
        // the same reason as the state timeout above. WebDriverAgent sets it too.
        let previousAX = ForegroundApp.setAXTimeout(Self.axTimeoutSeconds)
        Self.logBuffer.append("⏳ AX timeout \(previousAX)s → \(Self.axTimeoutSeconds)s")

        // Last-resort exit visibility: register atexit + signal handlers so a
        // silent teardown / kill leaves a trace in the persisted log.
        Self.installExitHandlers()

        // Note the lock state at startup (diagnostics). We DON'T block on it: with
        // app.activate() removed from setUp, starting the server no longer needs the
        // device unlocked — the NWListener + device-address lookup work while locked,
        // and UI actions read app.frame lazily (only once a client calls one, which
        // is after unlock in practice).
        let lockedAtStart = LockStateMonitor.shared().isLocked
        Self.logBuffer.append("🔐 startup lock state: \(lockedAtStart ? "LOCKED" : "unlocked")")

        // Prune old daily log files and note where logs are persisted.
        Self.logBuffer.pruneOldLogFiles()
        if let dir = Self.logBuffer.logDirectoryPath {
            Self.logBuffer.append("🗂 Logs persist to \(dir)/loopctrl-YYYY-MM-DD.log")
        }

        actionHandler = ActionHandler(app: app)

        // Pairing is approved from a notification on the device.
        AuthManager.shared.delegate = self

        // Dev convenience: LOOPCTRL_ALLOW_AUTH_ONCE=1 (set in the Xcode scheme's
        // environment) auto-approves the FIRST pairing after this cold start, so
        // a debug run can re-pair without someone tapping Allow on the device.
        // It is consumed by that one pairing and never rearms — a flag left set
        // costs one free pair per launch, not a standing bypass. Never persisted.
        //
        // Always log what was read, including when the variable is absent or set
        // to something we don't accept: silence would be indistinguishable from
        // "typo'd the value", which is exactly the case you need to diagnose.
        let authOnceRaw = ProcessInfo.processInfo.environment["LOOPCTRL_ALLOW_AUTH_ONCE"]
        if authOnceRaw == "1" {
            AuthManager.shared.armSingleAutoApproval()
            Self.logBuffer.append(
                "🔓 LOOPCTRL_ALLOW_AUTH_ONCE=1 — ARMED: the next /pair auto-approves without an "
                + "on-device tap. Single use: it is consumed by that one pairing and does not rearm.")
        } else if let raw = authOnceRaw {
            Self.logBuffer.append(
                "🔒 LOOPCTRL_ALLOW_AUTH_ONCE=\"\(raw)\" — NOT armed (only the exact value \"1\" is "
                + "accepted). /pair will require an on-device Allow tap.")
        } else {
            Self.logBuffer.append(
                "🔒 LOOPCTRL_ALLOW_AUTH_ONCE unset — /pair requires an on-device Allow tap. "
                + "Set it to \"1\" in the Xcode scheme's environment to auto-approve the first pairing.")
        }

        keepRunning = true
        startService()
        observeNetworkChanges()
        requestLocalNetworkAtLaunch()

        // When the app comes back to the foreground (e.g. the user opened it to
        // grant the Local Network permission), re-verify remote reachability — if
        // it now works we clear the failure notification and post a fresh success.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // Only react when we're recovering from a reported failure (the user
            // likely just went to grant the permission). verify() reads the
            // reportedRemoteFailure flag to decide whether to announce success and
            // whether to re-post the failure, so we DON'T clear it here.
            guard let self = self, self.server != nil, self.remoteAccessEnabled, self.reportedRemoteFailure else { return }
            Self.logBuffer.append("🔄 app active after remote failure — re-verifying reachability")
            self.verifyRemoteReachableThenNotify(address: self.getDeviceAddress(), announceSuccess: false)
        }

        // Drain immediately on any incoming URL rather than waiting for the
        // safety timer — a warm runner would otherwise take up to 2s to bounce
        // back, which reads as "the callback didn't work".
        URLSchemeHandler.shared.onURLReceived = { [weak self] in
            DispatchQueue.main.async { self?.handlePendingCallbackIfAny() }
        }
        // All-in-one build: the LoopCtrl screen hands its Start/Stop over as
        // URLs (+[EarlyURLHook deliverURL:]), which says so here, so a tap acts
        // at once rather than on the next safety-timer tick.
        if EarlyURLHook.isInProcess() {
            NotificationCenter.default.addObserver(
                forName: Notification.Name(EarlyURLHook.urlDeliveredNotification), object: nil, queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.handlePendingCallbackIfAny() }
            }
            // The LoopCtrl screen's client list, log viewer and settings, same
            // process: answered like /rpc, without the key /rpc requires.
            NotificationCenter.default.addObserver(
                forName: InProcessRunnerControl.rpc, object: nil, queue: nil
            ) { [weak self] note in
                guard let info = note.userInfo, let method = info["method"] as? String,
                      let reply = info["reply"] as? (Data?, String?) -> Void else { return }
                guard InProcessRunnerControl.rpcMethods.contains(method) else {
                    reply(nil, "\(method) is not available in-process")
                    return
                }
                guard let handler = self?.server?.onRPCRequest else {
                    reply(nil, InProcessRunnerControl.notRunningError)
                    return
                }
                var params = (info["params"] as? Data)
                    .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
                // Same as a loopback /rpc caller; set here so it can't be claimed.
                if method == "config" {
                    params[JSONRPCServer.peerSourceParam] = .string(PeerSource.local.rawValue)
                }
                handler(method, params) { result, error in
                    if let error {
                        reply(nil, error.message)
                    } else {
                        reply(try? JSONEncoder().encode(result ?? [:]), nil)
                    }
                }
            }
            // The Remote Access switch on the LoopCtrl screen, same process.
            NotificationCenter.default.addObserver(
                forName: InProcessRunnerControl.setRemoteAccess, object: nil, queue: nil
            ) { [weak self] note in
                let on = note.userInfo?["on"] as? Bool ?? false
                DispatchQueue.main.async {
                    guard let self, self.server != nil else { return }
                    Self.logBuffer.append(on ? "🌐 Remote access on (LoopCtrl screen)" : "🔒 Remote access off (LoopCtrl screen)")
                    if on { self.enableRemoteAccess() } else { self.disableRemoteAccess() }
                }
            }
            // The visibility choice in LoopCtrl's Settings sheet, same process.
            NotificationCenter.default.addObserver(
                forName: InProcessRunnerControl.setNearby, object: nil, queue: nil
            ) { [weak self] note in
                let on = note.userInfo?["on"] as? Bool ?? false
                DispatchQueue.main.async {
                    guard let self, self.server != nil else { return }
                    Self.logBuffer.append(on ? "📡 Nearby discovery on (LoopCtrl screen)" : "📴 Nearby discovery off (LoopCtrl screen)")
                    if on && !self.remoteAccessEnabled { self.enableRemoteAccess() }
                    self.setNearby(on)
                }
            }
            returnToLoopCtrlIfBackgrounded()
        }

        // If launched via loopctrl://start?callback=..., jump back to the caller now.
        handlePendingCallbackIfAny()

        // Background the runner now that the server is listening.
        //
        // Reaching this point is the signal that could not be obtained any
        // earlier: XCTest's bootstrap completed, which means its "enable UI
        // automation" passcode prompt — if one was shown — has been answered.
        // Suspending from +load on a timer cancelled that authorization and
        // killed the launch outright.
        //
        // After the listener is up rather than before it, so suspension can't
        // curtail the startup work still to be done. A foreground runner gets
        // killed after a while and its UI is an empty XCTest shell, so there is
        // nothing lost by stepping aside once there is something to serve.
        // In the all-in-one build the "runner" is the LoopCtrl screen itself.
        //
        // Not when a start callback is on its way either: opening it already
        // takes the runner out of the foreground, into the app that asked (the
        // LoopCtrl app's Start button). Suspending as well raced that open and
        // could land the user on the Home Screen instead, which reads as
        // "LoopCtrl quit when I pressed Start". openCallback() falls back to
        // suspending if the callback cannot be opened.
        if !EarlyURLHook.isInProcess() && !startCallbackDispatched {
            backgroundSelfNow()
        }

        Self.logBuffer.append("🔁 entering run loop (keepRunning=\(keepRunning))")
        // WDA-style run loop: block on distantFuture instead of a 0.2s poll. The
        // run loop wakes on any input source — the RPC queue's main.sync, server
        // callbacks, notification actions — so we don't need to busy-poll. This
        // keeps CPU near zero when idle (matching FBWebServer.startServing) and
        // removes the 0.2s wakeup churn. A low-frequency safety timer still drains
        // any loopctrl:// callback that somehow didn't wake us.
        let runLoop = RunLoop.current
        let safetyTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.handlePendingCallbackIfAny()
        }
        runLoop.add(safetyTimer, forMode: .default)
        // Keep the status notification reachable (see startStatusRefresh).
        startStatusRefresh(on: runLoop)

        while keepRunning {
            autoreleasepool {
                // Blocks until an input source fires (or distantFuture, i.e. never).
                runLoop.run(mode: .default, before: Date.distantFuture)
            }
        }
        safetyTimer.invalidate()
        // Only reached when keepRunning was set false (stop_server / notification /
        // config restart). If we ever get here unexpectedly, the log shows it.
        // Never in the all-in-one build: there, returning means XCTest exit()s
        // LoopCtrl itself, so stopping parks the test instead (stopService).
        Self.logBuffer.append("🔁 run loop exited (keepRunning=false)")
    }

    // MARK: - Service start / stop

    /// Whether stopping the service leaves this test running, parked in its
    /// run loop with no listener, instead of ending it.
    ///
    /// In the two-app setup the test owns a process of its own (the
    /// LoopCtrlUITests-Runner), so ending it — after which XCTest calls exit()
    /// — is the cleanest stop there is, and a later `loopctrl://start` simply
    /// launches the runner afresh.
    ///
    /// In the all-in-one build the test runs inside the LoopCtrl app
    /// (InProcessRunner), and XCTest's exit() takes the app with it: Stop
    /// looked like a crash. XCTest can also be bootstrapped only once per
    /// process, so an ended test could not be started again without a
    /// relaunch. Parking keeps the app on screen and lets `loopctrl://start`
    /// (the app's Start button) bring the listener back on the same test.
    private var parksWhenStopped: Bool { EarlyURLHook.isInProcess() }

    /// All-in-one build, fallback only: XCTest's bootstrap presses Home on the
    /// runner, which here is LoopCtrl. InProcessRunner's BootstrapForegroundGuard
    /// keeps that from happening; should LoopCtrl still be in the background
    /// when the test begins, open it again through LaunchServices
    /// (`-[XCUIApplication activate]` on its own bundle id throws).
    private func returnToLoopCtrlIfBackgrounded(retry: Bool = true) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        if UIApplication.shared.applicationState == .background {
            Self.logBuffer.append("🏠 LoopCtrl is in the background after bootstrap — bringing it back")
            let ok = ForegroundApp.openBundleID(bundleID)
            Self.logBuffer.append(ok ? "🏠 LoopCtrl reopened" : "🏠 couldn't reopen LoopCtrl")
        }
        if retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.returnToLoopCtrlIfBackgrounded(retry: false)
            }
        }
    }

    /// Create, wire and start a listener from the persisted settings.
    ///
    /// Called once when the test begins and, in the all-in-one build, again for
    /// each start after a stop.
    @discardableResult
    private func startService() -> Bool {
        // Restore persisted preferences (fresh install → local only, ServerPort.defaultPort)
        remoteAccessEnabled = Self.persistedRemoteAccess
        if let asked = URLSchemeHandler.shared.pendingStartPort(), asked != Self.persistedPort {
            Self.logBuffer.append("🔢 Port \(asked) from loopctrl://start")
            Self.persistedPort = asked
        }
        let port = Self.persistedPort
        let newServer = JSONRPCServer(port: port, localOnly: !remoteAccessEnabled)
        server = newServer
        configureServerCallbacks(newServer)
        Self.serverStartedAt = ProcessInfo.processInfo.systemUptime
        // While LoopCtrl is in front: iOS starts a Live Activity for no other app.
        DispatchQueue.main.async { RemoteLiveActivity.shared.start() }

        defer { wireServerStateChange() }
        do {
            try newServer.start()
            if remoteAccessEnabled {
                nearbyEnabled = Self.persistedNearby
                if nearbyEnabled { newServer.startNearby() }
                let address = getDeviceAddress()
                announceRemoteReady(address: address)
            } else {
                Self.persistedNearby = false
                Self.logBuffer.append("🔒 Server started on 127.0.0.1:\(port) (local only)")
                postStatusNotification(port: port)
            }
            return true
        } catch {
            Self.logBuffer.append("🔴 Failed to start server: \(error)")
            sendNotification(
                subtitle: String(format: L10n.t(.serverFailedSubtitle), "\(port)"),
                body: error.localizedDescription
            )
            return false
        }
    }

    /// Stop serving. Every deliberate stop comes here: the loopctrl://stop
    /// URL, the Stop Service action on the status notification, `config{stop_server}`.
    /// Two-app setup: end the test, as before. All-in-one: drop the listener
    /// and park (see parksWhenStopped). Main thread.
    private func stopService(_ reason: String) {
        Self.logBuffer.append("🛑 \(reason)")
        // Detached first: the listener's own "cancelled" report would otherwise
        // also run the unexpected-stop path in wireServerStateChange.
        server?.onStateChange = nil
        server?.stop()
        announceStopped()
        DispatchQueue.main.async { RemoteLiveActivity.shared.end() }
        guard parksWhenStopped else {
            keepRunning = false   // break the run loop → test ends → XCTest exit()s the runner
            return
        }
        server = nil
        Self.logBuffer.append("⏸ service stopped — test parked; loopctrl://start (LoopCtrl's Start) restarts it")
        releaseAutomation()
    }

    /// All-in-one, parked: give UI automation back so iOS drops its
    /// "Automation Running" overlay (see AutomationSession.h). Start takes it
    /// again in `restartParkedService`.
    private func releaseAutomation() {
        var why: NSString?
        if AutomationSession.releaseAutomation(&why) {
            Self.logBuffer.append("🤖 automation released — the Automation Running overlay should go")
        } else {
            Self.logBuffer.append("🤖 automation kept (overlay stays): \(why ?? "?")")
        }
    }

    /// All-in-one, parked: take automation back if Stop released it, then
    /// listen again. Re-enabling Automation Mode waits on testmanagerd and may
    /// put up the passcode prompt, so it runs off the main thread; the server
    /// starts on the main thread afterwards.
    private func restartParkedService() {
        guard AutomationSession.isReleased else {
            startService()
            return
        }
        guard !reacquiringAutomation else { return }
        reacquiringAutomation = true
        Self.logBuffer.append("🤖 taking automation back…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var why: NSString?
            let ok = AutomationSession.reacquire(&why)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reacquiringAutomation = false
                Self.logBuffer.append(ok ? "🤖 automation back\(why.map { " (\($0))" } ?? "")"
                                         : "🤖 couldn't take automation back: \(why ?? "?")")
                if self.server == nil { self.startService() }
            }
        }
    }

    /// Withdraw the "running" notification (its Stop Service action has nothing left to
    /// stop) and post the usual "stopped" one.
    private func announceStopped() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.serverReadyNotifID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.serverReadyNotifID])
        sendStoppedNotification()
    }

    /// "Service stopped". Its one action, Copy Logs, would go unnoticed on a
    /// notification that otherwise needs nothing, so the body says it is there.
    private func sendStoppedNotification() {
        sendNotification(
            subtitle: L10n.t(.serverStoppedSubtitle),
            body: L10n.t(.longPressCopyLogs),
            category: Self.serverStoppedCategoryID
        )
    }

    /// Step out of the foreground via -[UIApplication suspend].
    ///
    /// `suspend` is the only one of the four probed selectors that iOS 26 still
    /// has, and it is what finally worked — pressing Home through XCUIDevice or
    /// IOHID reported success while doing nothing, the silent-confirmation
    /// failure Appium documented in WDA PR #1171.
    private func backgroundSelfNow() {
        // Only once XCTest is genuinely usable.
        //
        // Position in the code is not proof of that. XCTest can still be
        // acquiring its automation authorization here — the passcode prompt the
        // user has to answer — and suspending into that cancels it and takes the
        // launch down. Rather than infer readiness, ask: query SpringBoard's
        // state through XCUIApplication, which is exactly the capability the
        // authorization grants. A usable answer means the grant landed.
        guard waitUntilTestable(timeout: 30) else {
            Self.logBuffer.append("🏠 auto-background skipped — XCTest never became testable")
            return
        }

        let app = UIApplication.shared
        let sel = NSSelectorFromString("suspend")
        guard app.responds(to: sel) else {
            Self.logBuffer.append("🏠 auto-background unavailable — no suspend selector")
            return
        }
        // Wrapped: a throw inside XCTest aborts the runner, and failing to
        // background must never be worse than staying in front.
        let raised = ObjCException.catching {
            _ = app.perform(sel)
        }
        Self.logBuffer.append(raised.map { "🏠 auto-background raised: \($0)" }
                              ?? "🏠 auto-backgrounded via -[UIApplication suspend]")
    }

    /// Block until XCTest can actually drive the UI, or give up.
    ///
    /// `XCUIApplication.state` is the cheapest call that depends on the
    /// automation grant: it goes through the accessibility channel the
    /// authorization opens. While the prompt is still up it throws or answers
    /// `.unknown`; once the user has answered, it returns a real state.
    ///
    /// Generous timeout because the thing being waited on is a human typing a
    /// passcode. Giving up leaves the runner in the foreground, which is a far
    /// smaller problem than suspending mid-prompt.
    private func waitUntilTestable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var logged = false
        var lastReport = Date.distantPast
        while Date() < deadline {
            // Is a system prompt covering us right now?
            //
            // The passcode sheet is presented by LocalAuthenticationUIService,
            // not by us, and the device log shows it deactivating our scene while
            // it is up. UIScene.activationState is the first-party read of that:
            // .foregroundInactive means something is in front of us — during a
            // passcode entry, exactly what we must not suspend into.
            let sceneBlocked = UIApplication.shared.connectedScenes.contains { scene in
                scene.activationState == .foregroundInactive
            }
            if sceneBlocked {
                // Periodic rather than once: a silent 30s wait is
                // indistinguishable from a hang when reading the log later.
                if Date().timeIntervalSince(lastReport) >= 2 {
                    lastReport = Date()
                    let left = Int(deadline.timeIntervalSinceNow)
                    Self.logBuffer.append("🏠 waiting — a system prompt is covering the runner "
                                        + "(passcode / authorization, \(left)s left)")
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
                continue
            }

            var state = 0
            let raised = ObjCException.catching {
                state = ForegroundApp.appState(forBundleID: "com.apple.springboard")
            }
            // 0 == unknown; anything else means the accessibility channel answered.
            if raised == nil, state != 0 { return true }
            if !logged {
                Self.logBuffer.append("🏠 waiting for XCTest to become testable "
                                    + "(automation authorization may be pending)")
                logged = true
            }
            // Spin the run loop rather than sleep: the authorization completes on
            // the main thread, and blocking it here would deadlock the wait.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        return false
    }

    // MARK: - URL Scheme Callback

    /// Drain any pending loopctrl:// URLs and, for each start URL carrying a
    /// callback, jump back to the caller with the server status/address.
    /// Guards against re-entering the drain from a nested run loop.
    ///
    /// The start path spins `RunLoop.current.run(until:)` for up to 8s waiting
    /// for the server to listen. That nested loop happily dispatches the timer
    /// and the wake-up hook, which would re-enter this and consume the very URL
    /// the outer call is still working on.
    private var isDrainingURLs = false

    private func handlePendingCallbackIfAny() {
        guard !isDrainingURLs else { return }
        isDrainingURLs = true
        defer { isDrainingURLs = false }

        for url in URLSchemeHandler.shared.takeAllPendingURLs() {
            handleOneURL(url)
        }
    }

    private func handleOneURL(_ url: URL) {
        Self.logBuffer.append("🔗 handling \(url.absoluteString)")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        let host = url.host?.lowercased()

        // loopctrl://stop — shut the server down and end the test.
        //
        // This exists because /rpc is the only other way to stop the server and
        // it requires an encrypted envelope, which the host app has no key for.
        // The URL scheme is the same trust boundary as loopctrl://start: only
        // something already on this device can open it.
        if host == "stop" {
            let callback = items.first(where: { $0.name == "callback" })?.value
                .flatMap { Self.normalizeCallback($0) }
            stopService("loopctrl://stop — shutting down")
            if let callback {
                var cb = URLComponents(url: callback, resolvingAgainstBaseURL: false)
                var q = cb?.queryItems ?? []
                q.append(URLQueryItem(name: "status", value: "stopped"))
                cb?.queryItems = q
                if let final = cb?.url { openCallback(final, attempt: 1) }
            }
            return
        }

        // Only the "start" host triggers a callback jump; others are ignored.
        guard host == "start" || host == nil else {
            Self.logBuffer.append("🔗 Ignored loopctrl:// host: \(host ?? "")")
            return
        }

        // The LoopCtrl app's port setting. Stored either way; a server already
        // listening on another port moves over (startService reads it below).
        if let asked = URLSchemeHandler.port(in: url), asked != Self.persistedPort {
            Self.persistedPort = asked
            if let current = server, current.port != asked {
                Self.logBuffer.append("🔢 loopctrl://start asks for port \(asked) — moving from \(current.port)")
                current.onStateChange = nil
                current.stop()
                let moved = JSONRPCServer(port: asked, localOnly: !remoteAccessEnabled)
                wireNewServer(moved)
                do {
                    try moved.start()
                    if remoteAccessEnabled && nearbyEnabled { moved.startNearby() }
                } catch {
                    Self.logBuffer.append("🔴 Failed to listen on port \(asked): \(error)")
                }
            }
        }

        // All-in-one build, service stopped earlier: start it again on this
        // same test (a second XCTest bootstrap in one process would abort).
        if parksWhenStopped && server == nil {
            Self.logBuffer.append("▶️ loopctrl://start while parked — restarting the service")
            restartParkedService()
        }

        guard let callbackRaw = items.first(where: { $0.name == "callback" })?.value,
              !callbackRaw.isEmpty,
              let callbackURL = Self.normalizeCallback(callbackRaw) else {
            Self.logBuffer.append("🔗 loopctrl://start with no callback — server is running")
            return
        }

        // The server starts asynchronously (and a passcode prompt may have delayed
        // everything). Wait — briefly — for it to actually be listening before we
        // report status, so we don't hand the caller a false "failed".
        let deadline = Date().addingTimeInterval(8)
        while !(server?.isRunning ?? false) && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        }

        let running = server?.isRunning ?? false
        Self.logBuffer.append("🔙 server running=\(running) after wait")
        let address = remoteAccessEnabled ? "\(getDeviceAddress()):\(server?.port ?? Self.persistedPort)"
                                          : "127.0.0.1:\(server?.port ?? Self.persistedPort)"
        let status = running ? "ready" : "failed"

        // Append status + address to the callback URL.
        var cb = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        var q = cb?.queryItems ?? []
        q.append(URLQueryItem(name: "status", value: status))
        q.append(URLQueryItem(name: "address", value: address))
        cb?.queryItems = q

        guard let finalURL = cb?.url else {
            Self.logBuffer.append("🔗 Failed to build callback URL")
            return
        }

        Self.logBuffer.append("🔙 Callback → \(callbackURL.scheme ?? "")://…?status=\(status)")
        startCallbackDispatched = true
        // Off the main thread: ForegroundApp.open blocks on a semaphore for up
        // to 5s waiting for the XCTest daemon, and doing that on main stalls the
        // very run loop the server needs to keep answering.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.openCallback(finalURL, attempt: 1, backgroundIfUnopened: true)
        }
    }

    /// A start callback has been sent on its way; opening it moves the runner
    /// out of the foreground, so testStartServer doesn't suspend on top of it.
    private var startCallbackDispatched = false

    /// Accept a callback either as a full URL ("minis://home") or as a bare scheme
    /// ("minis" → "minis://"), so callers don't have to URL-encode a scheme.
    static func normalizeCallback(_ raw: String) -> URL? {
        if let u = URL(string: raw), u.scheme != nil {
            return u
        }
        // No scheme separator — treat the whole thing as a scheme name.
        let scheme = raw.hasSuffix("://") ? String(raw.dropLast(3)) : raw
        guard !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" || $0 == "." })
        else { return nil }
        return URL(string: "\(scheme)://")
    }

    /// Open the callback URL. From inside the XCTest runner, UIApplication.open is
    /// unreliable (it returns false), so we open via LSApplicationWorkspace
    /// (ForegroundApp.openURL) — the same private path that reliably launches
    /// apps from the runner. UIApplication.open is kept as a last-resort fallback.
    ///
    /// `backgroundIfUnopened`: step out of the foreground the usual way
    /// (backgroundSelfNow) if the callback cannot be opened at all, since the
    /// start path skipped that in favour of the callback.
    private func openCallback(_ url: URL, attempt: Int, backgroundIfUnopened: Bool = false) {
        if ForegroundApp.open(url) {
            Self.logBuffer.append("🔙 Callback opened via XCTest daemon")
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                if ok {
                    Self.logBuffer.append("🔙 Callback opened via UIApplication (attempt \(attempt))")
                } else if attempt < 3 {
                    Self.logBuffer.append("🔙 Callback open failed, retrying (\(attempt))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.openCallback(url, attempt: attempt + 1, backgroundIfUnopened: backgroundIfUnopened)
                    }
                } else {
                    Self.logBuffer.append("🔙 Callback gave up after \(attempt) attempts")
                    if backgroundIfUnopened && !EarlyURLHook.isInProcess() {
                        self.backgroundSelfNow()
                    }
                }
            }
        }
    }

    // MARK: - Notifications Setup

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Every action carries an SF Symbol; identifiers are what the response
        // handler keys off, so they never change with the presentation.
        func action(_ id: String, _ title: L10n.Key, _ symbol: String,
                    _ options: UNNotificationActionOptions = []) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: L10n.t(title), options: options,
                                 icon: UNNotificationActionIcon(systemImageName: symbol))
        }

        // Pairing request. Allow needs the device unlocked: a locked phone left
        // on a desk must not hand control to whoever is asking.
        let allowAction = action(Self.allowActionID, .allow, "checkmark.circle", [.authenticationRequired])
        let denyAction = action(Self.denyActionID, .deny, "xmark.circle", [.destructive])
        let authCategory = UNNotificationCategory(
            identifier: Self.authCategoryID,
            actions: [allowAction, denyAction],
            intentIdentifiers: [],
            options: []
        )

        // Status, local only: Remote Access on + Stop.
        let enableRemoteAction = action(Self.enableRemoteActionID, .enableRemote, "network", [.authenticationRequired])
        let stopServerAction = action(Self.stopServerActionID, .stopServer, "stop.circle",
                                      [.destructive, .authenticationRequired])
        let serverReadyCategory = UNNotificationCategory(
            identifier: Self.serverReadyCategoryID,
            actions: [enableRemoteAction, stopServerAction],
            intentIdentifiers: [],
            options: []
        )

        // Status, remote access on: Remote Access off, Nearby on/off, Stop.
        let disableRemoteAction = action(Self.disableRemoteActionID, .disableRemote, "lock", [.authenticationRequired])
        let enableNearbyAction = action(Self.enableNearbyActionID, .enableNearby,
                                        "dot.radiowaves.left.and.right", [.authenticationRequired])
        let disableNearbyAction = action(Self.disableNearbyActionID, .disableNearby,
                                         "antenna.radiowaves.left.and.right.slash", [.authenticationRequired])
        // Remote access on, nearby off: offer to turn nearby on.
        let serverRemoteCategory = UNNotificationCategory(
            identifier: Self.serverRemoteCategoryID,
            actions: [disableRemoteAction, enableNearbyAction, stopServerAction],
            intentIdentifiers: [],
            options: []
        )
        // Remote access and nearby on.
        let serverNearbyCategory = UNNotificationCategory(
            identifier: Self.serverNearbyCategoryID,
            actions: [disableRemoteAction, disableNearbyAction, stopServerAction],
            intentIdentifiers: [],
            options: []
        )

        // Stopped: Copy Logs.
        let copyLogsAction = action(Self.copyLogsActionID, .copyLogs, "doc.on.doc")
        let serverStoppedCategory = UNNotificationCategory(
            identifier: Self.serverStoppedCategoryID,
            actions: [copyLogsAction],
            intentIdentifiers: [],
            options: []
        )

        // Remote viewing or control: Pause, at once (no unlock), so a phone in
        // someone else's hands can always be taken back. Resuming needs the
        // device unlocked, like Allow.
        let pauseRemoteAction = action(Self.pauseRemoteActionID, .pauseRemote, "pause.circle", [.destructive])
        let remoteCategory = UNNotificationCategory(identifier: Self.remoteCategoryID, actions: [pauseRemoteAction],
                                                    intentIdentifiers: [], options: [])
        let resumeRemoteAction = action(Self.resumeRemoteActionID, .resumeRemote, "play.circle", [.authenticationRequired])
        let remotePausedCategory = UNNotificationCategory(identifier: Self.remotePausedCategoryID,
                                                          actions: [resumeRemoteAction], intentIdentifiers: [], options: [])

        center.setNotificationCategories([authCategory, serverReadyCategory, serverRemoteCategory,
                                          serverNearbyCategory, serverStoppedCategory,
                                          remoteCategory, remotePausedCategory])

        // Whatever a previous run left in Notification Centre is stale: pairing
        // prompts can no longer be answered (their requests died with that
        // process) and old status entries offer menus for a state that no
        // longer holds. This run posts its own status right after starting.
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()

        // Request permission
        let semaphore = DispatchSemaphore(value: 0)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Self.logBuffer.append(granted ? "🔔 Notifications enabled" : "🔕 Notifications denied")
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let requestID = response.notification.request.identifier

        // Pause / resume remote viewing and control (RemoteSession).
        if actionID == Self.pauseRemoteActionID || actionID == Self.resumeRemoteActionID {
            let pause = actionID == Self.pauseRemoteActionID
            Self.logBuffer.append(pause ? "⏸ Remote control paused by the owner (notification)"
                                        : "▶️ Remote control resumed by the owner (notification)")
            RemoteSession.shared.setPaused(pause)
            completionHandler()
            return
        }

        // Handle "Copy Logs"
        if actionID == Self.copyLogsActionID {
            let logs = Self.logBuffer.dump()
            UIPasteboard.general.string = logs
            Self.logBuffer.append("📋 Copied \(Self.logBuffer.count) log entries to clipboard")
            completionHandler()
            return
        }

        // A status notification left over from before a stop (all-in-one build,
        // parked): its toggles would bring a listener back behind the user's
        // back. Starting again is LoopCtrl's Start button.
        let serviceActions = [Self.enableRemoteActionID, Self.disableRemoteActionID,
                              Self.enableNearbyActionID, Self.disableNearbyActionID, Self.stopServerActionID]
        if parksWhenStopped && server == nil && serviceActions.contains(actionID) {
            Self.logBuffer.append("⏸ \(actionID) ignored — the service is stopped")
            completionHandler()
            return
        }

        // Handle "Disable Remote Access"
        if actionID == Self.disableRemoteActionID {
            Self.logBuffer.append("🔒 Remote access disabled via notification")
            disableRemoteAccess()
            completionHandler()
            return
        }

        // Handle "Stop Server"
        if actionID == Self.stopServerActionID {
            // The delegate may be called off the main thread; the server and
            // the run-loop flag belong to it.
            DispatchQueue.main.async { [weak self] in
                self?.stopService("Server stopped via notification")
            }
            completionHandler()
            return
        }

        // Handle "Enable / Disable Nearby Discovery"
        if actionID == Self.enableNearbyActionID {
            Self.logBuffer.append("📡 Nearby discovery enabled via notification")
            setNearby(true)
            completionHandler()
            return
        }
        if actionID == Self.disableNearbyActionID {
            Self.logBuffer.append("📴 Nearby discovery disabled via notification")
            setNearby(false)
            completionHandler()
            return
        }

        // Handle "Enable Remote Access" from server-ready notification
        if actionID == Self.enableRemoteActionID {
            Self.logBuffer.append("🌐 Remote access enabled via notification")
            enableRemoteAccess()
            completionHandler()
            return
        }

        // Handle auth request responses.
        guard requestID.hasPrefix("auth-") else {
            completionHandler()
            return
        }
        let kind = "Auth"

        authLock.lock()
        let authCompletion = pendingAuthCompletions.removeValue(forKey: requestID)
        if currentAuthRequestID == requestID { currentAuthRequestID = nil }
        authLock.unlock()

        switch actionID {
        case Self.allowActionID:
            Self.logBuffer.append("✅ \(kind) approved")
            authCompletion?(true)
        case Self.denyActionID:
            Self.logBuffer.append("❌ \(kind) denied")
            authCompletion?(false)
        case UNNotificationDefaultActionIdentifier:
            Self.logBuffer.append("✅ \(kind) approved (tap)")
            authCompletion?(true)
        case UNNotificationDismissActionIdentifier:
            Self.logBuffer.append("❌ \(kind) denied (dismiss)")
            authCompletion?(false)
        default:
            authCompletion?(false)
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Helpers

    private func wireServerStateChange() {
        server?.onStateChange = { [weak self, weak srv = server] running in
            if !running {
                Self.logBuffer.append("Server stopped")
                guard let self = self else { return }
                if self.parksWhenStopped {
                    // All-in-one: the listener failing must not end the test
                    // (and with it the LoopCtrl app). Park; Start retries.
                    DispatchQueue.main.async {
                        guard let srv, self.server === srv else { return }
                        srv.onStateChange = nil
                        srv.stop()
                        self.server = nil
                        self.announceStopped()
                        Self.logBuffer.append("⏸ listener went down — test parked; Start restarts it")
                    }
                    return
                }
                self.keepRunning = false
                self.sendStoppedNotification()
            }
        }
    }

    /// Methods that drive XCUITest and therefore MUST run on the main thread.
    /// Anything else (config, resolve_app, device_info, list_apps, is_locked, …)
    /// runs directly on the RPC queue — no main-thread hop, so it can't be delayed
    /// by (or delay) a slow UI action.
    private static let mainThreadMethods: Set<String> = [
        "tap", "double_tap", "long_press", "swipe", "scroll", "drag", "gesture",
        "page", "page_down", "page_up", "collect",
        "type", "clear_text", "screenshot", "page_source", "view_tree", "ui_tree",
        "scroll_to_element", "scroll_to", "find_element", "tap_element", "find_and_tap",
        "launch_app", "activate_app", "terminate_app",
        "home", "lock", "unlock", "rotate", "app_switcher", "notification_center", "control_center",
        "read_value",
        // device_info reads app.frame to report the coordinate space. That is an
        // XCUITest call, so it must hop to the main thread — and it cannot use
        // UIScreen instead: the runner runs in iOS compatibility mode and would
        // report 320x480 for every device (see compatibilityModeScreenBounds).
        // Correct geometry outranks staying off the UI queue; every tap the
        // client sends is computed from these numbers. Cached after the first
        // call, so the cost is one-shot.
        "device_info",
    ]

    /// Methods that bypass the UI queue entirely and run on their own concurrent
    /// queue.
    ///
    /// An XCUITest call can wedge for ~16s and cannot be cancelled, and the UI
    /// queue is serial — so anything sharing that queue is stuck behind it. That
    /// used to include the very calls you need when things go wrong: `device_info`
    /// to check liveness, `logs` to see why, `config{stop_server}` to recover.
    /// Diagnosis and recovery must not queue behind the fault they diagnose, so
    /// they get their own lane. Every method here must be free of XCUITest APIs.
    private static let nonUIMethods: Set<String> = [
        "config", "reset", "is_locked", "logs", "recent_logs",
        "resolve_app", "search_app", "search_apps",
        "list_apps", "installed_apps",
        // Waits up to a minute; each of its looks hops to the main thread on
        // its own, so touches from others go on meanwhile.
        "wait",
        // Class-metadata introspection only — takes no snapshot, touches no
        // element. Belongs here precisely because you want to run it WHILE the
        // UI channel is wedged, to find out what the snapshot API supports.
        "snapshot_api",
    ]

    /// Compact one-line summary of the most useful params for the request log.
    /// Keeps element_id/x/y/bundle_id/direction/text-length so a crash post-mortem
    /// shows what an action targeted, without dumping the whole payload.
    private static func summarizeParams(_ params: [String: JSONValue]?) -> String {
        guard let params = params, !params.isEmpty else { return "" }
        let keys = ["element_id", "ref", "bundle_id", "x", "y", "direction", "match", "element_type", "submit"]
        var parts: [String] = []
        for k in keys {
            if let v = params[k] {
                switch v {
                case .string(let s): parts.append("\(k)='\(s)'")
                case .int(let i): parts.append("\(k)=\(i)")
                case .double(let d): parts.append("\(k)=\(Int(d))")
                case .bool(let b): parts.append("\(k)=\(b)")
                default: break
                }
            }
        }
        if let t = params["text"]?.stringValue { parts.append("text.len=\(t.count)") }
        return parts.joined(separator: " ")
    }

    /// Serial queue for RPC execution — OFF the main thread so a slow/blocking
    /// XCUITest call can't freeze the network listener (which would drop the whole
    /// service). Serial so actions still run one-at-a-time in order.
    private let rpcQueue = DispatchQueue(label: "top.ebato.loopctrl.rpc")

    /// Consecutive UI-method timeouts. Reset by any UI method that completes.
    private var uiTimeoutStreak = 0
    /// Set when the breaker trips, so the message can name how long it's been.
    private var uiBreakerTrippedAt: Date?
    private let uiHealthLock = NSLock()
    /// The UI call currently executing, if any. The queue is serial and a stuck
    /// call can't be cancelled, so "what is it stuck on, and for how long" is the
    /// one fact every later timeout needs — without it a post-mortem has to
    /// reconstruct it from logs, and got it wrong (blamed the calls behind it).
    private var uiInFlight: (method: String, since: TimeInterval)?

    private func setUIInFlight(_ method: String?) {
        uiHealthLock.lock()
        uiInFlight = method.map { ($0, ProcessInfo.processInfo.systemUptime) }
        uiHealthLock.unlock()
    }

    /// "tap (running 42s)" for the call holding the UI queue, or nil.
    private func uiInFlightSummary() -> String? {
        uiHealthLock.lock()
        defer { uiHealthLock.unlock() }
        guard let f = uiInFlight else { return nil }
        let secs = Int(ProcessInfo.processInfo.systemUptime - f.since)
        return "\(f.method) (running \(secs)s)"
    }

    /// Consecutive timeouts before the UI channel is treated as unhealthy. Two
    /// keeps a single slow-but-recoverable action (a heavy page snapshot) from
    /// tripping it, while still reacting on the second confirmation.
    private static let uiBreakerThreshold = 2

    /// Non-nil when the UI channel is unhealthy — the value is the client message.
    private func uiBreakerMessage() -> String? {
        uiHealthLock.lock()
        defer { uiHealthLock.unlock() }
        guard uiTimeoutStreak >= Self.uiBreakerThreshold, let since = uiBreakerTrippedAt else { return nil }
        let secs = Int(Date().timeIntervalSince(since))
        let stuck = uiInFlight.map { f -> String in
            let running = Int(ProcessInfo.processInfo.systemUptime - f.since)
            return " The queue is held by \(f.method), running for \(running)s — it can't be cancelled, "
                 + "only waited out; logs{text:\"\(f.method)\"} shows when it ends."
        } ?? ""
        return "UI automation is unresponsive: \(uiTimeoutStreak) consecutive calls timed out "
             + "(first \(secs)s ago), so this request was rejected instead of queued behind them."
             + stuck + " "
             + "Call reset to rebuild the accessibility connection, or launch_app to bring the target app "
             + "back to the front. logs, config and reset still answer; device_info shares the UI queue."
    }

    /// Record a UI method timing out. Trips the breaker at the threshold.
    private func noteUITimeout(method: String) {
        uiHealthLock.lock()
        uiTimeoutStreak += 1
        let streak = uiTimeoutStreak
        if streak == Self.uiBreakerThreshold { uiBreakerTrippedAt = Date() }
        uiHealthLock.unlock()
        if streak == Self.uiBreakerThreshold {
            Self.logBuffer.append("⛔️ UI channel marked unhealthy after \(streak) consecutive timeouts "
                                + "(latest: \(method)) — UI methods now fail fast; call reset to recover")
        }
    }

    /// A UI method finished, so the channel is alive again.
    private func noteUISuccess() {
        uiHealthLock.lock()
        let wasTripped = uiTimeoutStreak >= Self.uiBreakerThreshold
        uiTimeoutStreak = 0
        uiBreakerTrippedAt = nil
        uiHealthLock.unlock()
        if wasTripped { Self.logBuffer.append("✅ UI channel recovered — resuming normal dispatch") }
    }

    /// Queue for methods that never touch XCUITest (see `nonUIMethods`).
    ///
    /// Concurrent, and deliberately separate from `rpcQueue`: its whole purpose is
    /// to keep answering while the serial UI queue is blocked by an uncancellable
    /// XCUITest call. Sharing a queue with the UI work would defeat that.
    private let nonUIQueue = DispatchQueue(label: "top.ebato.loopctrl.rpc.nonui",
                                           attributes: .concurrent)

    /// Hard ceiling for a single RPC before we report failure to the client. With
    /// quiescence disabled + fast defaults, real actions finish well under 1s, so
    /// a few seconds is already a hang. We reply failure quickly (so the client
    /// isn't left waiting and XCTest's own execution watchdog is less likely to
    /// kill the test); the underlying XCUITest call — which genuinely can't be
    /// force-cancelled — finishes on its own, and the serial queue drains it
    /// before the next request runs.
    private static let rpcTimeout: TimeInterval = 6

    /// page_source gets a longer leash than actions do. On a long-scrolled feed
    /// the read is legitimately slow — audited at 6.7–9.6s per call on X with
    /// every one COMPLETING on the device — so a flat 6s cap was discarding
    /// finished work, and two such "failures" in a row tripped the circuit
    /// breaker, which then rejected everything: the mechanic behind a measured
    /// 51% page_source failure rate. Most actions keep the tight cap; for them
    /// a 6-second silence really does mean something is wrong.
    ///
    /// find_and_tap / tap_element are the exception: they are locate-driven,
    /// and locating during a screen transition is legitimately slow — XCTest's
    /// AX layer stalls per query while the UI animates (a 30-node mid-transition
    /// WeChat tree cost 5–6.5s per snapshot; the settled 120-node tree, 169ms).
    /// Three consecutive find_and_tap "timeouts" all completed server-side at
    /// 10.2–11.6s. A false timeout is WORSE for an action than for a read: the
    /// documented remedy for ambiguity is to retry, and retrying an already-
    /// landed tap fires it twice. The longer watchdog does not hold the serial
    /// queue any longer — the work occupies it either way — it only keeps the
    /// client waiting for the real answer.
    // screen_text: OCR alone can take seconds on a busy or thermally
    // throttled device, pushing a normally finishing call past 6s.
    private static let extendedTimeoutMethods: Set<String> = ["page_source", "find_and_tap", "tap_element", "collect", "screen_text"]
    private static let extendedRpcTimeout: TimeInterval = 15

    private static func rpcBudget(for method: String, params: [String: JSONValue]?) -> TimeInterval {
        if method == "wait" {
            // As long as it was asked to wait, and a slow last look (OCR).
            let asked = params?["text"] != nil ? (params?["timeout"]?.doubleValue ?? 10) : (params?["duration"]?.doubleValue ?? 1)
            return min(max(asked, 0), 60) + 15
        }
        return extendedTimeoutMethods.contains(method) ? extendedRpcTimeout : rpcTimeout
    }

    /// Wire RPC dispatch + public logs onto a server instance.
    private func configureServerCallbacks(_ srv: JSONRPCServer) {
        // Advertising can start late (awdl0 appears once Wi-Fi is on), so the
        // status notification follows the advertiser rather than the toggle.
        srv.onNearbyStateChange = { [weak self, weak srv] status in
            DispatchQueue.main.async {
                guard let self = self, let srv = srv, self.server === srv else { return }
                Self.logBuffer.append("📡 Nearby status: \(status.rawValue)")
                self.postStatusNotification(port: srv.port, silent: true)
                if status == .denied {
                    // Also catches access revoked while running; the re-check
                    // it starts clears it again if that was something else.
                    self.setLocalNetworkAccess("denied")
                    self.requestLocalNetworkForNearby()
                }
                // Advertising at all proves the permission.
                if status == .advertising { self.setLocalNetworkAccess("granted") }
            }
        }
        srv.onRPCRequest = { [weak self] method, params, completion in
            guard let self = self else {
                completion(nil, .internalError)
                return
            }

            // Run the work on the serial RPC queue with a watchdog timeout so a
            // hung call reports back to the client instead of stalling forever.
            let done = DispatchSemaphore(value: 0)
            var replied = false
            let replyLock = NSLock()

            func replyOnce(_ result: ([String: JSONValue]?, JSONRPCError?)) {
                replyLock.lock()
                let first = !replied
                replied = true
                replyLock.unlock()
                if first { completion(result.0, result.1) }
            }

            // Non-UI methods take their own lane so diagnosis and recovery stay
            // available while the serial UI queue is wedged.
            let isUIMethod = !Self.nonUIMethods.contains(method)
            let queue = isUIMethod ? self.rpcQueue : self.nonUIQueue
            // Read-only polls (a log viewer pulling `logs`, a client list
            // re-reading `config`) would otherwise fill the very log being
            // read with their own request lines. They still count in timing
            // stats, and a failure is still logged.
            let quiet = method == "logs" || method == "recent_logs"
                || (method == "config" && (params ?? [:]).keys.allSatisfy { $0 == JSONRPCServer.peerSourceParam })

            // Circuit breaker: once the UI channel has hung repeatedly, stop
            // adding to the backlog. Each queued call would wait out the stuck
            // one and then likely hang itself, so the queue grows without ever
            // draining. Failing immediately with a recovery hint is strictly
            // better than a client blocking for minutes.
            if isUIMethod, let tripped = self.uiBreakerMessage() {
                Self.logBuffer.append("⛔️ \(method) rejected — UI channel unhealthy")
                completion(nil, .serverError(tripped))
                return
            }

            // reset is the documented way out of a tripped breaker, so give the
            // UI channel a clean slate — otherwise the next UI call is rejected
            // by the very state reset was called to clear.
            if method == "reset" { self.noteUISuccess() }

            // Set once the call actually begins — a timeout reply has to say
            // whether this call ran and hung, or is still waiting behind another.
            let started = Atomic(false)

            queue.async {
                let start = ProcessInfo.processInfo.systemUptime
                var result: ([String: JSONValue]?, JSONRPCError?) = (nil, .internalError)
                started.set(true)
                if isUIMethod { self.setUIInFlight(method) }

                // Log the request WITH key params BEFORE running it, so if this
                // call crashes/hangs the persisted log shows exactly what was
                // invoked (e.g. which element tap_element targeted). Redaction in
                // the log layer masks sensitive values.
                if !quiet { Self.logBuffer.append("→ \(method) \(Self.summarizeParams(params))") }

                // XCUITest UI interactions (tap/swipe/type/…) MUST run on the main
                // thread — calling them off-main throws an ObjC NSException that,
                // uncaught on a background queue, aborts the whole runner (observed
                // crash). So we hop to the main thread for the actual dispatch, and
                // wrap it in an Obj-C @try/@catch so a stale/non-hittable element
                // turns into a JSON-RPC error instead of a SIGABRT.
                let work = {
                    if method == "config" {
                        result = self.handleConfig(params)
                    } else if let handler = self.actionHandler {
                        let reason = ObjCException.catching {
                            result = handler.dispatch(method: method, params: params)
                        }
                        if let reason = reason {
                            result = (nil, .serverError(
                                "\(method) failed: \(reason). The element may be gone/off-screen/not hittable, or the UI changed — re-check with page_source and retry."
                            ))
                        }
                    } else {
                        result = (nil, .internalError)
                    }
                }
                // Only XCUITest UI interactions must run on the main thread. Pure
                // data/network methods (config, resolve_app, device_info, list_apps,
                // logs, lock state) run directly on the RPC queue — no reason to
                // hop to (and potentially block) the main thread for them.
                if Self.mainThreadMethods.contains(method) && !Thread.isMainThread {
                    DispatchQueue.main.sync(execute: work)
                } else {
                    work()
                }

                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                Self.logBuffer.recordTiming(method: method, ms: ms, ok: result.1 == nil, quiet: quiet)
                // Completing at all proves the UI channel is alive, even if the
                // action itself failed (element not found is a healthy answer).
                if isUIMethod { self.setUIInFlight(nil); self.noteUISuccess() }
                if let err = result.1 { Self.logBuffer.append("← ERR \(method): \(err.message)") }
                done.signal()
                replyOnce(result)  // may be a no-op if the watchdog already replied
            }

            // Watchdog: if the work doesn't finish in time, tell the client now.
            let budget = Self.rpcBudget(for: method, params: params)
            DispatchQueue.global().async {
                if done.wait(timeout: .now() + budget) == .timedOut {
                    // Queued, not hung: this call never started because another
                    // one holds the serial UI queue. It will still run once that
                    // finishes — the caller must know that before retrying.
                    if isUIMethod, !started.get(), let holder = self.uiInFlightSummary() {
                        Self.logBuffer.append("⏱ TIMEOUT \(method) — still queued behind \(holder)")
                        self.noteUITimeout(method: method)
                        replyOnce((nil, JSONRPCError(code: -32000, message:
                            "\(method) has NOT run yet: it is queued behind \(holder), which is stuck and can't be " +
                            "cancelled. It will still execute once that finishes — do not send it again. " +
                            "Wait, and watch logs{text:\"\(method)\"} for '⏱ ✓ \(method)'. If the stuck call is against " +
                            "an app that left the screen, activate_app it or wait for it to fail on its own.",
                            data: ["outcome": .string("queued"), "retry_safe": .bool(false)])))
                        return
                    }
                    Self.logBuffer.append("⏱ TIMEOUT \(method) (>\(Int(budget))s) — still running in background")
                    if isUIMethod { self.noteUITimeout(method: method) }
                    replyOnce((nil, JSONRPCError(code: -32000, message:
                        "\(method) exceeded \(Int(budget))s and may still be running on the device. " +
                        "Do NOT blindly retry — the action may have already succeeded. Call logs{text:\"\(method)\"} (an ordinary RPC on the non-UI lane, works even while UI calls are wedged) and look for '⏱ ✓ \(method)'. If UI calls keep timing out, reset rebuilds the accessibility connection.",
                        data: ["outcome": .string("unknown"), "retry_safe": .bool(false)])))
                }
            }
        }
        srv.onLogsRequest = {
            let logs = Self.logBuffer.dumpRedacted()
            let timing = Self.logBuffer.timingSummary()
            return logs + "\n\n=== Timing summary (ms) ===\n" + timing
        }
        // Route the server's internal lifecycle messages into the persisted log.
        srv.onLog = { Self.logBuffer.append($0) }
        // Persisted-log endpoints (crash recovery — survive process restarts).
        srv.onLogFilesRequest = { Self.logBuffer.listLogFiles() }
        srv.onLogHistoryRequest = { Self.logBuffer.readLogFile(date: $0) }
        // Live screen for /stream: one capture loop and encoder for every
        // viewer, logged with the RPC calls.
        ScreenStream.onLog = { msg in Self.logBuffer.append(msg) }
        // Someone watching or driving from afar: say so on the phone, with a
        // way to pause it all from the notification.
        ScreenStream.onViewersChange = { [weak self] _ in
            DispatchQueue.main.async { self?.updateRemoteNotification() }
        }
        RemoteSession.shared.onLog = { line in Self.logBuffer.append(line) }
        RemoteLiveActivity.shared.onLog = { line in Self.logBuffer.append(line) }
        // The Live Activity's Pause and Resume (RemoteActivityIntents, run in
        // this process by the app).
        NotificationCenter.default.addObserver(forName: RemoteActivityRequest.pause, object: nil, queue: .main) { note in
            let pause = note.userInfo?["paused"] as? Bool ?? true
            Self.logBuffer.append(pause ? "⏸ Remote control paused by the owner (Live Activity)"
                                        : "▶️ Remote control resumed by the owner (Live Activity)")
            RemoteSession.shared.setPaused(pause)
        }
        // A Live Activity that couldn't start with the service (LoopCtrl was
        // in the background), or that iOS ended after its 8 hours: try again
        // whenever LoopCtrl is in front.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.server != nil, !RemoteLiveActivity.shared.isShowing else { return }
            RemoteLiveActivity.shared.start()
            // Say it all again, now on the activity, if anyone is there.
            if RemoteSession.shared.paused || !RemoteSession.shared.present().isEmpty { self.remoteNotice = "" }
            self.updateRemoteNotification()
        }
        RemoteSession.shared.onChange = { [weak self] in
            ScreenStream.shared.broadcastState()
            DispatchQueue.main.async { self?.updateRemoteNotification() }
        }
        let scale = Double(UIScreen.main.scale)
        ScreenStream.shared.grab = { quality in
            // Off the main thread when the capture path allows it, so a
            // stream frame doesn't wait behind an action holding the main
            // thread; XCUIScreen otherwise has to be called there.
            var frame = Self.offMainFrame(jpegQuality: quality)
            if frame == nil { DispatchQueue.main.sync { frame = Self.captureFrame(jpegQuality: quality) } }
            guard let frame, let image = frame.image.cgImage else { return nil }
            return (image, frame.jpeg, scale)
        }
        // Cut click-to-reflect latency: when a UI-mutating RPC completes,
        // capture a fresh frame instead of waiting for the next tick.
        srv.onRPCUIChanged = { ScreenStream.shared.nudge() }
        srv.onPageUpdated = { ScreenStream.shared.broadcastState() }
        srv.onScreenStream = { connection, request in
            ScreenStream.shared.add(connection, request: request)
        }
        srv.onStreamAck = { viewer, micros, queueMs, wantsKey in
            ScreenStream.shared.ack(viewer: viewer, micros: micros, queueMs: queueMs, wantsKey: wantsKey)
        }
    }

    // MARK: - Config RPC

    /// Read (no params) or update basic settings.
    /// Params: {allow_remote_access?: bool, listen_port?: int}
    /// Returns current effective config. Changing settings restarts the server.
    /// `config` runs on the concurrent non-UI lane; two at once would race on
    /// the settings below.
    private let configLock = NSLock()

    private func handleConfig(_ params: [String: JSONValue]?) -> ([String: JSONValue]?, JSONRPCError?) {
        configLock.lock()
        defer { configLock.unlock() }
        return applyConfig(params)
    }

    private func applyConfig(_ params: [String: JSONValue]?) -> ([String: JSONValue]?, JSONRPCError?) {
        // Validate everything before changing anything: a request refused
        // half-way must not leave some settings applied and others not.
        let remoteTarget = params?["allow_remote_access"]?.boolValue ?? remoteAccessEnabled
        if params?["nearby_discovery"]?.boolValue == true && !nearbyEnabled {
            // Switching it ON widens who can reach the device, so it is
            // accepted only from a caller on this device — the LoopCtrl app or a
            // computer over USB — like the toggle on the device's notification.
            guard remoteTarget else {
                return (nil, JSONRPCError(code: -32602, message: "nearby_discovery needs allow_remote_access:true", data: nil))
            }
            guard params?[JSONRPCServer.peerSourceParam]?.stringValue == PeerSource.local.rawValue else {
                return (nil, JSONRPCError(code: -32602,
                                          message: "nearby_discovery can be switched on only from this device: the LoopCtrl app, a computer over USB, or the LoopCtrl notification",
                                          data: nil))
            }
        }
        if let newName = params?["device_name"]?.stringValue,
           newName.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > NearbyIdentity.maxNameBytes {
            return (nil, JSONRPCError(code: -32602,
                                      message: "device_name must be at most \(NearbyIdentity.maxNameBytes) bytes of UTF-8",
                                      data: nil))
        }
        if let portValue = params?["listen_port"]?.intValue, !ServerPort.allowed.contains(portValue) {
            return (nil, JSONRPCError(code: -32602,
                                      message: "listen_port must be \(ServerPort.allowed.lowerBound)..\(ServerPort.allowed.upperBound)",
                                      data: nil))
        }

        // Answering pairing requests is the device owner's call, so it is
        // accepted only from this device: the LoopCtrl app (in-process, or
        // over loopback in the two-IPA build) or a computer over USB. A client
        // asking to pair holds no key and cannot reach `config` at all; this
        // keeps an already-paired client on the network from approving others.
        let fromThisDevice = params?[JSONRPCServer.peerSourceParam]?.stringValue == PeerSource.local.rawValue
        let pairRespond = params?["pair_respond"]?.objectValue
        let pairAllowRecent = params?["pair_allow_recent"]?.stringValue
        // Remote service pre-approvals (docs/relay-enrollment.md): set when
        // the user confirms an invite in the app, removed on 解除绑定. Same
        // rule: only from this device.
        let relayPreapprove = params?["relay_preapprove"]?.objectValue
        // One id, or several (the app's batch 解除绑定).
        let relayRevoke: [String]? = params?["relay_revoke"].flatMap { value in
            value.stringValue.map { [$0] } ?? value.arrayValue?.compactMap(\.stringValue)
        }
        if (relayPreapprove != nil || relayRevoke != nil) && !fromThisDevice {
            return (nil, JSONRPCError(code: -32602,
                                      message: "Remote service approvals can be changed only on this device, in the LoopCtrl app",
                                      data: nil))
        }
        if let relayPreapprove {
            guard let connectionID = relayPreapprove["connection_id"]?.stringValue,
                  let rows = relayPreapprove["operators"]?.arrayValue else {
                return (nil, JSONRPCError(code: -32602, message: "relay_preapprove needs connection_id and operators", data: nil))
            }
            let operators: [(name: String, keyID: String)] = rows.compactMap { row in
                guard let o = row.objectValue, let keyID = o["key_id"]?.stringValue else { return nil }
                return (o["name"]?.stringValue ?? "", keyID)
            }
            AuthManager.shared.setRelayPreApprovals(connectionID: connectionID, operators: operators)
            Self.logBuffer.append("🔑 Remote service \(connectionID): \(operators.count) operator(s) pre-approved")
        }
        for connectionID in relayRevoke ?? [] {
            let revoked = AuthManager.shared.revokeRelayPreApprovals(connectionID: connectionID)
            Self.logBuffer.append("🧹 Remote service \(connectionID) unbound: pre-approvals removed, \(revoked) session(s) revoked")
        }
        if (pairRespond != nil || pairAllowRecent != nil) && !fromThisDevice {
            return (nil, JSONRPCError(code: -32602,
                                      message: "Pairing requests can be answered only on this device: the LoopCtrl app or the notification",
                                      data: nil))
        }
        var pairingAnswer: Bool?
        if let pairRespond {
            guard let id = pairRespond["request_id"]?.stringValue,
                  let allow = pairRespond["allow"]?.boolValue else {
                return (nil, JSONRPCError(code: -32602, message: "pair_respond needs request_id and allow", data: nil))
            }
            pairingAnswer = AuthManager.shared.respondToPendingRequest(id: id, allow: allow)
            Self.logBuffer.append(pairingAnswer == true
                                  ? (allow ? "✅ Auth approved (LoopCtrl app)" : "❌ Auth denied (LoopCtrl app)")
                                  : "⚠️ pair_respond: request no longer waiting")
        }
        if let id = pairAllowRecent {
            pairingAnswer = AuthManager.shared.allowRecentRequest(id: id)
            Self.logBuffer.append(pairingAnswer == true
                                  ? "🔓 Client allowed after the fact — its next pairing with the same key is approved once"
                                  : "⚠️ pair_allow_recent: request not found or not allowable")
        }

        var restartNeeded = false
        var newPort = UInt16(server?.port ?? Self.persistedPort)
        var clearedSessions = 0
        var revokedSession: String?

        // Revoke a specific session by id.
        if let sid = params?["revoke_session_id"]?.stringValue {
            let existed = AuthManager.shared.activeSessions.contains { $0.id == sid }
            AuthManager.shared.revokeSession(id: sid)
            revokedSession = existed ? sid : nil
            Self.logBuffer.append(existed ? "🧹 Revoked session \(sid)" : "⚠️ revoke_session_id not found")
        }

        // Clear all authorized sessions (revoke every token) if requested.
        if params?["clear_sessions"]?.boolValue == true {
            clearedSessions = AuthManager.shared.activeSessions.count
            AuthManager.shared.revokeAll()
            Self.logBuffer.append("🧹 Cleared all authorized sessions (\(clearedSessions))")
        }

        // Stop the whole service (ends the test / stops listening). Scheduled AFTER
        // this response is sent so the client still gets an acknowledgement. Tokens
        // persist, so a later relaunch doesn't require re-authorization.
        if params?["stop_server"]?.boolValue == true {
            Self.logBuffer.append("🛑 Stop requested via config — shutting down after reply")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { return }
                self.stopService("Stopping server (config stop_server)")
            }
            let restartHint = parksWhenStopped
                ? "Start it again from the LoopCtrl app or with loopctrl://start"
                : "Re-launch the LoopCtrl runner to start it again"
            return ([
                "message": .string("Server is shutting down. It will stop listening in ~1s. \(restartHint) (your token is preserved — no re-auth needed)."),
                "stopping": .bool(true),
            ], nil)
        }

        if let remote = params?["allow_remote_access"]?.boolValue {
            if remote != remoteAccessEnabled {
                remoteAccessEnabled = remote
                Self.persistedRemoteAccess = remote
                if !remote {             // nearby needs remote access
                    nearbyEnabled = false
                    Self.persistedNearby = false
                }
                restartNeeded = true
            }
        }

        // Nearby discovery (switching it on was checked above; off: anyone).
        var nearbyChange: Bool?
        if let nearby = params?["nearby_discovery"]?.boolValue, nearby != nearbyEnabled {
            nearbyChange = nearby            // validated above
        }

        // Name advertised to nearby clients; "" restores the default.
        if let newName = params?["device_name"]?.stringValue,
           let applied = NearbyIdentity.setName(newName) {     // length checked above
            Self.logBuffer.append("📡 Nearby name set to \"\(applied)\"")
            server?.refreshNearbyName()
        }

        if let portValue = params?["listen_port"]?.intValue {    // range checked above
            if UInt16(portValue) != newPort {
                newPort = UInt16(portValue)
                Self.persistedPort = UInt16(portValue)
                restartNeeded = true
            }
        }

        if let on = nearbyChange {
            nearbyEnabled = on
            Self.persistedNearby = on
            if on { nearbyPermissionRequested = false }
            Self.logBuffer.append(on ? "📡 Nearby discovery enabled via config" : "📴 Nearby discovery disabled via config")
            if !restartNeeded {
                if on { server?.startNearby() } else { server?.stopNearby() }
                let port = UInt16(server?.port ?? Self.persistedPort)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }
                    self.postStatusNotification(port: port)
                }
            }
        }

        if restartNeeded {
            // After the reply: stopping the listener now would also close the
            // connection this reply has yet to go out on.
            let port = newPort
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.server?.onStateChange = nil
                self.server?.stop()
                let newServer = JSONRPCServer(port: port, localOnly: !self.remoteAccessEnabled)
                self.wireNewServer(newServer)
                do {
                    try newServer.start()
                    if self.remoteAccessEnabled && self.nearbyEnabled { newServer.startNearby() }
                    Self.logBuffer.append("⚙️ Config applied, server restarted on port \(port)")
                    self.postStatusNotification(port: port)
                } catch {
                    Self.logBuffer.append("🔴 Config restart failed: \(error)")
                }
            }
        }

        let address = remoteAccessEnabled ? getDeviceAddress() : "127.0.0.1"
        let sessions = AuthManager.shared.activeSessions
        let iso = ISO8601DateFormatter()

        // The session id IS the token id (first 4 bytes of SHA256(K)) — a public
        // lookup handle, safe to list. The 32-byte key itself never leaves the
        // device after pairing, so there is nothing here to mask.
        let sessionList: [JSONValue] = sessions.map { s in
            .object([
                "session_id": .string(s.id),
                "client_name": .string(s.clientName),
                "tok": .string(s.id),
                "granted_at": .string(iso.string(from: s.grantedAt)),
                "last_active_at": .string(iso.string(from: s.lastActiveAt)),
                "expires_at": .string(iso.string(from: s.expiresAt)),
                "last_address": s.lastAddress.map(JSONValue.string) ?? .null,
                "last_via": s.lastVia.map(JSONValue.string) ?? .null,
                "relay_connection": s.relayConnection.map(JSONValue.string) ?? .null,
            ])
        }

        var result: [String: JSONValue] = [
            "allow_remote_access": .bool(remoteAccessEnabled),
            "listen_port": .int(Int(newPort)),
            "address": .string("\(address):\(newPort)"),
            "lan_addresses": .array(allReachableAddresses().map {
                .object(["label": .string($0.label), "address": .string($0.address)])
            }),
            "ipv4_interfaces": .array(Self.activeIPv4Interfaces().map {
                .object(["name": .string($0.name), "address": .string($0.address)])
            }),
            "restarted": .bool(restartNeeded),
            "device_name": .string(UIDevice.current.name),
            "nearby": .object([
                "enabled": .bool(nearbyEnabled),
                "advertising": .bool(server?.isNearbyAdvertising ?? false),
                "status": .string(nearbyEnabled ? (server?.nearbyStatus ?? .off).rawValue : "off"),
                "local_network": .string(Self.localNetworkAccess),
                "interface": NearbyAdvertiser.linkState().json,
                "name": .string(NearbyIdentity.name),
                "device_id": .string(NearbyIdentity.deviceID),
                "port": .int(Int(server?.nearbyPort ?? newPort + 1)),
            ]),
            "active_sessions": .int(sessions.count),
            "sessions": .array(sessionList),
            "cleared_sessions": .int(clearedSessions),
        ]
        if let revoked = revokedSession {
            result["revoked_session_id"] = .string(revoked)
        }
        // Who is asking to pair: for the app's card and list only, so not
        // shown to clients elsewhere on the network.
        if fromThisDevice {
            result["pairing"] = Self.pairingJSON()
            result["relay_preapprovals"] = .array(AuthManager.shared.relayPreApprovals.map {
                .object(["connection_id": .string($0.connectionID), "name": .string($0.operatorName),
                         "key_id": .string($0.keyID)])
            })
        }
        if let pairingAnswer {
            result["pairing_applied"] = .bool(pairingAnswer)
        }

        // Per-action timing stats (ms).
        let timing: [JSONValue] = Self.logBuffer.timingStats().map { s in
            .object([
                "method": .string(s["method"] as? String ?? ""),
                "count": .int(s["count"] as? Int ?? 0),
                "avg_ms": .int(s["avg_ms"] as? Int ?? 0),
                "min_ms": .int(s["min_ms"] as? Int ?? 0),
                "max_ms": .int(s["max_ms"] as? Int ?? 0),
            ])
        }
        result["timing"] = .array(timing)

        return (result, nil)
    }

    /// The pending and recent pairing requests, as `config` reports them.
    private static func pairingJSON() -> JSONValue {
        let (pending, recent) = AuthManager.shared.pairingRequests()
        let iso = ISO8601DateFormatter()
        let now = Date()
        func row(_ e: PairRequestLedger.Entry) -> JSONValue {
            var o: [String: JSONValue] = [
                "request_id": .string(e.id),
                "client_name": .string(e.clientName),
                "source": .string(e.source),
                "address": e.address.map(JSONValue.string) ?? .null,
                "fingerprint": e.fingerprint.map(JSONValue.string) ?? .null,
                "requested_at": .string(iso.string(from: e.requestedAt)),
                "outcome": .string(e.outcome.rawValue),
                "can_allow": .bool(e.canAllow(now: now)),
                "auto_approved": .bool(e.autoApproved),
            ]
            if e.outcome == .pending {
                o["deadline"] = .string(iso.string(from: e.deadline))
                o["seconds_left"] = .int(max(0, Int(e.deadline.timeIntervalSince(now).rounded(.up))))
            }
            if let resolved = e.resolvedAt { o["resolved_at"] = .string(iso.string(from: resolved)) }
            switch e.grant {
            case .none: o["grant"] = .string("none")
            case .armed(let until):
                o["grant"] = .string("armed")
                o["grant_until"] = .string(iso.string(from: until))
            case .used: o["grant"] = .string("used")
            }
            return .object(o)
        }
        return .object([
            "pending": .array(pending.map(row)),
            "recent": .array(recent.map(row)),
            "approval_timeout": .int(Int(AuthManager.approvalTimeout)),
            "recent_window": .int(Int(PairRequestLedger.recentWindow)),
        ])
    }

    private func wireNewServer(_ newServer: JSONRPCServer) {
        configureServerCallbacks(newServer)
        self.server = newServer
        wireServerStateChange()
    }

    /// True once a "Remote Access Failed" notification has been posted, so the
    /// didBecomeActive observer knows to re-verify when the user returns. Also
    /// guards against posting the failure notice twice for the same outage.
    private var reportedRemoteFailure = false

    /// Serializes reachability verification so overlapping triggers (startup,
    /// enable-remote, didBecomeActive) can't run concurrent checks / stack notes.
    private var verifyInFlight = false

    /// Whether we've already self-woken to the foreground for the current outage,
    /// so we don't repeatedly re-open the app.
    private var selfWokeForCurrentOutage = false

    /// The runner's own URL scheme, used to bring it back to the foreground so
    /// iOS can present the Local Network permission prompt (which only appears
    /// while the app is foreground).
    private static let selfWakeURL = URL(string: "loopctrl://start")!

    /// Holds the multicast connection alive briefly while it triggers the prompt.
    private var lnTriggerConnection: NWConnection?

    /// Bring the runner to the foreground via its own loopctrl:// scheme so iOS can
    /// present the Local Network permission prompt (it only appears while the app
    /// is foreground), THEN actually touch the LAN so the OS raises the prompt.
    /// Declaring NSLocalNetworkUsageDescription is not enough — iOS only prompts
    /// on a real local-network access, and a TCP connect to our OWN device IP can
    /// route internally without counting. Sending to the mDNS multicast group is
    /// unambiguous LAN activity, so that's what triggers the dialog. Runs at most
    /// once per outage; posts no notification (the failure notice is owned by
    /// verifyRemote…()).
    private func selfWakeForLocalNetworkPrompt() {
        guard !selfWokeForCurrentOutage else { return }
        selfWokeForCurrentOutage = true

        let woke = bringRunnerForward()
        Self.logBuffer.append(woke ? "🔼 runner brought forward (foreground for LN prompt)"
                                   : "⚠️ could not bring the runner forward")

        // Give the app ~1s to reach the foreground, then touch the LAN to raise
        // the permission prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.triggerLocalNetworkPrompt()
        }
    }

    /// Local Network access as last observed: "granted", "denied" or
    /// "unknown" (not answered yet / not observable). Reported by `config`.
    private static var localNetworkAccess: String {
        get { localNetworkLock.lock(); defer { localNetworkLock.unlock() }; return localNetworkValue }
        set { localNetworkLock.lock(); localNetworkValue = newValue; localNetworkLock.unlock() }
    }
    private static var localNetworkValue = "unknown"
    private static let localNetworkLock = NSLock()
    private var launchBrowser: NWBrowser?

    /// Ask for Local Network access while the runner is in front, right after
    /// launch, instead of waiting for a feature to be refused in the
    /// background — iOS shows the prompt only to the foreground app, and
    /// LAN clients connecting in work without it, so nothing else surfaces
    /// the gap. A short Bonjour browse for our own declared service type is
    /// the reliable trigger, and its outcome tells us the answer: still ready
    /// after a moment means granted, PolicyDenied means refused (iOS will not
    /// ask again; the user must switch it on in Settings).
    private func requestLocalNetworkAtLaunch() {
        probeLocalNetwork(for: 60)
    }

    /// Browse briefly and record what it says about Local Network access.
    /// `seconds`: how long to keep the browse (and so a prompt) open.
    private func probeLocalNetwork(for seconds: TimeInterval) {
        launchBrowser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: NearbyAdvertiser.serviceType, domain: "local."), using: .tcp)
        launchBrowser = browser
        // Whether THIS browse was refused; the stored state may still hold
        // an earlier answer.
        var refused = false
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch state {
                case .ready:
                    // Ready comes first even when access is refused — the
                    // refusal follows a moment later as a waiting state. So
                    // only a browse still ready after a pause counts.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak browser] in
                        guard let self = self, let browser = browser, !refused,
                              case .ready = browser.state else { return }
                        self.setLocalNetworkAccess("granted")
                    }
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        refused = true
                        self.setLocalNetworkAccess("denied")
                    }
                default:
                    break
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "top.ebato.loopctrl.ln-browse"))
        // Long enough for the user to answer the prompt; the browse itself
        // has no other job.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak browser] in
            guard let self = self, let browser = browser, self.launchBrowser === browser else { return }
            browser.cancel()
            self.launchBrowser = nil
        }
    }

    /// While refused, look again every 30 s: access switched on in Settings
    /// should clear the warning (and unblock nearby) without a relaunch.
    private func scheduleLocalNetworkRecheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, Self.localNetworkAccess == "denied" else { return }
            self.probeLocalNetwork(for: 5)
            self.scheduleLocalNetworkRecheck()
        }
    }

    private func setLocalNetworkAccess(_ value: String) {
        guard Self.localNetworkAccess != value else { return }
        Self.localNetworkAccess = value
        Self.logBuffer.append(value == "granted"
            ? "🌐 Local Network access: granted"
            : "🚫 Local Network access: denied — LAN clients can still connect in, but nearby discovery "
              + "cannot advertise. Allow it in Settings › Privacy & Security › Local Network › LoopCtrlUITests-Runner")
        // Granted just now (the prompt was answered): don't make a waiting
        // nearby registration sit out its back-off.
        if value == "granted" { server?.retryNearbyNow() } else { scheduleLocalNetworkRecheck() }
    }

    /// Set once nearby discovery has asked for Local Network access since it
    /// was last switched on, so a refusal doesn't keep pulling the runner
    /// to the front.
    private var nearbyPermissionRequested = false

    /// A refused nearby registration usually means Local Network access was
    /// never granted. iOS refuses a background app's Bonjour registration
    /// without asking, and nothing else may have asked: the remote-access
    /// self-check connects to the device's own address, which needs no
    /// permission, and on cellular it is skipped. So bring the runner to the
    /// front — the prompt only appears there — touch the LAN, and retry the
    /// registration while it is in front, which raises the prompt if the
    /// question is still open. Once per enable: after an explicit refusal iOS
    /// never asks again, and the status notification says what is needed.
    private func requestLocalNetworkForNearby() {
        guard nearbyEnabled, !nearbyPermissionRequested else { return }
        nearbyPermissionRequested = true
        let woke = bringRunnerForward()
        Self.logBuffer.append(woke
            ? "📡 Nearby refused (Local Network) — bringing the runner forward to request access"
            : "⚠️ Nearby refused (Local Network) and the runner could not come forward to ask")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.triggerLocalNetworkPrompt()
            self?.server?.retryNearbyNow()
        }
    }

    /// Put the runner in front, where iOS can show it a permission prompt.
    /// By bundle id, like tapping its icon: opening its own `loopctrl://` scheme
    /// is refused (the XCTest daemon will not hand a runner its own URL), so
    /// that is only the fallback.
    private func bringRunnerForward() -> Bool {
        if let id = Bundle.main.bundleIdentifier, ForegroundApp.openBundleID(id) { return true }
        return ForegroundApp.open(Self.selfWakeURL)
    }

    /// Send a datagram to the mDNS multicast group (224.0.0.251:5353) — real
    /// local-network activity that makes iOS present the Local Network permission
    /// prompt while the app is foreground. Held briefly, then torn down.
    private func triggerLocalNetworkPrompt() {
        let host = NWEndpoint.Host("224.0.0.251")
        guard let port = NWEndpoint.Port(rawValue: 5353) else { return }
        let conn = NWConnection(host: host, port: port, using: .udp)
        lnTriggerConnection = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                conn.send(content: Data([0]), completion: .contentProcessed { _ in })
                Self.logBuffer.append("🌐 LAN prompt trigger sent (mDNS multicast) — grant Local Network if asked")
            case .failed, .cancelled:
                self?.lnTriggerConnection = nil
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue(label: "top.ebato.loopctrl.ln-trigger"))
        // Tear down after a few seconds — its only job is to raise the dialog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.lnTriggerConnection?.cancel()
            self?.lnTriggerConnection = nil
        }
    }

    /// Fixed identifier for the "Remote Access Failed" notification so it can be
    /// removed once access starts working.
    private static let remoteFailedNotifID = "loopctrl.remote.failed"

    /// Fixed identifier for the "server is running" notification.
    ///
    /// Fixed, because that notification is the control surface: its long-press
    /// actions are how you toggle remote access or stop the server. Posted under
    /// a fresh UUID each time it would pile up as duplicates and, worse, sink out
    /// of reach as other apps deliver — exactly when you want to shut LoopCtrl off.
    /// Re-posting under the SAME id replaces the old one and refreshes its
    /// delivery time, which is what floats it back to the top.
    private static let serverReadyNotifID = "loopctrl.server.ready"

    /// Title shared by the service's notifications; what happened goes in the
    /// subtitle. In the two-app build they come from the runner, whose own name
    /// iOS shows above them, so the title is what says they are LoopCtrl's.
    private static let notificationTitle = "LoopCtrl"

    /// Notification Centre groups by thread: service status and failures in
    /// one stack, pairing requests (which need an answer) in their own.
    private static let statusThreadID = "loopctrl.status"
    private static let pairingThreadID = "loopctrl.pairing"

    private func sendNotification(subtitle: String, body: String, category: String? = nil,
                                  identifier: String? = nil, silent: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = Self.notificationTitle
        content.subtitle = subtitle
        content.body = body
        content.threadIdentifier = Self.statusThreadID
        // Silent refreshes go in the list WITHOUT a banner: .passive is
        // documented as "Added to the notification list; does not light up
        // screen or play sound". That matters more than the sound — a banner
        // appearing every few minutes covers whatever is on screen and invites
        // a mis-tap, which on a phone being driven by automation is a real way
        // to break a run.
        content.sound = silent ? nil : .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = silent ? .passive : .active
        }
        if let category = category {
            content.categoryIdentifier = category
        }

        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Remote viewing notification

    /// What the remote notification last said, so it is replaced only when
    /// that changes.
    private var remoteNotice = ""
    /// The banner already went up for this spell of remote use: everything
    /// after it updates the notification silently.
    private var remoteBannerShown = false
    /// When the last person left; the notification stays a little longer, so
    /// a reload or a quality switch doesn't end the spell and alert again.
    private var remoteQuietSince: Date?
    private var remoteWatchTimer: Timer?
    private static let remoteGrace: TimeInterval = 30
    /// When this spell of remote use began, for the Live Activity's clock.
    private var remoteSpellStart: Date?

    /// Who is watching and operating, with Pause; or "paused", with Resume.
    /// One banner when remote use starts; changes after that (who operates,
    /// how many watch) replace it without a banner or a sound. Shown by the
    /// Live Activity where it is up, by a notification otherwise.
    private func updateRemoteNotification() {
        let session = RemoteSession.shared
        session.sweep()
        let present = session.present()
        let paused = session.paused
        let now = Date()
        let live = RemoteLiveActivity.shared

        if !paused && present.isEmpty {
            live.show([], paused: false, since: nil, alert: nil)
            guard !remoteNotice.isEmpty else { return stopRemoteWatch() }
            let quiet = remoteQuietSince ?? now
            remoteQuietSince = quiet
            startRemoteWatch()
            guard now.timeIntervalSince(quiet) >= Self.remoteGrace else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.remoteNotificationID])
            remoteNotice = ""
            remoteBannerShown = false
            remoteQuietSince = nil
            remoteSpellStart = nil
            return stopRemoteWatch()
        }
        remoteQuietSince = nil
        if remoteSpellStart == nil { remoteSpellStart = now }
        startRemoteWatch()

        let subtitle: String
        if paused {
            subtitle = L10n.t(.remotePaused)
        } else {
            let operators = present.filter(\.operating).map { entry -> String in
                let p = entry.participant
                return p.kind == .agent ? "🤖 " + p.name : p.name
            }
            let watchers = present.filter { $0.participant.watching > 0 }.count
            var parts: [String] = []
            if !operators.isEmpty { parts.append(String(format: L10n.t(.remoteOperating), operators.joined(separator: ", "))) }
            if watchers > 0 { parts.append(String(format: L10n.t(.remoteWatchers), String(watchers))) }
            subtitle = operators.isEmpty && watchers <= 1 ? L10n.t(.remoteWatched) : parts.joined(separator: " · ")
        }
        guard subtitle != remoteNotice else { return }
        remoteNotice = subtitle
        let banner = !remoteBannerShown && !paused
        remoteBannerShown = true
        if live.show(present, paused: paused, since: remoteSpellStart, alert: banner ? subtitle : nil) {
            // The Live Activity says it all, Pause included.
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.remoteNotificationID])
            return
        }
        if paused {
            sendNotification(subtitle: subtitle, body: L10n.t(.remotePausedBody),
                             category: Self.remotePausedCategoryID, identifier: Self.remoteNotificationID, silent: true)
        } else {
            sendNotification(subtitle: subtitle, body: L10n.t(.remoteWatchedBody),
                             category: Self.remoteCategoryID, identifier: Self.remoteNotificationID, silent: !banner)
        }
    }

    /// Operators lapse quietly (nobody calls when they stop), and the grace
    /// period runs out on its own: look again every few seconds meanwhile.
    private func startRemoteWatch() {
        guard remoteWatchTimer == nil else { return }
        remoteWatchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.updateRemoteNotification()
        }
    }

    private func stopRemoteWatch() {
        remoteWatchTimer?.invalidate()
        remoteWatchTimer = nil
    }

    /// Timer that re-posts the status notification so it stays reachable.
    private var statusRefreshTimer: Timer?

    /// Re-post the status notification on a timer, keeping it near the top of
    /// Notification Centre and showing live state.
    ///
    /// Re-posting under the same identifier replaces the entry and refreshes its
    /// delivery time, which is what floats it back up. The refresh is `.passive`
    /// so it never draws a banner or a sound — it only reorders the list.
    ///
    /// Five minutes, not one: with no banner the only cost is a list reorder, and
    /// what actually matters is being near the top WHEN you go looking. Anything
    /// delivered in between pushes LoopCtrl down by at most a few rows in that
    /// window, while a shorter interval just burns wakeups on a run loop that is
    /// otherwise idle.
    private func startStatusRefresh(on runLoop: RunLoop) {
        statusRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.refreshStatusNotification()
        }
        // Added to the run loop the runner actually blocks on, in the same mode
        // as the existing safety timer. `Timer.scheduledTimer` would attach to
        // whichever run loop the caller happens to be on — which, off the main
        // thread, is one that never runs, so the timer would never fire.
        runLoop.add(timer, forMode: .default)
        statusRefreshTimer = timer
        Self.logBuffer.append("🔔 status notification refreshes every 5min (passive)")
    }

    /// Uptime reading captured when the server started, so the status line can
    /// report how long it has been up.
    private static var serverStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// Marker + address last shown, so a network change reposts only when the
    /// notification would actually read differently.
    private var lastNetworkSignature = ""

    /// Wi-Fi joining or leaving, a VPN starting or stopping: re-check nearby
    /// discovery and update the status notification right away. (Wi-Fi being
    /// switched off without a path change is caught by the advertiser's own
    /// interface polling.)
    private func observeNetworkChanges() {
        NetworkTypeMonitor.shared.observe { [weak self] type in
            DispatchQueue.main.async {
                guard let self = self, self.remoteAccessEnabled else { return }
                self.server?.recheckNearby()
                let signature = self.statusLines.joined(separator: "/") + "|" + (self.lanAddress() ?? "-")
                guard signature != self.lastNetworkSignature else { return }
                let first = self.lastNetworkSignature.isEmpty
                self.lastNetworkSignature = signature
                guard !first else { return }
                Self.logBuffer.append("🌐 Network changed (\(type.rawValue)) — LAN \(self.lanAddress() ?? "none")")
                self.refreshStatusNotification()
            }
        }
    }

    private func refreshStatusNotification() {
        // Parked (all-in-one, service stopped): nothing to advertise.
        guard let port = server?.port else { return }
        let sessions = AuthManager.shared.activeSessions.count
        let mins = Int(ProcessInfo.processInfo.systemUptime - Self.serverStartedAt) / 60
        let human = mins < 60 ? "\(mins)m" : "\(mins / 60)h\(mins % 60)m"
        postStatusNotification(
            port: port,
            footer: String(format: L10n.t(.statusUptime), sessions, human),
            silent: true
        )
    }

    // MARK: - Status notification

    /// Who can connect right now, then, while nearby discovery is switched on,
    /// whether it actually works and, if not, what is missing — the menu already
    /// shows that it is on, so saying nothing would contradict it.
    private var statusLines: [String] {
        guard remoteAccessEnabled else { return [L10n.t(.statusLocal)] }
        var lines = [lanAddress() != nil ? L10n.t(.statusLAN) : L10n.t(.statusNoLAN)]
        if nearbyEnabled {
            switch server?.nearbyStatus ?? .off {
            case .advertising: lines.append(String(format: L10n.t(.statusNearby), NearbyIdentity.name))
            case .needsWiFi:   lines.append(L10n.t(.nearbyNeedsWiFi))
            case .denied:      lines.append(L10n.t(.nearbyNeedsPermission))
            case .failed:      lines.append(L10n.t(.nearbyNotReady))
            case .starting, .off: lines.append(L10n.t(.nearbyStarting))
            }
        }
        return lines
    }

    /// Category, and so the long-press menu, for the current state.
    private var statusCategory: String {
        guard remoteAccessEnabled else { return Self.serverReadyCategoryID }
        return nearbyEnabled ? Self.serverNearbyCategoryID : Self.serverRemoteCategoryID
    }

    /// Post (or replace) the status notification.
    ///
    /// Subtitle: "Running · <address>", the LAN address while remote access is
    /// on and there is one, else loopback. Body: `note` (what just changed, if
    /// anything), who can connect, the nearby state, any further LAN addresses,
    /// then `footer`.
    private func postStatusNotification(port: UInt16, note: String? = nil, footer: String? = nil,
                                        silent: Bool = false) {
        let host = remoteAccessEnabled ? getDeviceAddress() : "127.0.0.1"
        var lines: [String] = []
        if let note { lines.append(note) }
        lines += statusLines
        if remoteAccessEnabled { lines += otherAddressLines(port: port) }
        if let footer { lines.append(footer) }
        sendNotification(subtitle: String(format: L10n.t(.statusRunning), "\(host):\(port)"),
                         body: lines.joined(separator: "\n"), category: statusCategory,
                         identifier: Self.serverReadyNotifID, silent: silent)
    }

    /// Turn nearby discovery on or off. Only possible while remote access is on.
    private func setNearby(_ on: Bool) {
        guard remoteAccessEnabled || !on else {
            Self.logBuffer.append("📡 Nearby discovery needs remote access — ignored")
            return
        }
        nearbyEnabled = on
        Self.persistedNearby = on
        if on { nearbyPermissionRequested = false }
        if on { server?.startNearby() } else { server?.stopNearby() }
        // Advertising normally confirms within a moment; the state callback
        // posts again when it does. Refresh now so the menu flips immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.postStatusNotification(port: self.server?.port ?? Self.persistedPort)
        }
    }

    /// Remove the "Remote Access Failed" notification (pending + already-delivered).
    private func clearRemoteFailedNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.remoteFailedNotifID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.remoteFailedNotifID])
    }

    private func enableRemoteAccess() {
        guard !remoteAccessEnabled else { return }
        server?.onStateChange = nil
        server?.stop()
        remoteAccessEnabled = true
        Self.persistedRemoteAccess = true  // remember for next launch

        let newServer = JSONRPCServer(port: Self.persistedPort, localOnly: false)
        wireNewServer(newServer)

        do {
            try newServer.start()
            announceRemoteReady(address: getDeviceAddress())
        } catch {
            Self.logBuffer.append("🔴 Failed to enable remote access: \(error)")
        }
    }

    /// Decide how to announce remote access based on the network type:
    /// - Wi-Fi / wired → the address is LAN-reachable, so self-check it (which also
    ///   raises the Local Network permission prompt if needed) and post
    ///   success/failure accordingly.
    /// - Cellular → the address is a public/CGNAT one that ISN'T reachable from
    ///   outside and has no Local Network concept; a self-check would always
    ///   "fail". So skip the check entirely, don't touch the LAN / trigger any
    ///   permission, and just tell the user it's on-device only. No error.
    private func announceRemoteReady(address: String) {
        let net = NetworkTypeMonitor.shared.current
        if lanAddress() != nil {
            Self.logBuffer.append("🌐 Server started on \(address):\(server?.port ?? Self.persistedPort) (remote, \(net.rawValue)) — verifying reachability")
            verifyRemoteReachableThenNotify(address: address)
        } else {
            // Cellular / undetermined: no LAN, so no self-check and no failure.
            Self.logBuffer.append("📶 Server started on \(address):\(server?.port ?? Self.persistedPort) (\(net.rawValue) — on-device only, skipping remote self-check)")
            // Clear any stale failure notice from a previous Wi-Fi session.
            reportedRemoteFailure = false
            clearRemoteFailedNotification()
            // The status lines say "Not on Wi-Fi · only this device can connect".
            postStatusNotification(port: server?.port ?? Self.persistedPort)
        }
    }

    private func disableRemoteAccess() {
        guard remoteAccessEnabled else { return }
        server?.onStateChange = nil
        server?.stop()                      // also closes the nearby listener
        remoteAccessEnabled = false
        Self.persistedRemoteAccess = false  // remember for next launch
        nearbyEnabled = false               // nearby needs remote access
        Self.persistedNearby = false

        let newServer = JSONRPCServer(port: Self.persistedPort, localOnly: true)
        wireNewServer(newServer)

        do {
            try newServer.start()
            Self.logBuffer.append("🔒 Remote access disabled, local only")
            postStatusNotification(port: newServer.port, note: L10n.t(.remoteDisabledNote))
        } catch {
            Self.logBuffer.append("🔴 Failed to disable remote access: \(error)")
        }
    }

    /// "New connection request", subtitle "“name” · LAN / nearby / this device",
    /// body the key fingerprint first — a banner truncates the body, and the key
    /// is what to check before allowing.
    private func sendAuthNotification(clientName: String, requestID: String, nearby: Bool, local: Bool,
                                      fingerprint: String?) {
        let content = UNMutableNotificationContent()
        content.title = L10n.t(.authRequestTitle)
        let source: L10n.Key = nearby ? .authFromNearby : (local ? .authFromLocal : .authFromLAN)
        content.subtitle = String(format: L10n.t(source), clientName)
        var lines: [String] = []
        if let fingerprint { lines.append(String(format: L10n.t(.authKeyLine), fingerprint)) }
        lines.append(L10n.t(.authRequestBody))
        content.body = lines.joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = Self.pairingThreadID
        content.categoryIdentifier = Self.authCategoryID

        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// How many addresses a notification will list before stopping.
    private static let maxAdvertisedAddresses = 3

    /// LAN addresses a peer can reach this device at, best first: Wi-Fi, then
    /// the Personal Hotspot bridge, then wired adapters.
    ///
    /// Only physical LAN interfaces count. Tunnels (`utun*`, `ipsec*`, `ppp*`)
    /// belong to VPNs and proxy apps — a proxy's TUN interface typically holds
    /// a placeholder such as 198.18.0.1 that nobody else can reach — and
    /// cellular (`pdp_ip*`) is carrier NAT. Peer-to-peer (`awdl*`, `llw*`) and
    /// USB host links (`anpi*`) are not a LAN either. Link-local and
    /// benchmark-range (198.18.0.0/15) addresses are skipped on any interface.
    ///
    /// Returns `(label, address)` pairs so the notification can say which is
    /// which rather than listing bare numbers. Empty means no LAN at all.
    private func allReachableAddresses() -> [(label: String, address: String)] {
        var found: [(rank: Int, label: String, address: String)] = []
        for (name, address, raw) in Self.activeIPv4Interfaces() {
            let (rank, label): (Int, String)
            if name == "en0" {
                (rank, label) = (0, "Wi-Fi")
            } else if name.hasPrefix("bridge") {
                (rank, label) = (1, "Hotspot")
            } else if name.hasPrefix("en") {
                (rank, label) = (2, name)
            } else {
                continue
            }
            guard raw != 0,
                  raw & 0xFFFF_0000 != 0xA9FE_0000,   // 169.254.0.0/16 link-local
                  raw & 0xFFFE_0000 != 0xC612_0000    // 198.18.0.0/15 placeholder range
            else { continue }
            found.append((rank, label, address))
        }
        // A notification has room for a few lines, not an interface dump.
        return found.sorted { $0.rank < $1.rank }
                    .prefix(Self.maxAdvertisedAddresses)
                    .map { ($0.label, $0.address) }
    }

    /// Every up, running, non-loopback IPv4 interface: (name, dotted address,
    /// address as a host-order integer). Unfiltered — also reported by
    /// `config` so a wrong address choice can be diagnosed.
    static func activeIPv4Interfaces() -> [(name: String, address: String, raw: UInt32)] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var result: [(name: String, address: String, raw: UInt32)] = []
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = interface.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append((String(cString: interface.ifa_name), String(cString: hostname), raw))
        }
        return result
    }

    /// The best LAN address, or nil when the device has none (cellular only,
    /// or only a VPN/proxy tunnel).
    private func lanAddress() -> String? {
        allReachableAddresses().first?.address
    }

    /// LAN addresses after the first, one labelled line each, for the status
    /// body (the first is in the subtitle). Usually none: the common single
    /// Wi-Fi case stays terse. With no LAN there are none either — never a
    /// tunnel or cellular address in their place.
    private func otherAddressLines(port: UInt16) -> [String] {
        allReachableAddresses().dropFirst().map { "\($0.label) \($0.address):\(port)" }
    }

    /// The single address for places that need exactly one: the LAN address,
    /// else loopback.
    private func getDeviceAddress() -> String {
        lanAddress() ?? "127.0.0.1"
    }

    /// After enabling remote access, confirm the LAN address is actually reachable
    /// before telling the user it's ready. If Local Network permission is denied,
    /// iOS binds the listener but silently blocks LAN connections — so a TCP
    /// connect to our own LAN address FAILS even though the server is "up". We do
    /// this self-check with a 1s timeout and post the appropriate notification:
    /// success → "Server Ready"; failure → "Remote Access Failed" (likely the
    /// Local Network permission — the user must open the app to grant it).
    /// `announceSuccess` controls whether a reachable result posts a "Server
    /// Ready" notification. First check after enabling remote access: yes. The
    /// re-check on didBecomeActive only announces if it's RECOVERING from a prior
    /// failure (so we don't ping "Ready" every time the app is foregrounded).
    private func verifyRemoteReachableThenNotify(address: String, announceSuccess: Bool = true) {
        // Serialize: overlapping triggers must not run concurrent checks.
        guard !verifyInFlight else {
            Self.logBuffer.append("🌐 reachability check already in flight — skipping duplicate")
            return
        }
        // No usable LAN address (e.g. Wi-Fi down) — can't verify or reach remotely.
        guard address != "127.0.0.1", !address.isEmpty else {
            Self.logBuffer.append("🌐 no LAN address available — skipping remote reachability check")
            return
        }
        // Authoritative gate: only self-check on a LAN (Wi-Fi/wired). On cellular
        // the address is public/CGNAT and unreachable from outside — a check would
        // always "fail", so skip it and never post a failure there.
        guard lanAddress() != nil else {
            Self.logBuffer.append("📶 not on LAN (\(NetworkTypeMonitor.shared.current.rawValue)) — skipping remote reachability check")
            return
        }
        verifyInFlight = true
        let portNum = UInt16(server?.port ?? Self.persistedPort)
        let wasFailed = reportedRemoteFailure
        selfConnectCheck(host: address, port: portNum, timeout: 1.0) { [weak self] ok in
            guard let self = self else { return }
            self.verifyInFlight = false

            if ok {
                Self.logBuffer.append("🌐 Remote reachability OK on \(address):\(portNum)")
                // Recovered (or first success): clear any failure notice, reset
                // outage state. Announce success on the first check, or when we're
                // recovering from a previously-reported failure.
                let recovering = self.reportedRemoteFailure
                self.reportedRemoteFailure = false
                self.selfWokeForCurrentOutage = false
                self.clearRemoteFailedNotification()
                if announceSuccess || recovering {
                    self.postStatusNotification(port: portNum)
                }
            } else {
                Self.logBuffer.append("🔴 Remote reachability FAILED on \(address):\(portNum) — likely Local Network permission")
                // Post the failure notice only once per outage (fixed id means a
                // repeat would just replace it, but skipping avoids re-alerting).
                if !wasFailed {
                    self.reportedRemoteFailure = true
                    self.sendNotification(
                        subtitle: String(format: L10n.t(.remoteFailedSubtitle), "\(address):\(portNum)"),
                        body: L10n.t(.remoteFailedBody),
                        identifier: Self.remoteFailedNotifID
                    )
                }
                // Bring the app forward so iOS can present the permission prompt
                // (once per outage). No extra notification here.
                self.selfWakeForLocalNetworkPrompt()
            }
        }
    }

    /// TCP-connect to host:port with a timeout, calling `completion(reachable)`
    /// on the main queue exactly once. Used to self-test LAN reachability.
    private func selfConnectCheck(host: String, port: UInt16, timeout: TimeInterval,
                                  completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { completion(false); return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        var finished = false
        let finish: (Bool) -> Void = { ok in
            if finished { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async { completion(ok) }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            // Don't fail immediately on .waiting: a healthy listener that's still
            // coming up briefly waits then goes ready, whereas a permission-blocked
            // connect stays waiting — so let the timeout be the arbiter for waiting.
            default: break
            }
        }
        conn.start(queue: DispatchQueue(label: "top.ebato.loopctrl.reachcheck"))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}

// MARK: - AuthManagerDelegate

extension LoopCtrlUITests: AuthManagerDelegate {
    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String, requestID: String,
                     nearby: Bool, fingerprint: String?, completion: @escaping (Bool) -> Void) {
        authManager(manager, didReceiveAuthRequest: clientName, requestID: requestID,
                    nearby: nearby, local: false, fingerprint: fingerprint, completion: completion)
    }

    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String, requestID: String,
                     nearby: Bool, local: Bool, fingerprint: String?, completion: @escaping (Bool) -> Void) {
        authLock.lock()
        pendingAuthCompletions[requestID] = completion
        currentAuthRequestID = requestID
        authLock.unlock()

        Self.logBuffer.append("🔐 Auth request from \"\(clientName)\"\(nearby ? " (nearby device)" : "")")
        sendAuthNotification(clientName: clientName, requestID: requestID, nearby: nearby, local: local,
                             fingerprint: fingerprint)
    }

    func authManager(_ manager: AuthManager, didWithdrawAuthRequest clientName: String, requestID: String) {
        authLock.lock()
        if currentAuthRequestID == requestID { currentAuthRequestID = nil }
        pendingAuthCompletions.removeValue(forKey: requestID)
        authLock.unlock()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    func authManager(_ manager: AuthManager, didExpireAuthRequest clientName: String, requestID: String) {
        authLock.lock()
        if currentAuthRequestID == requestID { currentAuthRequestID = nil }
        pendingAuthCompletions.removeValue(forKey: requestID)
        authLock.unlock()
        Self.logBuffer.append("⌛ Auth request from \"\(clientName)\" expired without an answer")
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }
}

extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}

/// A lock-guarded flag, for state one queue writes and another reads.
private final class Atomic<T> {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
