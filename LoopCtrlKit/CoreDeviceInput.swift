import Foundation
import os

#if canImport(IDevice)
import IDevice

/// Sends input through this device's own CoreDevice HID services — the Indigo
/// surface dtuhidd serves — the same path Xcode's DeviceHub uses. Events land
/// as real system input: no XCTest runner quirks, no main-thread stalls, and
/// the power button replies in tens of milliseconds instead of seconds.
///
/// The path needs two things, the same two the DDI mount needs:
///  * a RemotePairing record at Application Support/Pairing/pairingFile.plist
///    (on-device pairing writes it there), and
///  * the LocalDevVPN/StosVPN tunnel that makes this device's `remoted`
///    routable at 10.7.0.1:49152 (DDIMounter.tunnelAddress).
///
/// Every Indigo event lands only while a displayservice media stream is open
/// (the "authentication gate"), and its RTP payload can be discarded — so the
/// backend holds one open while input is flowing and lets it go after a short
/// idle. The digitizer takes 0.0–1.0 normalized coordinates (observed; see
/// Patches/idevice/0003).
///
/// Every entry point is synchronous and returns false when the path is
/// unavailable or fails — the caller then falls back to the XCTest route, so
/// behavior never gets worse than it was.
final class CoreDeviceInput {
    static let shared = CoreDeviceInput()

    private static let log = Logger(subsystem: "top.ebato.loopctrl", category: "coredevice-input")

    /// Where LocalDevVPN/StosVPN publishes this device (DDIMounter.tunnelAddress).
    private static let tunnelAddress = "10.7.0.1"
    /// `remoted` (DDIMounter.tunnelPort).
    private static let tunnelPort: UInt16 = 49152

    /// How long the media-stream gate stays open after the last event.
    private static let gateIdle: TimeInterval = 30
    /// How long to shun the whole path after a failure, so a dead tunnel or a
    /// revoked record doesn't cost a round-trip on every action.
    private static let cooldown: TimeInterval = 60

    private let queue = DispatchQueue(label: "loopctrl.coredevice-input", qos: .userInteractive)

    // Session state, only touched on `queue`.
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var hid: OpaquePointer?
    private var gate: OpaquePointer?
    private var cooldownUntil = Date.distantPast
    private var gateWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: - Entry points (called from the runner's dispatch thread)

    /// A single tap, at point coordinates on a `width` × `height` screen.
    ///
    /// A finger never lands perfectly still, and a down/up pair at the same
    /// normalized point is dropped by some SwiftUI controls — so carry one
    /// sample a point toward the screen centre between down and up. That's far
    /// inside the ~10 pt touch slop, so it still reads as a tap.
    func tap(x: Double, y: Double, width: Double, height: Double) -> Bool {
        guard width > 0, height > 0 else { return false }
        let jx = x + (x < width / 2 ? 1 : -1)
        let jy = y + (y < height / 2 ? 1 : -1)
        guard sendDigitizer(x: x, y: y, width: width, height: height, event: .start) else {
            return false
        }
        guard sendDigitizer(x: jx, y: jy, width: width, height: height,
                            event: .position, delay: 0.012) else { return false }
        return sendDigitizer(x: jx, y: jy, width: width, height: height, event: .end)
    }

    /// A drag from one point to another over `duration` seconds.
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              width: Double, height: Double, duration: Double) -> Bool {
        let steps = max(6, min(40, Int(duration * 60)))
        let dt = duration / Double(steps + 1)
        guard sendDigitizer(x: fromX, y: fromY, width: width, height: height, event: .start) else {
            return false
        }
        for i in 1...steps {
            let t = Double(i) / Double(steps + 1)
            let px = fromX + (toX - fromX) * t
            let py = fromY + (toY - fromY) * t
            guard sendDigitizer(x: px, y: py, width: width, height: height,
                                event: .position, delay: dt) else { return false }
        }
        return sendDigitizer(x: toX, y: toY, width: width, height: height, event: .end)
    }

    /// A touch held at a point for `duration` seconds: a long press.
    /// Unlike a tap this needs no displacement sample — verified on device by
    /// the home screen entering edit mode after a 1 s hold.
    func hold(x: Double, y: Double, width: Double, height: Double, duration: Double) -> Bool {
        guard sendDigitizer(x: x, y: y, width: width, height: height, event: .start) else {
            return false
        }
        usleepUsecs(UInt64(min(max(duration, 0.05), 10) * 1_000_000))
        return sendDigitizer(x: x, y: y, width: width, height: height, event: .end)
    }

    /// A named hardware button held for `holdMs` milliseconds: usage page 0x0C
    /// carries home 0x40, power 0x30, volume up 0xE9, volume down 0xEA.
    func button(usagePage: UInt64, usage: UInt64, holdMs: Int) -> Bool {
        queueSend { hid in
            hid_indigo_send_button(hid, usagePage, usage, 1) // down
        } &&
        (holdMs <= 0 || usleepUsecs(UInt64(holdMs) * 1000)) &&
        queueSend { hid in
            hid_indigo_send_button(hid, usagePage, usage, 2) // up
        }
    }

    /// A keyboard key press: HID keyboard usage (page 0x07 implicit).
    func key(usage: UInt64) -> Bool {
        queueSend { hid in hid_indigo_send_keyboard(hid, usage, 1) } &&
        queueSend { hid in hid_indigo_send_keyboard(hid, usage, 2) }
    }

    /// Whether the path may be worth trying right now (not cooling down).
    var usable: Bool { Date() >= cooldownUntil }

    // MARK: - FFI plumbing

    private enum DigitizerEvent {
        case start, position, end
        var raw: UInt64 { switch self { case .start: 0; case .position: 1; case .end: 2 } }
    }

    /// One digitizer event, with the point normalized on the way in.
    private func sendDigitizer(x: Double, y: Double, width: Double, height: Double,
                               event: DigitizerEvent, delay: Double = 0) -> Bool {
        guard width > 0, height > 0 else { return false }
        let nx = min(max(x / width, 0.0), 1.0)
        let ny = min(max(y / height, 0.0), 1.0)
        let ok = queueSend { hid in
            hid_indigo_send_digitizer(hid, nx, ny, 0, 0, 0, event.raw, 0, 0)
        }
        if ok, delay > 0 { usleepUsecs(UInt64(delay * 1_000_000)) }
        return ok
    }

    /// Run one FFI call against the live HID handle, on the serial queue.
    private func queueSend(_ call: (OpaquePointer) -> UnsafeMutablePointer<IdeviceFfiError>?) -> Bool {
        queue.sync { ensureSession() && ensureGate() && runCall(call) }
    }

    private func runCall(_ call: (OpaquePointer) -> UnsafeMutablePointer<IdeviceFfiError>?) -> Bool {
        guard let hid else { return false }
        if let err = call(hid) {
            Self.log.info("CoreDeviceInput: event failed: \(self.errorMessage(err))")
            teardownAll(cooldown: true)
            return false
        }
        scheduleGateIdle()
        return true
    }

    private func usleepUsecs(_ usecs: UInt64) -> Bool {
        usleep(useconds_t(clamping: usecs)) == 0
    }

    // MARK: - Session lifecycle

    /// Establish tunnel + RSD + HID client + media-stream gate, reusing what's
    /// alive. Anything that fails tears the session down and starts the cooldown.
    private func ensureSession() -> Bool {
        if hid != nil { return true }
        guard Date() >= cooldownUntil else { return false }

        // Mirrors PairingFileStore.storedURL (LoopCtrlApp): on-device pairing
        // writes the RP record to Application Support. In the all-in-one build
        // the runner shares the app's container and reads the same file; in the
        // separate-runner build the file is absent and the path stays off.
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let pairingPath = base.appendingPathComponent("Pairing/pairingFile.plist").path
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            Self.log.info("CoreDeviceInput: no pairing record at \(pairingPath, privacy: .public) — staying on XCTest")
            cooldownUntil = Date().addingTimeInterval(Self.cooldown)
            return false
        }
        // The tunnel is down after every reboot; don't dial a dead address.
        guard Self.tunnelReachable() else {
            Self.log.info("CoreDeviceInput: tunnel \(Self.tunnelAddress, privacy: .public):\(Self.tunnelPort) unreachable — staying on XCTest")
            cooldownUntil = Date().addingTimeInterval(Self.cooldown)
            return false
        }

        var pairing: OpaquePointer?
        guard rp_pairing_file_read(pairingPath, &pairing) == nil, let pairing else {
            cooldownUntil = Date().addingTimeInterval(Self.cooldown)
            return false
        }
        defer { rp_pairing_file_free(pairing) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.tunnelPort.bigEndian
        guard Self.tunnelAddress.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            return false
        }

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        let connectErr = withUnsafePointer(to: &addr) { ptr -> UnsafeMutablePointer<IdeviceFfiError>? in
            ptr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { sa in
                tunnel_create_rppairing(sa, idevice_socklen_t(MemoryLayout<sockaddr_in>.size),
                                        "LoopCtrl", pairing, nil, nil,
                                        &newAdapter, &newHandshake)
            }
        }
        if let connectErr {
            Self.log.info("CoreDeviceInput: tunnel failed: \(self.errorMessage(connectErr))")
            teardownAll(cooldown: true)
            return false
        }
        adapter = newAdapter
        handshake = newHandshake

        var newHid: OpaquePointer?
        if let err = hid_indigo_connect_rsd(adapter, handshake, &newHid) {
            Self.log.info("CoreDeviceInput: hid connect failed: \(self.errorMessage(err))")
            teardownAll(cooldown: true)
            return false
        }
        hid = newHid
        Self.log.info("CoreDeviceInput: session up (tunnel → RSD → indigo)")
        return true
    }

    /// Open the displayservice media stream that authenticates HID events.
    private func ensureGate() -> Bool {
        if gate != nil { return true }
        guard let adapter, let handshake else { return false }
        var newGate: OpaquePointer?
        if let err = display_gate_start_rsd(adapter, handshake, 1, &newGate) {
            Self.log.info("CoreDeviceInput: media gate failed: \(self.errorMessage(err))")
            teardownAll(cooldown: true)
            return false
        }
        gate = newGate
        return true
    }

    /// Close the gate after `gateIdle` without events (its encoder load isn't
    /// free); the session itself stays for the next burst.
    private func scheduleGateIdle() {
        gateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.closeGate()
        }
        gateWorkItem = item
        queue.asyncAfter(deadline: .now() + Self.gateIdle, execute: item)
    }

    private func closeGate() {
        guard let gate else { return }
        self.gate = nil
        if let err = display_gate_stop_rsd(gate) {
            Self.log.info("CoreDeviceInput: gate stop: \(self.errorMessage(err))")
        }
    }

    private func teardownAll(cooldown: Bool) {
        closeGate()
        if let hid { hid_indigo_free(hid) }
        hid = nil
        if let handshake { rsd_handshake_free(handshake) }
        handshake = nil
        if let adapter { adapter_free(adapter) }
        adapter = nil
        cooldownUntil = cooldown ? Date().addingTimeInterval(Self.cooldown) : .distantPast
    }

    /// Extracts the message and frees the FFI error. Consuming: call once.
    private func errorMessage(_ err: UnsafeMutablePointer<IdeviceFfiError>?) -> String {
        guard let err else { return "unknown error" }
        let text = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
        idevice_error_free(err)
        return text
    }

    /// A TCP connect is the probe; LocalDevVPN answers or it doesn't.
    private static func tunnelReachable() -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = tunnelPort.bigEndian
        guard tunnelAddress.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            return false
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // 700 ms: the tunnel answers immediately when it's up.
        var tv = timeval(tv_sec: 0, tv_usec: 700_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

#else

/// Stub for targets that don't link IDevice (LoopCtrlKitTests): the input
/// backend reports unavailable and callers fall back to XCTest.
final class CoreDeviceInput {
    static let shared = CoreDeviceInput()

    private static let log = Logger(subsystem: "top.ebato.loopctrl", category: "coredevice-input")
    func tap(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              width: Double, height: Double, duration: Double) -> Bool { false }
    func hold(x: Double, y: Double, width: Double, height: Double, duration: Double) -> Bool { false }
    func button(usagePage: UInt64, usage: UInt64, holdMs: Int) -> Bool { false }
    func key(usage: UInt64) -> Bool { false }
    var usable: Bool { false }
}

#endif
