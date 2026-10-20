import BackgroundTasks
import Foundation
import IDevice
import UserNotifications
import dnssd

/// Device-initiated pairing (iOS 27+): this app becomes the "computer" the
/// device pairs with, and keeps the RemotePairing record the DDI mount needs.
///
/// Settings › Privacy & Security › Developer Mode lists hosts that advertise
/// `_remotepairing-pairable-host._tcp` on the local network. idevice runs the
/// listener and the SRP exchange; this file supplies the two things an iOS app
/// has to do differently from a desktop host:
///  * the Bonjour record goes through mDNSResponder (`DNSServiceRegister`),
///    because idevice's own raw-multicast advertiser needs an entitlement apps
///    don't get — hence the patched `pairable_host_accept_unadvertised`;
///  * the wait survives the user switching to Settings, by asking for
///    continued-processing time, whose system UI also carries the PIN.
@MainActor
final class OnDevicePairing: ObservableObject {

    static let shared = OnDevicePairing()

    static var isSupported: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    /// The host name Settings shows.
    static let hostName = "LoopCtrl"
    static let serviceType = "_remotepairing-pairable-host._tcp."
    nonisolated fileprivate static let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "top.ebato.loopctrl") + ".pairing"

    enum Phase: Equatable {
        case idle
        case waiting
        case showPin(String)
        case paired
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { loopctrlLog("Pairing phase → \(phase)") }
    }

    var isRunning: Bool {
        if case .waiting = phase { return true }
        if case .showPin = phase { return true }
        return false
    }

    private var attempt: PairingAttempt?
    private let bonjour = BonjourRecord()
    private let background = ContinuedProcessing()

    private init() {}

    /// Registers the continued-processing launch handler. BGTaskScheduler only
    /// accepts this before the app finishes launching.
    nonisolated static func registerBackgroundTask() {
        ContinuedProcessing.register(identifier: backgroundIdentifier) {
            shared.background.adopt($0, stillWanted: shared.isRunning) { shared.stop() }
        }
    }

    func start() {
        guard Self.isSupported, !isRunning else { return }
        phase = .waiting
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        background.begin(identifier: Self.backgroundIdentifier,
                         title: Self.hostName,
                         subtitle: L10n.t(.pairWaitingSubtitle))

        let attempt = PairingAttempt(hostName: Self.hostName) { [weak self] event in
            self?.handle(event)
        }
        self.attempt = attempt
        attempt.run()
    }

    func stop() {
        guard isRunning else { return }
        attempt?.cancel()
    }

    private func handle(_ event: PairingAttempt.Event) {
        switch event {
        case .listening(let instance, let port, let txt):
            if bonjour.publish(instance: instance, type: Self.serviceType, port: port, txt: txt) {
                loopctrlLog("Pairing: published \(instance), port \(port)")
            } else {
                loopctrlLog("Pairing: could not publish the Bonjour record")
            }

        case .pin(let pin):
            guard isRunning else { return }
            phase = .showPin(pin)
            let body = String(format: L10n.t(.pairPinBody), pin)
            Notice.post(.pin, title: L10n.t(.pairPinTitle), body: body)
            background.update(subtitle: body, step: .pinShown)

        case .ended(let result):
            attempt = nil
            bonjour.withdraw()
            Notice.withdraw(.pin)
            conclude(result)
        }
    }

    private func conclude(_ result: Result<Data, Error>) {
        let record: Data
        switch result {
        case .failure(let error):
            let message = error.localizedDescription
            // The user pressed Cancel; nothing went wrong.
            phase = message.contains("canceled by user") ? .idle : .failed(message)
            background.end(success: false)
            return
        case .success(let data):
            record = data
        }

        do {
            try PairingFileStore.store(record)
        } catch {
            phase = .failed(error.localizedDescription)
            background.end(success: false)
            return
        }
        NotificationCenter.default.post(name: PairingFileStore.didImport, object: nil)
        phase = .paired
        Notice.post(.done, title: L10n.t(.pairDoneTitle), body: L10n.t(.pairDoneBody))
        background.end(success: true)
    }
}

// MARK: - One pairing attempt

/// Owns one blocking `pairable_host_accept_unadvertised` call on its own
/// thread, and reports back on the main actor. The C callbacks can't capture,
/// so they find the attempt through `context`, which the attempt keeps alive
/// (`retainedSelf`) until the call has returned.
private final class PairingAttempt: @unchecked Sendable {

    enum Event {
        case listening(instance: String, port: UInt16, txt: [String: String])
        case pin(String)
        case ended(Result<Data, Error>)
    }

    private let hostName: String
    private let deliver: @MainActor (Event) -> Void
    private let token: OpaquePointer?
    private var retainedSelf: Unmanaged<PairingAttempt>?

    init(hostName: String, deliver: @escaping @MainActor (Event) -> Void) {
        self.hostName = hostName
        self.deliver = deliver
        self.token = pairable_host_cancel_new()
    }

    func run() {
        let context = Unmanaged.passRetained(self)
        retainedSelf = context
        let worker = Thread { [self] in
            let result = accept(context: context.toOpaque())
            if let token { pairable_host_cancel_free(token) }
            send(.ended(result))
            retainedSelf?.release()
        }
        worker.name = "loopctrl.pairing"
        worker.qualityOfService = .userInitiated
        worker.start()
    }

    func cancel() {
        if let token { pairable_host_cancel_signal(token) }
    }

    fileprivate func send(_ event: Event) {
        let deliver = self.deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(event) } }
    }

    private func accept(context: UnsafeMutableRawPointer) -> Result<Data, Error> {
        var record: OpaquePointer?
        let failure = hostName.withCString { name in
            pairable_host_accept_unadvertised(name, nil, 0,
                                              onListening, onPin, context,
                                              token, nil, nil, &record)
        }
        if let failure {
            return .failure(Self.error("Pairing", failure))
        }
        guard let record else {
            return .failure(DDIError.ffi("Pairing", "no pairing file returned"))
        }
        defer { rp_pairing_file_free(record) }

        var bytes: UnsafeMutablePointer<UInt8>?
        var count: UInt = 0
        if let failure = rp_pairing_file_to_bytes(record, &bytes, &count) {
            return .failure(Self.error("Reading the new pairing file", failure))
        }
        guard let bytes, count > 0 else {
            return .failure(DDIError.ffi("Reading the new pairing file", "empty"))
        }
        defer { idevice_data_free(bytes, count) }
        return .success(Data(UnsafeBufferPointer(start: bytes, count: Int(count))))
    }

    private static func error(_ operation: String, _ raw: UnsafeMutablePointer<IdeviceFfiError>) -> Error {
        defer { idevice_error_free(raw) }
        let text = raw.pointee.message.map { String(cString: $0) } ?? "code \(raw.pointee.code)"
        return DDIError.ffi(operation, text)
    }

    static func from(_ context: UnsafeMutableRawPointer?) -> PairingAttempt? {
        context.map { Unmanaged<PairingAttempt>.fromOpaque($0).takeUnretainedValue() }
    }
}

private func onListening(_ instance: UnsafePointer<CChar>?, _ port: UInt16,
                         _ keys: UnsafePointer<UnsafePointer<CChar>?>?,
                         _ values: UnsafePointer<UnsafePointer<CChar>?>?,
                         _ count: UInt, _ context: UnsafeMutableRawPointer?) {
    guard let attempt = PairingAttempt.from(context), let instance else { return }
    var txt: [String: String] = [:]
    for i in 0..<Int(count) {
        if let key = keys?[i], let value = values?[i] {
            txt[String(cString: key)] = String(cString: value)
        }
    }
    attempt.send(.listening(instance: String(cString: instance), port: port, txt: txt))
}

private func onPin(_ pin: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let attempt = PairingAttempt.from(context), let pin else { return }
    attempt.send(.pin(String(cString: pin)))
}

// MARK: - Bonjour

/// One registered DNS-SD service, published through mDNSResponder.
@MainActor
private final class BonjourRecord {
    private var registration: DNSServiceRef?

    func publish(instance: String, type: String, port: UInt16, txt: [String: String]) -> Bool {
        withdraw()

        var record = TXTRecordRef()
        TXTRecordCreate(&record, 0, nil)
        defer { TXTRecordDeallocate(&record) }
        for (key, value) in txt {
            let bytes = Array(value.utf8.prefix(255))
            _ = TXTRecordSetValue(&record, key, UInt8(bytes.count), bytes)
        }

        // DNS-SD wants the type without the trailing dot and the port in
        // network byte order.
        let regType = type.hasSuffix(".") ? String(type.dropLast()) : type
        var ref: DNSServiceRef?
        let status = DNSServiceRegister(&ref, 0, 0, instance, regType, nil, nil,
                                        port.bigEndian,
                                        TXTRecordGetLength(&record),
                                        TXTRecordGetBytesPtr(&record),
                                        nil, nil)
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return false }
        DNSServiceSetDispatchQueue(ref, .main)
        registration = ref
        return true
    }

    func withdraw() {
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
    }
}

// MARK: - Background time

/// Continued-processing time (iOS 26+) for the wait in Settings. Without it,
/// pairing still works as long as LoopCtrl stays in front.
@MainActor
private final class ContinuedProcessing {

    enum Step: Int64 {
        case started = 1
        case pinShown = 2
        case finished = 3
    }

    /// Typed as AnyObject so the class itself needs no availability gate.
    private var task: AnyObject?
    private var subtitle: String?
    private var step: Step = .started

    nonisolated static func register(identifier: String, onLaunch: @escaping @MainActor (AnyObject) -> Void) {
        guard #available(iOS 26, *) else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { launched in
            MainActor.assumeIsolated { onLaunch(launched) }
        }
    }

    func begin(identifier: String, title: String, subtitle: String) {
        guard #available(iOS 26, *) else { return }
        self.subtitle = subtitle
        step = .started
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // A busy system queues the request; adopt(_:) sorts out a late launch.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            loopctrlLog("Pairing: no continued-processing time (\(error.localizedDescription))")
        }
    }

    func adopt(_ launched: AnyObject, stillWanted: Bool, onExpiry: @escaping @MainActor () -> Void) {
        guard #available(iOS 26, *), let launched = launched as? BGContinuedProcessingTask else { return }
        guard stillWanted else {
            // The attempt ended before the system launched the task.
            launched.setTaskCompleted(success: step == .finished)
            return
        }
        task = launched
        launched.progress.totalUnitCount = Step.finished.rawValue
        launched.expirationHandler = { Task { @MainActor in onExpiry() } }
        refresh()
    }

    func update(subtitle: String, step: Step) {
        self.subtitle = subtitle
        self.step = step
        refresh()
    }

    func end(success: Bool) {
        step = success ? .finished : step
        guard #available(iOS 26, *), let running = task as? BGContinuedProcessingTask else { return }
        running.progress.completedUnitCount = Step.finished.rawValue
        running.setTaskCompleted(success: success)
        task = nil
    }

    private func refresh() {
        guard #available(iOS 26, *), let running = task as? BGContinuedProcessingTask else { return }
        running.progress.completedUnitCount = step.rawValue
        if let subtitle { running.updateTitle(OnDevicePairing.hostName, subtitle: subtitle) }
    }
}

// MARK: - Notifications

private enum Notice: String {
    case pin = "loopctrl.pairing.pin"
    case done = "loopctrl.pairing.done"

    static func post(_ notice: Notice, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notice.rawValue, content: content, trigger: nil))
    }

    static func withdraw(_ notice: Notice) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notice.rawValue])
    }
}
