import Foundation
import AppKit
import StreamProtocol

/// Streams the Mac's current cursor shape to the clients, so the pointer they draw themselves
/// turns into an I-beam over text, a hand over a link, a resize arrow at an edge, exactly as on
/// the Mac. `NSCursor.currentSystem` is the cursor the window server is showing, whichever app
/// owns it. Polled at 20 Hz on the main queue only while a source is streaming.
///
/// Cost matters here: this runs on the main thread beside the coordinator. The first version
/// fingerprinted a TIFF of every representation (the arrow's is 583 KB across four sizes up to
/// 280×400) at ~1.4 ms per poll, about as much CPU as the whole streaming pipeline. Now the
/// fingerprint is the hotspot, the point size and the pixels of the smallest bitmap (a few KB);
/// the PNG is only made when the shape actually changes, from the representation nearest 2×.
@MainActor
final class CursorShapeWatcher {
    /// A new shape, already encoded. Main thread.
    var onChange: ((Data) -> Void)?
    /// The last blob sent, for a client that just connected.
    private(set) var current: Data?

    var running = false {
        didSet {
            guard running != oldValue else { return }
            if running { start() } else { stop() }
        }
    }

    private var timer: DispatchSourceTimer?
    private var lastHash: Int?

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func stop() {
        timer?.cancel(); timer = nil
        lastHash = nil
    }

    private func poll() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        let hash = Self.fingerprint(of: image, hotspot: cursor.hotSpot)
        guard hash != lastHash else { return }
        // The representation nearest 2× the point size: what a Retina device draws, without the
        // 5× and 10× assets some system cursors carry.
        let wanted = image.size.width * 2
        guard let rep = image.representations.min(by: { abs(CGFloat($0.pixelsWide) - wanted) < abs(CGFloat($1.pixelsWide) - wanted) }),
              let png = Self.png(of: rep) else { return }
        lastHash = hash   // only once the PNG exists, so a failed encode is retried next poll
        let blob = CursorShapeBlob.encode(hotspot: cursor.hotSpot, size: image.size, png: png)
        current = blob
        onChange?(blob)
        Stats.shared.bump("cursor.shape")
    }

    private static func fingerprint(of image: NSImage, hotspot: NSPoint) -> Int {
        var hasher = Hasher()
        hasher.combine(hotspot.x); hasher.combine(hotspot.y)
        hasher.combine(image.size.width); hasher.combine(image.size.height)
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let small = bitmaps.min(by: { $0.pixelsWide < $1.pixelsWide }), let bytes = small.bitmapData {
            hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: small.bytesPerRow * small.pixelsHigh))
        } else if let tiff = image.tiffRepresentation {
            hasher.combine(tiff)   // no bitmap representation: fall back to the expensive way
        }
        return hasher.finalize()
    }

    private static func png(of rep: NSImageRep) -> Data? {
        if let bitmap = rep as? NSBitmapImageRep { return bitmap.representation(using: .png, properties: [:]) }
        guard let cg = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
