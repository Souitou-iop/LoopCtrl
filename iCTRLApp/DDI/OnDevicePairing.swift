import BackgroundTasks
import Foundation
import IDevice
import UserNotifications

/// Pairs this app with the device it runs on, producing the RemotePairing
/// record the DDI mount needs — no computer, no other app.
///
/// From iOS 27 a device can start pairing itself: Settings › Privacy & Security
/// › Developer Mode lists hosts advertising `_remotepairing-pairable-host._tcp`
/// on the local network, and "Pair with iCTRL" connects to ours. We act as that
/// host: idevice listens and runs the SRP exchange, we publish the Bonjour
/// service, and the user types the PIN we show into Settings.
///
/// Two things are done here rather than in the library:
///  * Advertising. idevice's own `pairable_host_accept` sends raw multicast,
///    which an iOS app may only do with the multicast entitlement; our patched
///    `pairable_host_accept_unadvertised` hands us the service details and
///    `NetService` publishes them through mDNSResponder instead.
///  * Staying alive. The user leaves the app for Settings while we wait, so the
///    listener runs under a `BGContinuedProcessingTask`, whose system UI also
///    shows the PIN. The PIN goes out as a notification too.
@MainActor
final class OnDevicePairing: ObservableObject {

    static let shared = OnDevicePairing()

    /// Device-initiated pairing exists from iOS 27.
    static var isSupported: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    /// The name shown in Settings' list of hosts.
    static let hostName = "iCTRL"
    static let serviceType = "_remotepairing-pairable-host._tcp."
    private static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.openminis.ictrl") + ".pairing"

    enum Phase: Equatable {
        case idle
        case waiting
        case showPin(String)
        case paired
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { ictrlLog("Pairing phase → \(phase)") }
    }

    var isRunning: Bool {
        switch phase {
        case .waiting, .showPin: return true
        default: return false
        }
    }

    private var netService: NetService?
    private var cancel: OpaquePointer?
    /// The continued-processing task, once the system has launched it.
    private var bgTask: AnyObject?

    private init() {}

    // MARK: - Lifecycle

    /// Must run before the app finishes launching (BGTaskScheduler's rule).
    nonisolated static func registerBackgroundTask() {
        guard #available(iOS 26, *) else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated { OnDevicePairing.shared.attach(task) }
        }
    }

    func start() {
        guard !isRunning, Self.isSupported else { return }
        phase = .waiting
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        submitBackgroundTask()
        runPairing()
    }

    func stop() {
        guard isRunning, let cancel else { return }
        pairable_host_cancel_signal(cancel)
    }

    // MARK: - Pairing

    private func runPairing() {
        let token = pairable_host_cancel_new()
        cancel = token
        let tokenBits = token.map { UInt(bitPattern: $0) } ?? 0
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let ctxBits = UInt(bitPattern: ctx)

        // pairable_host_accept_* blocks until a device has paired, so it gets a
        // thread of its own.
        let thread = Thread {
            var handle: OpaquePointer?
            let err = Self.hostName.withCString { name in
                pairable_host_accept_unadvertised(
                    name, nil, 0, readyCallback, pinCallback,
                    UnsafeMutableRawPointer(bitPattern: ctxBits),
                    OpaquePointer(bitPattern: tokenBits), nil, nil, &handle)
            }

            var outcome: Result<Data, Error>
            if let err {
                let message = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
                idevice_error_free(err)
                outcome = .failure(DDIError.ffi("Pairing", message))
            } else if let handle {
                outcome = Self.serialize(handle)
                rp_pairing_file_free(handle)
            } else {
                outcome = .failure(DDIError.ffi("Pairing", "no pairing file returned"))
            }

            DispatchQueue.main.async {
                if let token = OpaquePointer(bitPattern: tokenBits) { pairable_host_cancel_free(token) }
                self.finish(outcome)
            }
        }
        thread.name = "ictrl.pairing"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    nonisolated private static func serialize(_ handle: OpaquePointer) -> Result<Data, Error> {
        var bytes: UnsafeMutablePointer<UInt8>?
        var len: UInt = 0
        if let err = rp_pairing_file_to_bytes(handle, &bytes, &len) {
            let message = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
            idevice_error_free(err)
            return .failure(DDIError.ffi("Reading the new pairing file", message))
        }
        guard let bytes else { return .failure(DDIError.ffi("Reading the new pairing file", "empty")) }
        let data = Data(bytes: bytes, count: Int(len))
        idevice_data_free(bytes, len)
        return .success(data)
    }

    private func finish(_ outcome: Result<Data, Error>) {
        cancel = nil
        stopAdvertising()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ictrl.pairing.pin"])

        switch outcome {
        case .success(let data):
            do {
                try PairingFileStore.store(data)
                NotificationCenter.default.post(name: PairingFileStore.didImport, object: nil)
                phase = .paired
                notify(id: "ictrl.pairing.done", title: L10n.t(.pairDoneTitle), body: L10n.t(.pairDoneBody))
                completeBackgroundTask(success: true)
            } catch {
                phase = .failed(error.localizedDescription)
                completeBackgroundTask(success: false)
            }
        case .failure(let error):
            // Cancelling is the user's own doing, not a failure to report.
            let message = error.localizedDescription
            phase = message.contains("canceled by user") ? .idle : .failed(message)
            completeBackgroundTask(success: false)
        }
    }

    // MARK: - Callbacks (hopped to the main actor)

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(domain: "", type: Self.serviceType, name: serviceID, port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        ictrlLog("Pairing: advertising \(serviceID) on port \(port)")
    }

    fileprivate func presentPin(_ pin: String) {
        guard isRunning else { return }
        phase = .showPin(pin)
        notify(id: "ictrl.pairing.pin",
               title: L10n.t(.pairPinTitle),
               body: String(format: L10n.t(.pairPinBody), pin))
        if #available(iOS 26, *), let task = bgTask as? BGContinuedProcessingTask {
            task.updateTitle(Self.hostName, subtitle: String(format: L10n.t(.pairPinBody), pin))
            task.progress.completedUnitCount = 50
        }
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    // MARK: - Background time

    private func submitBackgroundTask() {
        guard #available(iOS 26, *) else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.taskIdentifier,
                                                       title: Self.hostName,
                                                       subtitle: L10n.t(.pairWaitingSubtitle))
        // Queue rather than fail when the system is busy, as StikPair does:
        // a late launch is attached (or completed) by attach(_:).
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Pairing still works while the app stays in front; it just may be
            // suspended once the user switches to Settings.
            ictrlLog("Pairing: no continued-processing time (\(error.localizedDescription))")
        }
    }

    @available(iOS 26, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        // Finished (or cancelled) before the system got round to launching it.
        guard isRunning else {
            task.setTaskCompleted(success: phase == .paired)
            return
        }
        bgTask = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 5
        if case .showPin(let pin) = phase {
            task.updateTitle(Self.hostName, subtitle: String(format: L10n.t(.pairPinBody), pin))
        }
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
    }

    private func completeBackgroundTask(success: Bool) {
        if #available(iOS 26, *), let task = bgTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = 100
            task.setTaskCompleted(success: success)
        }
        bgTask = nil
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

// C callbacks: no captures allowed, so the controller travels in `context`.

private let readyCallback: @convention(c) (UnsafePointer<CChar>?, UInt16,
                                          UnsafePointer<UnsafePointer<CChar>?>?,
                                          UnsafePointer<UnsafePointer<CChar>?>?,
                                          UInt, UnsafeMutableRawPointer?) -> Void = { id, port, keys, values, count, ctx in
    guard let id, let ctx else { return }
    let serviceID = String(cString: id)
    var txt: [String: Data] = [:]
    if let keys, let values {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = values[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    let ctxBits = UInt(bitPattern: ctx)
    DispatchQueue.main.async {
        guard let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits) else { return }
        Unmanaged<OnDevicePairing>.fromOpaque(ctx).takeUnretainedValue()
            .startAdvertising(serviceID: serviceID, port: Int32(port), txt: txt)
    }
}

private let pinCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pin, ctx in
    guard let pin, let ctx else { return }
    let code = String(cString: pin)
    let ctxBits = UInt(bitPattern: ctx)
    DispatchQueue.main.async {
        guard let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits) else { return }
        Unmanaged<OnDevicePairing>.fromOpaque(ctx).takeUnretainedValue().presentPin(code)
    }
}
