import Foundation
import Darwin
import UIKit

/// Starts the XCUITest server inside THIS process — the all-in-one build, where
/// LoopCtrl.app carries `PlugIns/LoopCtrlUITests.xctest` and there is no separate
/// runner app. SPIKE: compiles, never run on a device (docs/runner-merge-spike.md).
///
/// Why it can work at all: the separate runner is Apple's XCTRunner stub, and
/// all that stub does when tapped on the Home Screen is (disassembled, Xcode 27):
///
///     XCTCommandLineToolHelper configurationFromCommandLineArguments:…
///         → XCTestConfigurationLoader: no environment, so take the newest
///           `Bundle.main.builtInPlugInsURL/*.xctest` and synthesize a
///           configuration for it (UI testing on if its Info.plist says
///           XCTContainsUITests)
///     _XCTestMain(configuration)            ← never returns; ends in exit()
///
/// performed from a CFRunLoopPerformBlock on the main run loop. Nothing in that
/// chain, nor in testmanagerd, looks at the main executable's name or bundle id;
/// only `Bundle.main` matters. So once the DDI is mounted this process can do the
/// same steps itself. The one thing the stub has that this app must not is a
/// hard link to XCTest.framework — that is what kills the runner in dyld when no
/// DDI is mounted — so XCTest is dlopen'd here, after the mount.
enum InProcessRunner {

    enum Failure: LocalizedError {
        case notMounted
        case noTestBundle
        case load(String)
        case missingSymbol(String)
        case configuration(String)

        var errorDescription: String? {
            switch self {
            case .notMounted: return "The Developer Disk Image isn't mounted."
            case .noTestBundle: return "This build has no PlugIns/LoopCtrlUITests.xctest."
            case .load(let why): return "XCTest could not be loaded: \(why)"
            case .missingSymbol(let name): return "XCTest on this device has no \(name)."
            case .configuration(let why): return "No test configuration: \(why)"
            }
        }
    }

    /// Set before the test bundle loads, so its +load and test body know they
    /// share a process with the LoopCtrl UI (no self-backgrounding, no delegate
    /// swizzling — see EarlyURLHook.m).
    static let environmentKey = "LOOPCTRL_IN_PROCESS"

    /// XCTest can be bootstrapped once per process: a second _XCTestMain aborts
    /// on "shared symbolication service already set" (the crash EarlyURLHook.m
    /// documents). So the test is never allowed to end in this build: Stop
    /// parks it with its listener closed (`stop()`), and a later `start()`
    /// reopens the listener on the same test.
    private(set) static var bootstrapped = false

    static var testBundleURL: URL? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("LoopCtrlUITests.xctest"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Loads XCTest from the mounted image and hands the main thread to it.
    ///
    /// Returns once the hand-off is scheduled. The test itself starts on a
    /// later main-run-loop turn and from then on owns the bottom of the main
    /// thread (its distantFuture run loop); the UI keeps running inside it.
    ///
    /// Once bootstrapped, starting again (after `stop()`) does not touch XCTest
    /// at all: the test is still there, parked, and is asked to bring its
    /// listener back up.
    static func start() throws {
        precondition(Thread.isMainThread)
        if bootstrapped {
            enqueue(startURL)
            return
        }

        let ddi = DeveloperDiskImage.status()
        guard ddi.isMounted else { throw Failure.notMounted }
        guard let bundleURL = testBundleURL else { throw Failure.noTestBundle }

        try loadXCTest()
        setenv(environmentKey, "1", 1)

        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_XCTestMain") else {
            throw Failure.missingSymbol("_XCTestMain")
        }
        typealias XCTestMain = @convention(c) (AnyObject?) -> Void
        let xctestMain = unsafeBitCast(sym, to: XCTestMain.self)
        let configuration = try makeConfiguration(testBundleURL: bundleURL)

        bootstrapped = true
        holdBackgroundTaskUntilTestStarts()
        // Same hand-off as -[_XCTRunnerAppDelegate runTestsInBackground:]: a run
        // loop block rather than a dispatch block. The test never returns, and
        // the main queue does not drain re-entrantly — started from inside a
        // main-queue block, every DispatchQueue.main.sync the server makes would
        // wait forever. A run-loop block runs on a turn of its own, whatever
        // context start() was called from.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            xctestMain(configuration)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // MARK: - Loading

    /// The image's own install names are absolute (/System/Developer/…), so
    /// dlopen'ing XCTest pulls in XCTestCore, XCUIAutomation and
    /// XCTAutomationSupport by itself. The test bundle, on the other hand,
    /// links `@rpath/XCTest.framework` and `@rpath/libXCTestSwiftSupport.dylib`,
    /// which is why the all-in-one target copies XCTRunner's LC_RPATHs.
    private static func loadXCTest() throws {
        // The install-name path first: loading the same file again through the
        // cryptex alias could map a second copy of every image.
        var errors: [String] = []
        for layout in [DeveloperDiskImage.Layout.system, .legacy, .cryptex] {
            let path = layout.frameworkPath + "/XCTest"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
                // …/Developer/Library/Frameworks/XCTest.framework → …/Developer
                var developer = URL(fileURLWithPath: layout.frameworkPath)
                for _ in 0..<3 { developer.deleteLastPathComponent() }
                // Swift test bundles link this too. Optional: absent on old images.
                _ = dlopen(developer.path + "/usr/lib/libXCTestSwiftSupport.dylib", RTLD_NOW | RTLD_GLOBAL)
                return
            }
            errors.append(dlerror().map { String(cString: $0) } ?? path)
        }
        throw Failure.load(errors.isEmpty ? "no XCTest.framework on disk" : errors.joined(separator: "; "))
    }

    // MARK: - Configuration

    private static func makeConfiguration(testBundleURL: URL) throws -> AnyObject {
        // 1. Exactly what the runner stub does (iOS 17+ images have the helper).
        //    Passing the bundle path as the last argument pins the bundle
        //    instead of relying on "newest .xctest in PlugIns".
        if let helper = NSClassFromString("XCTCommandLineToolHelper") {
            let sel = NSSelectorFromString("configurationFromCommandLineArguments:userDefaults:requiresTestBundleURL:outError:")
            if let method = class_getClassMethod(helper, sel) {
                typealias Fn = @convention(c) (AnyClass, Selector, NSArray, UserDefaults, Bool,
                                               UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
                let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
                var error: NSError?
                if let config = fn(helper, sel, [testBundleURL.path] as NSArray, .standard, false, &error) {
                    return config.takeUnretainedValue()
                }
                if let error { throw Failure.configuration(error.localizedDescription) }
            }
        }
        // 2. Older images: build what -[XCTestConfigurationLoader
        //    _synthesizedConfigurationForTestBundle:] builds.
        guard let cls = NSClassFromString("XCTestConfiguration") as? NSObject.Type else {
            throw Failure.missingSymbol("XCTestConfiguration")
        }
        let config = cls.init()
        config.setValue(testBundleURL, forKey: "testBundleURL")
        config.setValue(true, forKey: "initializeForUITesting")
        config.setValue(true, forKey: "reportActivities")
        return config
    }
}

// MARK: - URLs

extension InProcessRunner {
    /// URLs waiting for the test bundle to load (it loads inside _XCTestMain,
    /// a run-loop turn or more after start(), and later still if the "Enable
    /// UI Automation" passcode prompt is up).
    private static var undelivered: [URL] = []
    private static var deliveryTimer: Timer?

    /// An `loopctrl://` URL opened at this app. Before the bootstrap only `start`
    /// means anything; after it, the test's own URL handling takes over — the
    /// queue the runner's delegate hooks fill, reached by class name because
    /// the app does not link the test bundle.
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "loopctrl" else { return }
        if !bootstrapped {
            guard url.host?.lowercased() == "start" else { return }
            do { try start() } catch { loopctrlLog("In-process start failed: \(error.localizedDescription)") }
        }
        // Queued even for the start URL: it carries the callback the caller
        // waits for, and the test answers it once the server is up. After a
        // stop it is also what restarts the parked test's listener.
        enqueue(url)
    }

    /// Stop serving without leaving the app.
    ///
    /// The test that hosts the server lives in this process, and XCTest calls
    /// exit() when a test returns, so ending it would close LoopCtrl (and a
    /// second bootstrap in the same process aborts). In this build the test
    /// therefore only shuts its listener down on `loopctrl://stop` and stays
    /// parked; `start()` brings it back. No callback: there is no other app
    /// to return to.
    static func stop() {
        guard bootstrapped else { return }
        enqueue(stopURL)
    }

    private static let startURL = URL(string: "loopctrl://start")!
    private static let stopURL = URL(string: "loopctrl://stop")!

    private static func enqueue(_ url: URL) {
        undelivered.append(url)
        deliverPending()
    }

    private static func deliverPending() {
        guard let hook = NSClassFromString("EarlyURLHook") as? NSObject.Type else {
            // Default mode on purpose: the test's distantFuture loop runs in it.
            if deliveryTimer == nil {
                let timer = Timer(timeInterval: 0.5, repeats: true) { _ in deliverPending() }
                RunLoop.main.add(timer, forMode: .default)
                deliveryTimer = timer
            }
            return
        }
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        let urls = undelivered
        undelivered.removeAll()
        for url in urls { hook.perform(NSSelectorFromString("deliverURL:"), with: url) }
    }
}

// MARK: - Staying alive through the bootstrap

extension InProcessRunner {
    /// Posted by the test bundle's EarlyURLHook once testStartServer begins
    /// (name shared as a string: this app does not link the bundle).
    private static let testStartedNotification = Notification.Name("LoopCtrlInProcessTestStarted")
    private static var bootstrapTask: UIBackgroundTaskIdentifier = .invalid
    private static var testStartedObserver: NSObjectProtocol?

    /// The runner stub holds a "XCTRunner Initialization" process assertion
    /// from launch until XCTest's testBundleWillStart; after that testmanagerd
    /// keeps the test process alive. This app has no such assertion, so
    /// leaving it during the bootstrap (the passcode prompt, XCTest's slow
    /// start) could get it suspended half-way. A background task covers that
    /// window: ended as soon as the test runs, or when iOS says time is up.
    static func holdBackgroundTaskUntilTestStarts() {
        guard bootstrapTask == .invalid else { return }
        bootstrapTask = UIApplication.shared.beginBackgroundTask(withName: "LoopCtrl XCTest bootstrap") {
            loopctrlLog("XCTest bootstrap: background time ran out before the test started")
            endBootstrapTask()
        }
        testStartedObserver = NotificationCenter.default.addObserver(
            forName: testStartedNotification, object: nil, queue: .main
        ) { _ in
            endBootstrapTask()
        }
    }

    private static func endBootstrapTask() {
        if let observer = testStartedObserver {
            NotificationCenter.default.removeObserver(observer)
            testStartedObserver = nil
        }
        guard bootstrapTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bootstrapTask)
        bootstrapTask = .invalid
    }
}
