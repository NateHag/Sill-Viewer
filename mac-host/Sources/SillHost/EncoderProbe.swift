import Foundation
import CoreVideo
import CoreMedia

/// Frames through a new hardware HEVC session, to learn whether the encoder can carry a stream:
/// at launch one small frame (`hardwareResponds`, about 100 ms when healthy), and while the host
/// streams on the software encoder a short run at the stream's own size (`throughput`, the
/// coordinator's re-check), held against the rate a return needs (`returnBar`).
///
/// A probe that gets no answer is one of two things. On 2026-09-22 the Mac's hardware encoder was
/// stuck system-wide for about three hours: every session took a frame and never answered, and
/// each such session keeps a thread blocked for good (nothing can free it; the fallback path
/// leaks the same). On 2026-09-24 it was busy: the iOS Simulator's screen recorder held the one
/// encoder engine at a higher firmware priority, and frames of real-time sessions waited seconds,
/// then came back. A small frame answers even then (256×256 within 270 ms while a stream-size
/// session beside it was still starved; on 2026-09-25 in 72 ms, and the stream that went back to
/// the hardware on that answer ran at 12 fps), which is why the re-check measures a rate at the
/// stream's size. A probe frame that comes back late is counted out again (`stuckProbes`, and
/// `onStalledProbeBack` says so), so only a stuck encoder piles them up.
enum EncoderProbe {
    /// Probe sessions whose frame has not come back. Each holds a blocked thread while it lasts;
    /// the re-check stops probing while too many are out (StreamCoordinator.maxStuckProbes).
    static var stuckProbes: Int { lock.lock(); defer { lock.unlock() }; return stuck }
    /// Called on a utility queue each time a probe's stalled frame comes back, with the seconds it
    /// was inside, right after `stuckProbes` went down: the coordinator stops calling the encoder
    /// stuck then, not at its next check, which can be 300 s away or, with no device connected,
    /// never come. Set once, before the first probe.
    static var onStalledProbeBack: ((TimeInterval) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stalledProbeBack }
        set { lock.lock(); stalledProbeBack = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    private static var stuck = 0
    private static var stalledProbeBack: ((TimeInterval) -> Void)?
    /// TEST ONLY. `SILL_TEST_PROBE_HOLD=S`: every frame of every probe waits S seconds before it
    /// goes in. Over the 1 s timeout a probe gets no answer and its frame comes back S seconds later
    /// (a busy encoder), or with a huge S never (a stuck one); S = 0.08 makes a throughput probe
    /// measure ~12 fps (a starved one). Read once; 0 without it.
    private static let testHold = TimeInterval(ProcessInfo.processInfo.environment["SILL_TEST_PROBE_HOLD"] ?? "") ?? 0

    /// What one encoder engine is taken to do alone, in pixels a second, until a test has measured
    /// more (the coordinator keeps the best any test measured): well under what this M2 Pro's engine
    /// does in `throughput` (700–800 MP/s: ~120 fps at 3024×1904, ~39 at 6016×3384, 2026-09-25), so
    /// `returnBar` never asks a slower engine for more than it has.
    static let assumedEnginePixelRate = 400e6

    /// The rate `throughput` must measure at `pixels` a frame for the stream to go back to the
    /// hardware: `share` of the stream's rate (60 at most, what the software encoder gives), but
    /// never more than `share` of what the engine does alone at that size (`enginePixelRate`,
    /// pixels a second). 45 fps suits a Retina laptop's Desktop (~120 fps in the test on a free
    /// engine here; two ordinary sessions share it at ~50 fps each, a starved one runs at 7–18),
    /// but a free engine tests a Retina 6K Desktop (6016×3384) at 37–39 fps, and a fixed 45 kept
    /// such a host on the software encoder for good (5K, 5120×2880: 50–53). The same share of the
    /// engine's own rate still tells busy from free there: a starved session got a sixth of it or
    /// less.
    static func returnBar(streamFPS: Int, pixels: Int, enginePixelRate: Double, share: Double = 0.75) -> Double {
        let byStream = Double(min(streamFPS, 60)) * share
        let byEngine = enginePixelRate / Double(max(pixels, 1)) * share
        return min(byStream, byEngine)
    }

    /// True when a hardware session returns one 256×256 frame within `timeout`. The launch probe
    /// and the self-test: prints its one line and counts `enc.probeOK` or `enc.probeHung`.
    static func hardwareResponds(timeout: TimeInterval = 1.0) -> Bool {
        let started = CFAbsoluteTimeGetCurrent()
        let done = DispatchSemaphore(value: 0)
        guard let enc = try? HEVCEncoder(width: 256, height: 256, fps: 30, bitrate: 1_000_000, prioritizeSpeed: true) else {
            return false   // no hardware session at all: the software encoder is the only option
        }
        enc.onEncoded = { _, _, _ in done.signal() }
        enc.testHoldEachFrame = testHold
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      kCVPixelBufferWidthKey: 256, kCVPixelBufferHeightKey: 256,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &pb)
        guard let pb else { return true }   // cannot test; assume healthy
        CVPixelBufferLockBaseAddress(pb, [])
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) { memset(y, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * 256) }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) { memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * 128) }
        CVPixelBufferUnlockBaseAddress(pb, [])
        enc.encode(pb, pts: CMTime(value: 0, timescale: 30))
        let ok = done.wait(timeout: .now() + timeout) == .success
        if !ok { giveUp(enc) }
        Stats.shared.bump(ok ? "enc.probeOK" : "enc.probeHung")
        print("Hardware encoder probe: \(ok ? "responding" : "no answer") after \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        withExtendedLifetime(enc) {}
        return ok
    }

    /// Whether the hardware keeps up with a stream of this size now: frames of a moving test
    /// pattern through a quiet hardware session (no line, no counter), and the rate the last
    /// `frames` of them came back at. They go in one at a time, the next when the last came back,
    /// because a stream sends them so (HEVCEncoder keeps one frame inside VideoToolbox): the rate
    /// measured, the bar a return needs (`returnBar`) and the engine rate learned from the best
    /// test are then of the kind a stream gets. Three frames are drawn before the session opens
    /// and then reused, as a capture stream reuses its surfaces, and the first pass over them is
    /// left out (the session's warm-up, ~50 ms at Retina size, and each surface's first trip into
    /// the encoder): drawing a frame costs milliseconds a stream never spends there (30 MB of fresh
    /// memory at Retina 6K), and inside the timing it counted against the engine. `ok` false: a
    /// frame took longer than `timeout` (it then counts as stuck until it comes back). `fps` nil:
    /// nothing could be measured (no pixel buffers), so assume it keeps up. About 110 ms at
    /// 3024×1904 when the engine is free (~120 fps; drawn inside the timing it measured ~115) and
    /// 290 ms at 6016×3384 (~39 fps; ~37); a starved engine shows as a low rate, not as no answer.
    /// Blocks the calling thread for up to (`frames` + 3) × `timeout`: never call it on the main
    /// actor. `ms` leaves the drawing out.
    static func throughput(width: Int, height: Int, frames: Int = 7, timeout: TimeInterval = 1.0) -> (ok: Bool, fps: Double?, ms: Int) {
        let drawn = (0..<3).compactMap { testFrame(width: width, height: height, bar: $0) }
        let started = CFAbsoluteTimeGetCurrent()
        func elapsed() -> Int { Int((CFAbsoluteTimeGetCurrent() - started) * 1000) }
        guard drawn.count == 3 else { return (true, nil, elapsed()) }
        guard let enc = try? HEVCEncoder(width: width, height: height, fps: 60, bitrate: 15_000_000, prioritizeSpeed: false, quiet: true) else {
            return (false, nil, elapsed())
        }
        let done = DispatchSemaphore(value: 0)
        enc.onEncoded = { _, _, _ in done.signal() }
        enc.testHoldEachFrame = testHold
        let timed = max(1, frames)
        var timedFrom: CFAbsoluteTime = 0
        for i in 0..<(drawn.count + timed) {
            enc.encode(drawn[i % drawn.count], pts: CMTime(value: CMTimeValue(i), timescale: 60))
            guard done.wait(timeout: .now() + timeout) == .success else {
                giveUp(enc)
                return (false, nil, elapsed())
            }
            if i == drawn.count - 1 { timedFrom = CFAbsoluteTimeGetCurrent() }   // the warm-up pass is back
        }
        let span = CFAbsoluteTimeGetCurrent() - timedFrom
        withExtendedLifetime(enc) {}
        return (true, span > 0 ? Double(timed) / span : nil, elapsed())
    }

    /// Grey with a bar at the `bar`th tenth of the width, like the synthetic source: frames that
    /// follow each other differ, so there is motion to code.
    private static func testFrame(width: Int, height: Int, bar index: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), rows = CVPixelBufferGetHeightOfPlane(pb, 0)
            memset(y, 96, stride * rows)
            let bar = max(8, width / 20), x0 = (index * width / 10) % max(1, width - bar)
            for row in 0..<rows { memset(y.advanced(by: row * stride + x0), 235, bar) }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// A probe's frame did not come back in time: no watchdog report 1.5 s from now (the caller
    /// knows), and a frame still inside counts as stuck until the session lets go of it.
    private static func giveUp(_ enc: HEVCEncoder) {
        guard enc.abandon() else { return }
        lock.lock(); stuck += 1; lock.unlock()
        enc.onStalledFrameBack = { seconds in
            lock.lock(); stuck -= 1; let back = stalledProbeBack; lock.unlock()
            back?(seconds)
        }
    }
}
