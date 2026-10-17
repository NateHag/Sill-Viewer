import Foundation
import CoreVideo
import CoreMedia
import CoreGraphics
import ImageIO

/// `SillHost --synthetic`: a moving test pattern stands in for ScreenCaptureKit, so the encoder,
/// its software fallback and the network path can be exercised without Screen Recording.
/// Diagnostics only; the coordinator uses it for the Desktop source in that mode.
/// `pool` and `frameIndex` live on `queue`; `timer` is touched only by the main actor.
///
/// TEST ONLY: `SILL_TEST_PATTERN=noise` adds a square of random pixels, new every frame, so what the
/// encoder puts out follows its bitrate: the sweeping bar alone compresses to about 56 kbit/s on the
/// software encoder whatever the quality, and a link's end-to-end tests need a stream that picking a
/// lower quality makes smaller (docs/remote-bundle-plan.md, H12 and S3). Read once; this type runs
/// only on a --synthetic host.
///
/// TEST ONLY: `SILL_TEST_PATTERN=picture:<path>` shows that picture (any image ImageIO reads), still,
/// filling the frame and cropped to its shape, in place of the grey ground and its bar: a Desktop
/// that looks like one, for photographs of the device (docs/iphone-duo-plan.md). A picture that does
/// not load gives the pattern, with one line.
final class SyntheticCapture: @unchecked Sendable {   // state is confined to `queue` (see above)
    static let noise: Bool = ProcessInfo.processInfo.environment["SILL_TEST_PATTERN"] == "noise"
    /// `SILL_TEST_PATTERN=picture:<path>`'s path.
    static let picturePath: String? = {
        guard let raw = ProcessInfo.processInfo.environment["SILL_TEST_PATTERN"], raw.hasPrefix("picture:") else { return nil }
        return String(raw.dropFirst("picture:".count))
    }()
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private let queue = DispatchQueue(label: "sill.synthetic", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameIndex = 0
    private var fps = 60
    /// The picture's planes at the frame's size (`SILL_TEST_PATTERN=picture:`), nil for the pattern.
    private var picture: SyntheticPicture?

    func start(width: Int, height: Int, fps: Int) {
        timer?.cancel()
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        let picture = Self.picturePath.flatMap { SyntheticPicture(path: $0, width: width, height: height) }
        if let path = Self.picturePath, picture == nil { print("Synthetic capture: \(path) did not load; the pattern instead (SILL_TEST_PATTERN)") }
        queue.async { [weak self] in self?.pool = pool; self?.frameIndex = 0; self?.fps = fps; self?.picture = picture }   // ordered before the timer's first tick
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        print("Synthetic capture: \(width)×\(height) @\(fps) fps" + (Self.noise ? ", a square of noise (SILL_TEST_PATTERN)" : "")
              + (picture != nil ? ", a picture (SILL_TEST_PATTERN)" : ""))
    }

    /// Returns once no tick is running any more, so no late frame reaches the next encoder.
    func stop() async {
        timer?.cancel(); timer = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in self?.pool = nil; c.resume() }
        }
    }

    private func tick() {
        guard let pool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { Stats.shared.bump("syn.noBuffer"); return }
        frameIndex += 1
        CVPixelBufferLockBaseAddress(pb, [])
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        if let picture, picture.fill(pb) {
            CVPixelBufferUnlockBaseAddress(pb, [])
            Stats.shared.bump("cap.complete")
            onFrame?(pb, CMClockGetTime(CMClockGetHostTimeClock()))
            return
        }
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            // Grey ground with a bright bar sweeping left to right about once a second: a frozen
            // frame is obvious on the device, and the encoder gets real motion to code.
            memset(y, 96, stride * h)
            let barWidth = max(8, w / 20)
            let x0 = (frameIndex * max(1, w / fps)) % max(1, w - barWidth)   // one sweep a second at any rate
            for row in 0..<h { memset(y.advanced(by: row * stride + x0), 235, barWidth) }
            if Self.noise {
                // TEST ONLY: a square of random pixels, new every frame, a third of the frame's height
                // on a side: more than any quality carries whole, so what the encoder puts out follows
                // its bitrate (at 1512×948 the software encoder keeps about 14 frames a second of it:
                // about 3.6 Mbit/s at Low, 10.6 at Balanced).
                let side = min(w, h) / 3
                let left = (w - side) / 2
                for row in (h - side) / 2 ..< (h + side) / 2 { arc4random_buf(y.advanced(by: row * stride + left), side) }
            }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        Stats.shared.bump("cap.complete")
        onFrame?(pb, CMClockGetTime(CMClockGetHostTimeClock()))
    }
}

/// TEST ONLY (`SILL_TEST_PATTERN=picture:<path>`): a picture as the synthetic Desktop's two planes,
/// made once at the frame's size: drawn to fill it (cropped to its shape, centred), then turned into
/// full-range Y and interleaved CbCr (BT.709).
private struct SyntheticPicture {
    let width: Int, height: Int
    let luma: [UInt8], chroma: [UInt8]

    init?(path: String, width: Int, height: Int) {
        guard width > 1, height > 1,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              image.width > 0, image.height > 0 else { return nil }
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        guard let data = context.data else { return nil }
        let rgb = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        var luma = [UInt8](repeating: 0, count: width * height)
        for i in 0 ..< width * height {
            let r = Double(rgb[i * 4]), g = Double(rgb[i * 4 + 1]), b = Double(rgb[i * 4 + 2])
            luma[i] = clamp(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        let cw = width / 2, ch = height / 2
        var chroma = [UInt8](repeating: 128, count: cw * ch * 2)
        for cy in 0 ..< ch {
            for cx in 0 ..< cw {
                var r = 0.0, g = 0.0, b = 0.0
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let i = ((cy * 2 + dy) * width + cx * 2 + dx) * 4
                    r += Double(rgb[i]); g += Double(rgb[i + 1]); b += Double(rgb[i + 2])
                }
                r /= 4; g /= 4; b /= 4
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                chroma[(cy * cw + cx) * 2] = clamp((b - y) / 1.8556 + 128)
                chroma[(cy * cw + cx) * 2 + 1] = clamp((r - y) / 1.5748 + 128)
            }
        }
        self.width = width; self.height = height; self.luma = luma; self.chroma = chroma
    }

    /// Copies the planes into `pb` (its base address locked); false when its size is not the picture's.
    func fill(_ pb: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetWidthOfPlane(pb, 0) == width, CVPixelBufferGetHeightOfPlane(pb, 0) == height,
              let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return false }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let rows = min(CVPixelBufferGetHeightOfPlane(pb, 1), height / 2), uvBytes = min(uvStride, (width / 2) * 2)
        luma.withUnsafeBytes { src in
            for row in 0 ..< height { memcpy(y.advanced(by: row * yStride), src.baseAddress! + row * width, width) }
        }
        chroma.withUnsafeBytes { src in
            for row in 0 ..< rows { memcpy(uv.advanced(by: row * uvStride), src.baseAddress! + row * (width / 2) * 2, uvBytes) }
        }
        return true
    }
}
