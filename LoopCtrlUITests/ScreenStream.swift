import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import QuartzCore
import VideoToolbox

/// The live screen for `GET /stream` (docs/remote-control.md, "Stream").
///
/// One capture loop and one encoder (H.264, or HEVC when every viewer can
/// decode it) serve every viewer: frames are captured while anyone watches,
/// skipped while the screen doesn't change, and fanned out to each viewer's
/// connection. A viewer that can't keep up loses frames instead of queueing
/// them, and picks up again at a keyframe.
///
/// Viewers that acknowledge frames (`stream_ack`) also keep the queue short
/// end to end: no frame is captured while frames are queueing on the way to
/// a viewer, and the bitrate follows what actually gets through. On a
/// link slower than the stream, that is the difference between a fraction of
/// a second and several seconds behind. Pausing the capture rather than
/// dropping encoded frames keeps the picture whole: the next frame is an
/// ordinary delta, not a keyframe the slow link would have to carry too.
final class ScreenStream {
    static let shared = ScreenStream()

    /// Where log lines go (the runner's log buffer).
    static var onLog: ((String) -> Void)?
    /// How many are watching, whenever that changes (on the stream's queue).
    static var onViewersChange: ((Int) -> Void)?

    /// One screen frame in pixels, its JPEG bytes when the capture side
    /// produced them (equal bytes mean an unchanged screen), and pixels per
    /// point. Set by the runner.
    var grab: ((_ jpegQuality: Double) -> (image: CGImage, jpeg: Data?, scale: Double)?)?

    private let queue = DispatchQueue(label: "top.ebato.loopctrl.screenstream")
    private var viewers: [String: Viewer] = [:]
    private var quality: ScreenStreamRequest.Quality = .medium
    private var codec: ScreenStreamRequest.Codec = .h264
    /// This device would not make HEVC once; H.264 from then on.
    private var hevcUnavailable = false
    /// What the encoder aims for: the quality's rate, lowered while viewers
    /// fall behind and raised again as they keep up.
    private var bitrate = ScreenStreamRequest.Quality.medium.bitsPerSecond
    private var controller: DispatchSourceTimer?
    private var calmTicks = 0
    private static let minBitrate = 300_000
    private static let startBitrate = 2_000_000
    private var activeWorkers = 0
    private var workerCount = 3
    private var nextSlot: CFTimeInterval = 0
    private var captureSeq: UInt64 = 0
    private var encodedSeq: UInt64 = 0
    private let wake = DispatchSemaphore(value: 0)

    // Encoder state, on `queue`.
    private var session: VTCompressionSession?
    private var encodedSize: (width: Int, height: Int) = (0, 0)
    private var pool: CVPixelBufferPool?
    private var config: [String: Any]?
    private var forceKeyframe = false
    private var lastForcedAt: CFTimeInterval = 0
    private var lastHeartbeat: CFTimeInterval = 0
    static let heartbeatInterval: CFTimeInterval = 3
    private var lastJPEG: Data?
    /// The last frame came out (nearly) black: an app that hides its screen
    /// from capture (banking, payment), so viewers fall back to outlines.
    private var screenHidden = false
    private let started = CACurrentMediaTime()
    private var frames = 0
    private var statsSince = CACurrentMediaTime()
    // Where a frame's time goes, for the stats line in the log.
    private var captures = 0
    private var captureTime: CFTimeInterval = 0
    private var convertTime: CFTimeInterval = 0
    private var pausedTime: CFTimeInterval = 0

    private func log(_ message: String) {
        NSLog("LoopCtrl stream: %@", message)
        Self.onLog?("🎥 " + message)
    }

    // MARK: - Viewers

    func add(_ connection: NWConnection, request: ScreenStreamRequest) {
        let id = SecureEnvelope.randomBytes(8)?.hexString ?? UUID().uuidString
        let viewer = Viewer(id: id, connection: connection, sealer: ScreenStreamSealer(pairingKey: request.key),
                            codec: request.codec, acks: request.acks)
        queue.async {
            self.viewers[id] = viewer
            if request.quality != self.quality || self.viewers.count == 1 {
                self.quality = request.quality
                // With feedback, start where most links cope and climb from
                // there; a first burst at the full rate is what a slow link
                // would be stuck queueing.
                self.bitrate = request.acks ? min(request.quality.bitsPerSecond, Self.startBitrate)
                    : request.quality.bitsPerSecond
                self.teardownEncoder()   // new size and bitrate on the next frame
            }
            self.chooseCodec()
            if let workers = request.workers { self.workerCount = min(max(workers, 1), 3) }
            self.forceKeyframe = true
            self.lastJPEG = nil
            self.log("viewer joined (\(self.viewers.count) watching, \(request.quality.rawValue), \(request.codec.rawValue)"
                     + "\(request.acks ? ", acknowledging" : "")\(viewer.sealer.encrypted ? ", encrypted" : ""))")
            if let client = request.client {
                viewer.client = client
                RemoteSession.shared.watch(tok: client, name: AuthManager.shared.clientName(forTokenId: client) ?? client)
            }
            viewer.start(onClose: { self.queue.async { self.remove(id) } })
            if let config = self.config { viewer.sendConfig(config) }
            viewer.sendState(self.stateFields())
            Self.onViewersChange?(self.viewers.count)
            self.startCaptureIfNeeded()
            self.startController()
        }
    }

    private func remove(_ id: String) {
        guard let viewer = viewers.removeValue(forKey: id) else { return }
        if let client = viewer.client { RemoteSession.shared.unwatch(tok: client) }
        log("viewer left (\(viewers.count) watching)")
        Self.onViewersChange?(viewers.count)
        if viewers.isEmpty {
            teardownEncoder()
            controller?.cancel()
            controller = nil
        } else {
            chooseCodec()
        }
    }

    /// HEVC only when every viewer asked for it: one encoder serves them all.
    private func chooseCodec() {
        let wanted: ScreenStreamRequest.Codec =
            !hevcUnavailable && viewers.values.allSatisfy { $0.codec == .hevc } ? .hevc : .h264
        guard wanted != codec else { return }
        codec = wanted
        teardownEncoder()
        forceKeyframe = true
    }

    /// Tell every viewer who holds control and whether the owner paused (the
    /// runner calls this when `RemoteSession` changes).
    func broadcastState() {
        queue.async {
            if RemoteSession.shared.paused { self.log("paused by the owner: no frames until they resume") }
            let state = self.stateFields()
            for viewer in self.viewers.values { viewer.sendState(state) }
            if !RemoteSession.shared.paused { self.forceKeyframe = true; self.lastJPEG = nil; self.wake.signal() }
        }
    }

    private func stateFields() -> [String: JSONValue] {
        var fields = RemoteSession.shared.state()
        fields["hidden"] = .bool(screenHidden)
        fields["page"] = .int(PageUpdate.servedVersion)
        return fields
    }

    /// The viewer has everything up to the frame stamped `micros`, and saw
    /// it arrive `queueMs` later than the quickest frame lately (nil from a
    /// client that doesn't measure). `wantsKey`: its decoder dropped frames
    /// or failed, and shows nothing new until a keyframe.
    func ack(viewer: String, micros: UInt64, queueMs: Double?, wantsKey: Bool = false) {
        queue.async {
            guard let v = self.viewers[viewer] else { return }
            v.ack(upTo: micros, queue: queueMs.map { $0 / 1000 })
            if wantsKey {
                v.wantKeyframe()
                self.wake.signal()
            }
        }
    }

    // MARK: - Bitrate

    private func startController() {
        guard controller == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.heartbeat()
            self?.adjustBitrate()
        }
        timer.resume()
        controller = timer
    }

    /// Every few seconds, the state again: a still screen sends no frames, and
    /// without this the page couldn't tell it from a link that died quietly.
    private func heartbeat() {
        let now = CACurrentMediaTime()
        guard now - lastHeartbeat >= Self.heartbeatInterval else { return }
        lastHeartbeat = now
        let state = stateFields()
        for viewer in viewers.values { viewer.sendState(state) }
    }

    /// Once a second: down to what got through when a viewer fell behind,
    /// back up by a quarter each second once two have passed calmly.
    private func adjustBitrate() {
        let reports = viewers.values.compactMap { $0.takeReport() }
        guard !reports.isEmpty else { return }
        let ceiling = quality.bitsPerSecond
        var target = bitrate
        let congested = reports.filter(\.fellBehind)
        if let slowest = congested.map(\.deliveredBitsPerSecond).min() {
            // What got through understates the link while frames were held
            // back, so never more than halve in one step.
            calmTicks = 0
            target = max(Self.minBitrate, bitrate / 2, min(bitrate, Int(Double(slowest) * 0.85)))
        } else {
            calmTicks += 1
            if calmTicks >= 2 { target = min(ceiling, Int(Double(bitrate) * 1.25)) }
        }
        guard target != bitrate else { return }
        let before = bitrate
        bitrate = target
        applyBitrate()
        if abs(target - before) * 10 >= before { log("bitrate \(before / 1000) → \(target / 1000) kbps") }
    }

    private func applyBitrate() {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        Self.limitBursts(session, bitrate: bitrate)
    }

    /// At most half again the bitrate over a second, and twice it over any
    /// 0.2 s. With only the one-second limit, fast motion (the app switcher
    /// opening) spent a second's bytes in a tenth of one: the queue that built
    /// paused capture for a second, and the viewer saw the animation stop and
    /// jump. Bounded over 0.2 s, such frames come out softer instead. Encoders
    /// that take one limit only get the one-second one.
    private static func limitBursts(_ session: VTCompressionSession, bitrate: Int) {
        let perSecond = bitrate / 8
        let both = [perSecond * 3 / 2, 1, perSecond * 2 / 5, 0.2] as [Any] as CFArray
        if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: both) != noErr {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: [perSecond * 3 / 2, 1] as CFArray)
        }
    }

    /// Capture now instead of at the next tick: something on screen just
    /// changed because of an action.
    func nudge() {
        wake.signal()
    }

    // MARK: - Capture

    /// Capture runs on `workerCount` threads, paced to the frame rate in
    /// turn: one capture takes ~30 ms on a phone, so a second worker capturing
    /// while the first one's frame is being encoded is what lifts the stream
    /// from ~30 to 60 fps. Frames are stamped in the order their captures
    /// start; one that finishes after a later one is dropped.
    private func startCaptureIfNeeded() {
        if activeWorkers == 0 {
            frames = 0
            captures = 0
            captureTime = 0
            convertTime = 0
            pausedTime = 0
            statsSince = CACurrentMediaTime()
            nextSlot = 0
            log("capture started (\(workerCount) worker\(workerCount == 1 ? "" : "s"))")
        }
        while activeWorkers < workerCount {
            activeWorkers += 1
            let thread = Thread { [weak self] in self?.captureLoop() }
            thread.name = "LoopCtrl screen capture \(activeWorkers)"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    private func captureLoop() {
        var misses = 0
        while true {
            var stop = false
            var quality = ScreenStreamRequest.Quality.medium
            var force = false
            var paused = false
            var slot: CFTimeInterval = 0
            var seq: UInt64 = 0
            queue.sync {
                if viewers.isEmpty || activeWorkers > workerCount {
                    activeWorkers -= 1
                    stop = true
                    if activeWorkers == 0, viewers.isEmpty { log("capture stopped") }
                    return
                }
                quality = self.quality
                // A viewer is waiting for a keyframe (it missed frames, or
                // its decoder did): make one even if the screen is still,
                // at most once a second, until it has one. Otherwise a
                // still screen leaves it showing an old picture for good.
                let now = CACurrentMediaTime()
                if !forceKeyframe, now - lastForcedAt > 1, viewers.values.contains(where: \.waitingForKeyframe) {
                    forceKeyframe = true
                    lastForcedAt = now
                }
                force = forceKeyframe
                // A frame now would only queue behind the ones in flight, or
                // the owner has paused remote viewing.
                paused = RemoteSession.shared.paused || viewers.values.contains { $0.behind() }
                if !paused {
                    let now = CACurrentMediaTime()
                    slot = max(now, nextSlot)
                    nextSlot = slot + 1 / quality.fps
                    captureSeq += 1
                    seq = captureSeq
                }
            }
            if stop { break }
            if paused {
                let pauseStart = CACurrentMediaTime()
                _ = wake.wait(timeout: .now() + 0.02)
                queue.sync { pausedTime += CACurrentMediaTime() - pauseStart }
                continue
            }
            let wait = slot - CACurrentMediaTime()
            // A nudge (an action just changed the screen) captures at once.
            if wait > 0 { _ = wake.wait(timeout: .now() + wait) }
            let started = CACurrentMediaTime()
            guard let grab, let shot = autoreleasepool(invoking: { grab(quality.jpegQuality) }) else {
                misses += 1
                if misses == 3 {
                    // Captures that overlap may be what fails on this OS:
                    // back to one at a time.
                    queue.sync {
                        if workerCount > 1 {
                            workerCount = 1
                            log("captures failing with \(activeWorkers) workers: down to 1")
                        }
                    }
                }
                continue
            }
            misses = 0
            let grabbed = CACurrentMediaTime() - started
            // Handed off, not waited for: the worker goes straight back to
            // capturing while the frame is converted and encoded.
            queue.async {
                self.captures += 1
                self.captureTime += grabbed
                // A later capture already went out: this one is stale.
                guard seq > self.encodedSeq else { return }
                if !force, let jpeg = shot.jpeg, jpeg == self.lastJPEG { return }
                self.encodedSeq = seq
                self.lastJPEG = shot.jpeg
                self.encode(shot.image, scale: shot.scale, quality: quality)
            }
        }
    }

    // MARK: - Encoding (on `queue`)

    private func encode(_ cg: CGImage, scale: Double, quality: ScreenStreamRequest.Quality) {
        let (width, height) = Self.fit(width: cg.width, height: cg.height, longSide: quality.longSide)
        if session == nil || encodedSize != (width, height) {
            teardownEncoder()
            if !makeEncoder(width: width, height: height, quality: quality) {
                guard codec == .hevc else { return }
                // No HEVC encoder here: H.264 for everyone, for good.
                hevcUnavailable = true
                codec = .h264
                guard makeEncoder(width: width, height: height, quality: quality) else { return }
            }
            config = nil
            forceKeyframe = true
            // Screenshots are in pixels; taps are in points.
            pointSize = (Double(cg.width) / max(scale, 1), Double(cg.height) / max(scale, 1))
        }
        guard let session, let pool else { return }
        let convertStart = CACurrentMediaTime()
        defer { convertTime += CACurrentMediaTime() - convertStart }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let drawn: Bool = {
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }()
        let hidden = drawn && Self.nearlyBlack(buffer)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drawn else { return }
        if hidden != screenHidden {
            screenHidden = hidden
            log(hidden ? "screen hidden from capture (black frame): viewers show outlines" : "screen visible again")
            let state = stateFields()
            for viewer in viewers.values { viewer.sendState(state) }
        }

        var options: CFDictionary?
        if forceKeyframe {
            options = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyframe = false
        }
        let micros = UInt64((CACurrentMediaTime() - started) * 1_000_000)
        let pts = CMTime(value: CMTimeValue(micros), timescale: 1_000_000)
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: options,
                                        infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.queue.async { self?.deliver(sample, micros: micros) }
        }
    }

    private var pointSize: (Double, Double) = (0, 0)

    /// Whether a 16×16 grid of samples is all but black (BGRA, locked).
    private static func nearlyBlack(_ buffer: CVPixelBuffer) -> Bool {
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for gy in 0..<16 {
            for gx in 0..<16 {
                let x = (gx * 2 + 1) * width / 32, y = (gy * 2 + 1) * height / 32
                let p = base + y * row + x * 4
                if max(p[0], p[1], p[2]) > 24 { return false }
            }
        }
        return true
    }

    private func makeEncoder(width: Int, height: Int, quality: ScreenStreamRequest.Quality) -> Bool {
        var made: VTCompressionSession?
        let hevc = codec == .hevc
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let made else {
            log("\(codec.rawValue) encoder could not start (\(status))")
            return false
        }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_ProfileLevel: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: quality.fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(quality.fps * 4),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 4,
        ]
        for (key, value) in props {
            VTSessionSetProperty(made, key: key, value: value as CFTypeRef)
        }
        Self.limitBursts(made, bitrate: bitrate)
        VTCompressionSessionPrepareToEncodeFrames(made)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &newPool)
        guard let newPool else {
            VTCompressionSessionInvalidate(made)
            return false
        }
        session = made
        pool = newPool
        encodedSize = (width, height)
        log("\(codec.rawValue) encoder \(width)x\(height) \(quality.rawValue) \(bitrate / 1000) kbps")
        return true
    }

    private func teardownEncoder() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        pool = nil
        encodedSize = (0, 0)
        config = nil
    }

    private func deliver(_ sample: CMSampleBuffer, micros: UInt64) {
        // Encoded before the owner paused: never sent.
        if RemoteSession.shared.paused { return }
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let keyframe = Self.isKeyframe(sample)
        if keyframe || config == nil, let fresh = makeConfig(format) {
            if config.map({ NSDictionary(dictionary: $0) != NSDictionary(dictionary: fresh) }) ?? true {
                config = fresh
                for viewer in viewers.values { viewer.sendConfig(fresh) }
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let unit = Data(bytes: pointer, count: length)
        var wantKey = false
        for viewer in viewers.values {
            if viewer.send(unit, keyframe: keyframe, micros: micros) { wantKey = true }
        }
        // Someone missed frames: give them a keyframe, at most once a second.
        if wantKey, CACurrentMediaTime() - lastForcedAt > 1 {
            lastForcedAt = CACurrentMediaTime()
            forceKeyframe = true
            wake.signal()
        }
        frames += 1
        let now = CACurrentMediaTime()
        if now - statsSince >= 30 {
            let span = now - statsSince
            let n = Double(max(captures, 1))
            log(String(format: "%.1f fps over the last %.0f s: capture %.0f ms, convert %.0f ms a frame, paused %.0f%%, %d kbps",
                       Double(frames) / span, span, captureTime / n * 1000, convertTime / n * 1000,
                       pausedTime / span * 100, bitrate / 1000))
            frames = 0
            captures = 0
            captureTime = 0
            convertTime = 0
            pausedTime = 0
            statsSince = now
        }
    }

    /// The decoder configuration (avcC or hvcC) and its codec string.
    private func makeConfig(_ format: CMFormatDescription) -> [String: Any]? {
        guard let atoms = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
        else { return nil }
        let codecString: String
        let description: Data
        if let hvcC = atoms["hvcC"] as? Data {
            codecString = ScreenStreamSealer.codecString(hvcC: hvcC)
            description = hvcC
        } else if let avcC = atoms["avcC"] as? Data {
            var sps: UnsafePointer<UInt8>?
            var spsLength = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsLength,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let sps else { return nil }
            codecString = ScreenStreamSealer.codecString(sps: Data(bytes: sps, count: spsLength))
            description = avcC
        } else {
            return nil
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        return [
            "codec": codecString,
            "width": Int(dims.width), "height": Int(dims.height),
            "point_width": pointSize.0, "point_height": pointSize.1,
            "description": description.base64EncodedString(),
        ]
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// The largest even size with this aspect whose longer side is at most
    /// `longSide`, never larger than the source.
    /// Multiples of 16, the codecs' block size, so no decoder has to crop a
    /// padded edge. 882 wide (an iPhone's 1206 at 1920 high) needed that, and
    /// Edge's H.265 decoder on Windows drew such a stream wrong (the top half
    /// of the screen stretched over all of it) — the likeliest reason.
    static func fit(width: Int, height: Int, longSide: Int) -> (Int, Int) {
        let scale = min(1, Double(longSide) / Double(max(width, height)))
        func block(_ v: Double) -> Int { max(16, Int(v) & ~15) }
        return (block(Double(width) * scale), block(Double(height) * scale))
    }
}

/// One viewer's connection. Touched only on the stream's queue.
private final class Viewer {
    let id: String
    let connection: NWConnection
    let sealer: ScreenStreamSealer
    let codec: ScreenStreamRequest.Codec
    let acks: Bool
    /// The paired client watching (token id), when known.
    var client: String?
    private var inFlight = false
    private var needsKeyframe = true
    private var closed = false
    private var onClose: (() -> Void)?

    // Acknowledgement bookkeeping, for viewers that send them.
    private struct Sent {
        let micros: UInt64
        let bytes: Int
        let at: CFTimeInterval
    }
    private var sent: [Sent] = []
    /// The quickest a frame has come back lately: the path's own delay,
    /// without any queue. Sampled with its time, so it can rise again.
    private var baseDelays: [(at: CFTimeInterval, delay: CFTimeInterval)] = []
    /// The viewer's own reading of the queue: how much later than the
    /// quickest frame lately its newest frame arrived. One way, so the slow
    /// trip of the acknowledgement itself doesn't count. With when it came.
    private var reportedQueue: CFTimeInterval?
    private var reportedAt: CFTimeInterval = 0
    private var deliveredBytes = 0
    private var dropped = 0
    private var wasBehind = false
    private var reportSince = CACurrentMediaTime()

    struct Report {
        let deliveredBitsPerSecond: Int
        let fellBehind: Bool
    }

    init(id: String, connection: NWConnection, sealer: ScreenStreamSealer,
         codec: ScreenStreamRequest.Codec, acks: Bool) {
        self.id = id
        self.connection = connection
        self.sealer = sealer
        self.codec = codec
        self.acks = acks
    }

    func start(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/vnd.loopctrl.stream\r\n"
            + "Cache-Control: no-store\r\n"
            + "X-Accel-Buffering: no\r\n"
            + "Connection: close\r\n\r\n"
        write(Data(head.utf8) + sealer.hello(viewer: id))
        watchForClose()
    }

    /// The peer sends nothing after its request; any read completing means
    /// it has gone.
    private func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil { self.close() } else { self.watchForClose() }
        }
    }

    /// Shows nothing new until a keyframe reaches it.
    var waitingForKeyframe: Bool { !closed && needsKeyframe }

    func wantKeyframe() { needsKeyframe = true }

    func sendState(_ state: [String: JSONValue]) {
        guard let message = sealer.state(state) else { return }
        write(message, counted: false)
    }

    func sendConfig(_ config: [String: Any]) {
        guard let message = sealer.config(config) else { return }
        // Configuration always goes out, behind whatever is in flight.
        write(message, counted: false)
        needsKeyframe = true
    }

    /// Queues one access unit. Returns true when this viewer is waiting for
    /// a keyframe, so the encoder can make one sooner.
    func send(_ unit: Data, keyframe: Bool, micros: UInt64) -> Bool {
        if closed { return false }
        if needsKeyframe && !keyframe { return true }
        if inFlight {
            // Still writing the last frame: skip this one, and the deltas
            // that depend on it, until the next keyframe.
            needsKeyframe = true
            dropped += 1
            return true
        }
        guard let message = sealer.frame(keyframe: keyframe, timestampMicros: micros, accessUnit: unit) else { return false }
        needsKeyframe = false
        if acks { sent.append(Sent(micros: micros, bytes: message.count, at: CACurrentMediaTime())) }
        write(message)
        return false
    }

    /// Whether frames are queueing on the way to this viewer. Always false
    /// for a viewer that doesn't acknowledge.
    func behind() -> Bool {
        guard acks else { return false }
        let now = CACurrentMediaTime()
        if let oldest = sent.first, now - oldest.at > 3 {
            // Acknowledgements stopped coming (or got lost): start afresh
            // rather than stall for good.
            sent.removeAll()
            reportedQueue = nil
            return false
        }
        let queued: Bool
        if let q = reportedQueue, now - reportedAt < 2 {
            // While nothing new joins it, the queue drains in real time.
            queued = q - (now - reportedAt) > 0.2
        } else if let oldest = sent.first {
            // A client that doesn't measure: only how long the oldest frame
            // has waited, generously, since that includes the
            // acknowledgement's own trip.
            let base = baseDelays.map(\.delay).min() ?? 0.15
            queued = now - oldest.at > max(1.0, base + 0.6)
        } else {
            queued = false
        }
        if queued { wasBehind = true }
        return queued
    }

    func ack(upTo micros: UInt64, queue: CFTimeInterval?) {
        let now = CACurrentMediaTime()
        if let queue {
            reportedQueue = max(0, queue)
            reportedAt = now
        }
        var newest: Sent?
        while let first = sent.first, first.micros <= micros {
            deliveredBytes += first.bytes
            newest = first
            sent.removeFirst()
        }
        guard let newest else { return }
        baseDelays.append((now, now - newest.at))
        baseDelays.removeAll { now - $0.at > 10 }
    }

    /// What got through since the last report, and whether frames had to be
    /// held back; nil for a viewer that doesn't acknowledge.
    func takeReport() -> Report? {
        guard acks else { return nil }
        let now = CACurrentMediaTime()
        let elapsed = max(now - reportSince, 0.001)
        let report = Report(deliveredBitsPerSecond: Int(Double(deliveredBytes * 8) / elapsed),
                            fellBehind: wasBehind || dropped > 0)
        deliveredBytes = 0
        dropped = 0
        wasBehind = false
        reportSince = now
        return report
    }

    private func write(_ data: Data, counted: Bool = true) {
        guard !closed else { return }
        if counted { inFlight = true }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            ScreenStream.sharedQueueAsync {
                if counted { self.inFlight = false }
                if error != nil { self.close() }
            }
        })
    }

    private func close() {
        ScreenStream.sharedQueueAsync {
            guard !self.closed else { return }
            self.closed = true
            self.connection.cancel()
            self.onClose?()
            self.onClose = nil
        }
    }
}

extension ScreenStream {
    /// Viewer callbacks arrive on Network's queue; their state belongs to
    /// the stream's queue.
    fileprivate static func sharedQueueAsync(_ work: @escaping () -> Void) {
        shared.queue.async(execute: work)
    }
}
