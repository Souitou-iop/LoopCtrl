import CoreMedia
import CoreVideo
import Network
import QuartzCore
import ReplayKit
import UIKit
import VideoToolbox

/// The system broadcast (docs/remote-control.md, "System broadcast"): iOS
/// hands this extension the screen as it is drawn, up to 60 times a second,
/// with no screenshot taken and no JPEG made. It scales and encodes it for
/// each lane the runner asks for and passes the frames to the runner, which
/// sends them on to the viewers. Started from LoopCtrl (or Control Center);
/// the runner falls back to screenshots when it ends.
///
/// The extension may use 50 MB at most: no frame is kept beyond the newest
/// one per lane (for keyframes on a still screen), and frames the runner
/// hasn't taken yet are dropped rather than queued.
///
/// A broadcast is started by hand, so losing the runner doesn't end it: the
/// extension connects again every second (the runner restarting, or still
/// waiting for iOS to count the screen as captured), and gives up only after
/// half a minute without one, or when LoopCtrl says stop.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "top.ebato.loopctrl.broadcast")
    private var connection: NWConnection?
    private var reader = BroadcastWire.Reader()
    private var lanes: [UInt32: EncoderLane] = [:]
    private var connected = false
    /// Bumped per connection, so a late callback from an old one is ignored.
    private var generation = 0
    /// Without a runner since then (the start counts).
    private var lostSince: CFTimeInterval? = CACurrentMediaTime()
    private static let giveUpAfter: CFTimeInterval = 30
    private var ended = false
    /// Bytes handed to the connection and not yet sent: past this the runner
    /// is behind, and frames are skipped (each lane resumes at a keyframe).
    private var unsent = 0
    private static let unsentLimit = 1_500_000
    private var hidden = false
    /// The newest picture iOS handed over: on a still screen it sends no
    /// more, and a lane that starts (a viewer joining) needs one now.
    private var newest: (pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation)?
    /// Pixels per point, read once: UIKit belongs to the main thread.
    private var scale: Double = 3
    /// The screen in points, read once on the main thread. ReplayKit hands
    /// over a video buffer that is already scaled (884×1920 here, not the
    /// screen's 1206×2622), so buffer pixels divided by nativeScale is NOT
    /// the tap space: it made every tap land up and to the left of the
    /// finger. The tap space is nativeBounds / nativeScale.
    private var screenPoints = CGSize.zero

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let screen = UIScreen.main
        let scale = Double(screen.nativeScale)
        let points = CGSize(width: screen.nativeBounds.width / scale,
                            height: screen.nativeBounds.height / scale)
        queue.async {
            self.scale = scale
            self.screenPoints = points
            self.lostSince = CACurrentMediaTime()
            self.connect()
            self.watch()
        }
    }

    /// No runner to take the frames for a while (service off, or the switch
    /// in LoopCtrl off): say so instead of recording into nothing.
    private func watch() {
        guard !ended else { return }
        if let since = lostSince, CACurrentMediaTime() - since > Self.giveUpAfter {
            return finish(Self.text(en: "Turn on the LoopCtrl service and System broadcast in LoopCtrl first.",
                                    zh: "请先在 LoopCtrl 中开启服务和「系统录屏推流」。"))
        }
        queue.asyncAfter(deadline: .now() + 1) { self.watch() }
    }

    override func broadcastFinished() {
        queue.sync {
            ended = true
            connection?.cancel()
            connection = nil
            newest = nil
            for lane in lanes.values { lane.teardown() }
            lanes.removeAll()
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)
            as? NSNumber).flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        queue.sync { self.handle(pixels, orientation: orientation) }
    }

    // MARK: - Runner

    private func connect() {
        guard !ended, let port = NWEndpoint.Port(rawValue: BroadcastWire.port) else { return }
        generation += 1
        let mine = generation
        let conn = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        connection = conn
        reader = BroadcastWire.Reader()
        unsent = 0
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == mine else { return }
            switch state {
            case .ready:
                self.connected = true
                self.lostSince = nil
                self.send(BroadcastWire.message(.hello, json: BroadcastWire.Hello()), counted: false)
                self.receive(mine)
            case .waiting, .failed, .cancelled:
                // Nobody listening (yet), or the runner went away.
                self.dropped()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ mine: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.generation == mine else { return }
            if let data, !data.isEmpty {
                for (kind, payload) in self.reader.feed(data) { self.handle(kind, payload) }
            }
            if complete || error != nil { self.dropped() } else { self.receive(mine) }
        }
    }

    /// The runner is gone or not there yet: try again in a second. Its
    /// lanes start afresh with the next connection.
    private func dropped() {
        generation += 1
        connection?.cancel()
        connection = nil
        if connected { lostSince = CACurrentMediaTime() }
        connected = false
        for lane in lanes.values { lane.teardown() }
        lanes.removeAll()
        guard !ended else { return }
        queue.asyncAfter(deadline: .now() + 1) { self.connect() }
    }

    private func handle(_ kind: BroadcastWire.Kind, _ payload: Data) {
        switch kind {
        case .lanes:
            guard let wanted = try? JSONDecoder().decode([BroadcastWire.Lane].self, from: payload) else { return }
            let ids = Set(wanted.map(\.id))
            for (id, lane) in lanes where !ids.contains(id) {
                lane.teardown()
                lanes[id] = nil
            }
            for spec in wanted {
                let lane = lanes[spec.id] ?? EncoderLane(id: spec.id, queue: queue, scale: scale,
                                                         screenPoints: screenPoints,
                                                         output: { [weak self] in self?.send($0, counted: true) })
                lanes[spec.id] = lane
                lane.apply(spec)
                // A keyframe on a still screen: iOS sends no new picture,
                // so encode the newest one again.
                if spec.key && !spec.hold, !lane.encodeAgain(now: Self.micros()), let newest {
                    _ = lane.take(newest.pixels, orientation: newest.orientation, now: Self.micros())
                }
            }
        case .stop:
            finish(Self.text(en: "System broadcast was turned off in LoopCtrl.", zh: "已在 LoopCtrl 中关闭「系统录屏推流」。"))
        default:
            break
        }
    }

    private func handle(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard connected else { return }
        newest = (pixels, orientation)
        if unsent > Self.unsentLimit {
            for lane in lanes.values { lane.needsKeyframe() }
            return
        }
        let now = Self.micros()
        var checkedHidden = false
        for lane in lanes.values {
            guard let scaled = lane.take(pixels, orientation: orientation, now: now) else { continue }
            if !checkedHidden {
                checkedHidden = true
                let black = Self.nearlyBlack(scaled)
                if black != hidden {
                    hidden = black
                    if let m = BroadcastWire.message(.hidden, json: BroadcastWire.Hidden(hidden: black)) {
                        send(m, counted: false)
                    }
                }
            }
        }
    }

    private func send(_ data: Data?, counted: Bool) {
        guard let data, let connection else { return }
        if counted { unsent += data.count }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self, counted else { return }
            self.queue.async { self.unsent = max(0, self.unsent - data.count) }
        })
    }

    private func finish(_ reason: String) {
        guard !ended else { return }
        ended = true
        generation += 1
        connected = false
        connection?.cancel()
        connection = nil
        finishBroadcastWithError(NSError(domain: "LoopCtrl", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]))
    }

    static func micros() -> UInt64 { UInt64(CACurrentMediaTime() * 1_000_000) }

    private static func text(en: String, zh: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
    }

    /// Whether a 16×16 grid of the luma plane is all but black: an app that
    /// hides its screen from capture (banking, payment).
    private static func nearlyBlack(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for gy in 0..<16 {
            for gx in 0..<16 {
                let x = (gx * 2 + 1) * width / 32, y = (gy * 2 + 1) * height / 32
                if base[y * row + x] > 40 { return false }
            }
        }
        return true
    }
}

/// One encoder: the screen turned upright, scaled to the lane's size, and
/// encoded at its codec and bitrate. Everything, the encoder's output
/// included, runs on the handler's queue.
private final class EncoderLane {
    let id: UInt32
    private let queue: DispatchQueue
    private let scale: Double
    private let screenPoints: CGSize
    private let output: (Data) -> Void
    /// The whole screen in points, as it is turned now.
    private var points = (width: 0.0, height: 0.0)
    private var spec: BroadcastWire.Lane?
    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var rotation: VTPixelRotationSession?
    private var pool: CVPixelBufferPool?
    private var size = (width: 0, height: 0)
    private var rotationKey: CFString?
    /// The newest scaled picture, for a keyframe on a still screen.
    private var last: CVPixelBuffer?
    private var lastAt: UInt64 = 0
    private var forceKey = true
    private var configSent = false
    private var failures = 0

    init(id: UInt32, queue: DispatchQueue, scale: Double, screenPoints: CGSize,
         output: @escaping (Data) -> Void) {
        self.id = id
        self.queue = queue
        self.scale = scale
        self.screenPoints = screenPoints
        self.output = output
    }

    func apply(_ new: BroadcastWire.Lane) {
        let old = spec
        spec = new
        if old?.codec != new.codec || old?.longSide != new.longSide {
            teardownEncoder()
        } else if old?.bitrate != new.bitrate, let session {
            Self.setBitrate(session, new.bitrate)
        }
        if new.key { forceKey = true }
    }

    func needsKeyframe() { forceKey = true }

    /// Scale and encode a new picture, unless the lane is holding back or
    /// at its frame rate already. Returns the scaled picture when encoded.
    func take(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation, now: UInt64) -> CVPixelBuffer? {
        guard let spec, !spec.hold else { return nil }
        if !forceKey, lastAt > 0, Double(now - lastAt) < 1_000_000 / spec.fps * 0.9 { return nil }
        guard let upright = turn(pixels, orientation: orientation) else { return nil }
        // The tap space comes from the screen, never from this buffer: the
        // buffer is already scaled by ReplayKit. Swap only when the picture
        // is turned relative to the screen.
        let turned: (Double, Double)
        if screenPoints.width > 0, screenPoints.height > 0 {
            let bufferLandscape = CVPixelBufferGetWidth(upright) > CVPixelBufferGetHeight(upright)
            let screenLandscape = screenPoints.width > screenPoints.height
            turned = bufferLandscape == screenLandscape
                ? (Double(screenPoints.width), Double(screenPoints.height))
                : (Double(screenPoints.height), Double(screenPoints.width))
        } else {
            turned = (Double(CVPixelBufferGetWidth(upright)) / scale, Double(CVPixelBufferGetHeight(upright)) / scale)
        }
        if turned != points {
            points = turned
            configSent = false   // tap space changed: say so with the next frame
        }
        guard let scaled = fit(upright, longSide: spec.longSide), prepare(spec) else { return nil }
        last = scaled
        encode(scaled, at: now)
        return scaled
    }

    /// The newest scaled picture once more, as a keyframe; false if there
    /// is none yet.
    func encodeAgain(now: UInt64) -> Bool {
        guard let last, let spec, prepare(spec) else { return false }
        forceKey = true
        encode(last, at: now)
        return true
    }

    func teardown() {
        teardownEncoder()
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        if let rotation { VTPixelRotationSessionInvalidate(rotation) }
        transfer = nil
        rotation = nil
        pool = nil
        last = nil
    }

    private func teardownEncoder() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        configSent = false
        forceKey = true
    }

    /// The picture as the screen shows it: iOS hands it over in the panel's
    /// native (portrait) layout and says how it is turned.
    private func turn(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let key: CFString?
        switch orientation {
        case .left: key = kVTRotation_CW90
        case .right: key = kVTRotation_CCW90
        case .down: key = kVTRotation_180
        default: key = nil
        }
        guard let key else { return pixels }
        if rotation == nil {
            var made: VTPixelRotationSession?
            guard VTPixelRotationSessionCreate(nil, &made) == noErr else { return pixels }
            rotation = made
        }
        guard let rotation else { return pixels }
        if rotationKey != key {
            VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: key)
            rotationKey = key
        }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let (ow, oh) = key == kVTRotation_180 ? (w, h) : (h, w)
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, ow, oh, CVPixelBufferGetPixelFormatType(pixels),
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
        guard let out, VTPixelRotationSessionRotateImage(rotation, pixels, out) == noErr else { return pixels }
        return out
    }

    /// Scaled in hardware to the lane's size: the longer side at most
    /// `longSide`, both multiples of 16 (see ScreenStream.fit).
    private func fit(_ pixels: CVPixelBuffer, longSide: Int) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let factor = min(1, Double(longSide) / Double(max(w, h)))
        func block(_ v: Double) -> Int { max(16, Int(v) & ~15) }
        let target = (width: block(Double(w) * factor), height: block(Double(h) * factor))
        if pool == nil || size != target {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: target.width,
                kCVPixelBufferHeightKey: target.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary,
                                    attrs as CFDictionary, &made)
            pool = made
            if size != target { teardownEncoder() }
            size = target
        }
        if transfer == nil {
            var made: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &made) == noErr else { return nil }
            transfer = made
            if let made {
                VTSessionSetProperty(made, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            }
        }
        var out: CVPixelBuffer?
        guard let pool, let transfer,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
              VTPixelTransferSessionTransferImage(transfer, from: pixels, to: out) == noErr else { return nil }
        return out
    }

    private func prepare(_ spec: BroadcastWire.Lane) -> Bool {
        if session != nil { return true }
        guard size.width > 0 else { return false }
        let hevc = spec.codec == "hevc"
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(size.width), height: Int32(size.height),
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let made else { return false }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_ProfileLevel: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!,
            kVTCompressionPropertyKey_ExpectedFrameRate: spec.fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(spec.fps * 4),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 4,
        ]
        for (key, value) in props { VTSessionSetProperty(made, key: key, value: value as CFTypeRef) }
        Self.setBitrate(made, spec.bitrate)
        VTCompressionSessionPrepareToEncodeFrames(made)
        session = made
        configSent = false
        forceKey = true
        return true
    }

    /// The bitrate, with bursts bounded as in the runner's own encoder.
    private static func setBitrate(_ session: VTCompressionSession, _ bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        let perSecond = bitrate / 8
        let both = [perSecond * 3 / 2, 1, perSecond * 2 / 5, 0.2] as [Any] as CFArray
        if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: both) != noErr {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [perSecond * 3 / 2, 1] as CFArray)
        }
    }

    private func encode(_ buffer: CVPixelBuffer, at micros: UInt64) {
        guard let session else { return }
        lastAt = micros
        var options: CFDictionary?
        if forceKey {
            options = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKey = false
        }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(micros), timescale: 1_000_000),
            duration: .invalid, frameProperties: options, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            self?.queue.async {
                guard let self, self.session === session else { return }   // from an encoder since replaced
                guard status == noErr, let sample else {
                    if status != noErr { self.failed() }
                    return
                }
                self.emit(sample, micros: micros)
            }
        }
        if status != noErr { failed() }
    }

    /// An encoder that errs is replaced on the next frame, which is a keyframe.
    private func failed() {
        failures += 1
        teardownEncoder()
    }

    private func emit(_ sample: CMSampleBuffer, micros: UInt64) {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if keyframe || !configSent, let config = Self.config(format, lane: id, points: points),
           let message = BroadcastWire.message(.config, json: config) {
            configSent = true
            output(message)
        }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return }
        output(BroadcastWire.frame(lane: id, keyframe: keyframe, micros: micros,
                                   accessUnit: Data(bytes: pointer, count: length)))
    }

    private static func config(_ format: CMFormatDescription, lane: UInt32,
                               points: (width: Double, height: Double)) -> BroadcastWire.Config? {
        guard let atoms = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let pw = points.width, ph = points.height
        if let hvcC = atoms["hvcC"] as? Data {
            return BroadcastWire.Config(lane: lane, kind: "hvc", description: hvcC, sps: nil, width: Int(dims.width),
                                        height: Int(dims.height), pointWidth: pw, pointHeight: ph)
        }
        guard let avcC = atoms["avcC"] as? Data else { return nil }
        var sps: UnsafePointer<UInt8>?
        var spsLength = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &sps,
                                                           parameterSetSizeOut: &spsLength, parameterSetCountOut: nil,
                                                           nalUnitHeaderLengthOut: nil)
        return BroadcastWire.Config(lane: lane, kind: "avc", description: avcC,
                                    sps: sps.map { Data(bytes: $0, count: spsLength) }, width: Int(dims.width),
                                    height: Int(dims.height), pointWidth: pw, pointHeight: ph)
    }
}
