import CoreGraphics
import Foundation
import StreamProtocol

/// Sill Desktop Host addition: "Fit screen" and "Match this screen" for the whole desktop.
///
/// Sill's virtual display holds one streamed window; the Desktop source always captures the Mac's
/// main display. Here the desktop gets a virtual display of its own, sized to the viewer (its panel
/// in points, at 2× when Sharp is on; or, for Match this screen, exactly the viewer's monitor), and
/// that display becomes the main one: the menu bar, the Dock and new windows go there, and the
/// Desktop source captures it. The real displays stay on, to its right. Releasing it removes the
/// display; macOS then makes a real display main again and windows on it come back.
@MainActor
final class DesktopFit {
    struct Size: Equatable, CustomStringConvertible {
        var widthPt: Int
        var heightPt: Int
        var scale: Int
        var description: String { "\(widthPt)×\(heightPt) pt at \(scale)×" }
    }

    private var display: VirtualDisplay?
    private(set) var size: Size?
    /// The main display before ours took its place.
    private var savedMain: CGDirectDisplayID?

    var isOn: Bool { display != nil }

    func matches(_ want: Size) -> Bool { display != nil && size == want }

    /// What the viewer asks for: Match this screen's exact pixels when its viewport carries them,
    /// else its panel in points. Nil when it is out of range.
    static func wanted(viewport v: Viewport?, sharp: Bool) -> Size? {
        guard let v else { return nil }
        var s: Size
        if let pw = v.pixelWidth, let ph = v.pixelHeight, pw > 0, ph > 0 {
            let scale = (v.pixelScale ?? 1) >= 1.5 ? 2 : 1
            s = Size(widthPt: pw / scale, heightPt: ph / scale, scale: scale)
        } else {
            s = Size(widthPt: Int(v.width.rounded()), heightPt: Int(v.height.rounded()), scale: sharp ? 2 : 1)
        }
        s.widthPt -= s.widthPt % 2
        s.heightPt -= s.heightPt % 2
        guard s.widthPt >= 320, s.heightPt >= 240, s.widthPt * s.scale <= 8192, s.heightPt * s.scale <= 8192 else { return nil }
        return s
    }

    /// Makes the desktop's display `want`, and the main display. True when something changed (the
    /// caller then reads the displays again before capturing).
    func apply(_ want: Size) async -> Bool {
        if matches(want) { return false }
        release(restoreMain: false)   // a new size: the old main display comes back only at the end
        do {
            // Not Sill's stage display (vendor 0x5111, product 1): its own identity, so macOS keeps
            // their arrangements apart.
            let d = try VirtualDisplay(name: "Sill Desktop", widthPt: want.widthPt, heightPt: want.heightPt,
                                       scale: want.scale, refreshHz: 60, vendorID: 0x5111, productID: 0x0002, serialNum: 2)
            display = d
            size = want
            if !(await d.waitUntilOnline(timeout: 4)) {
                print("Desktop fit: the display came up at \(Int(d.bounds.width))×\(Int(d.bounds.height)) pt, not \(want)")
            }
            makeMain(d.displayID, widthPt: want.widthPt)
            // A moment for the window server to move the menu bar and the Dock.
            try? await Task.sleep(nanoseconds: 300_000_000)
            print("Desktop fit: the desktop is on a virtual display, \(want)")
            return true
        } catch {
            print("Desktop fit: no virtual display (\(error)); streaming the real display")
            display = nil
            size = nil
            return false
        }
    }

    /// Removes the desktop's display; a real one becomes main again. Safe to call twice.
    func release(restoreMain: Bool = true) {
        guard let d = display else { return }
        d.destroy()
        display = nil
        size = nil
        if restoreMain, let saved = savedMain {
            savedMain = nil
            // macOS picks a new main display itself; put back the one that was main before, if it
            // is still there and macOS chose another.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if CGMainDisplayID() != saved, Self.onlineDisplays().contains(saved) {
                    Self.makeMainOnly(saved)
                }
            }
        }
        print("Desktop fit: off; the real display is the desktop again")
    }

    /// Puts `id` at (0, 0), which makes it the main display, and the others to its right, keeping
    /// their arrangement.
    private func makeMain(_ id: CGDirectDisplayID, widthPt: Int) {
        guard id != 0 else { return }
        if savedMain == nil { savedMain = CGMainDisplayID() }
        let others = Self.onlineDisplays().filter { $0 != id }
        let minX = others.map { CGDisplayBounds($0).minX }.min() ?? 0
        let minY = others.map { CGDisplayBounds($0).minY }.min() ?? 0
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, id, 0, 0)
        for o in others {
            let b = CGDisplayBounds(o)
            CGConfigureDisplayOrigin(config, o, Int32(Double(widthPt) + b.minX - minX), Int32(b.minY - minY))
        }
        let r = CGCompleteDisplayConfiguration(config, .forSession)
        if r != .success { print("Desktop fit: could not make it the main display (\(r.rawValue))") }
    }

    /// `id` at (0, 0) and the rest as they are, shifted so none overlaps it.
    private static func makeMainOnly(_ id: CGDirectDisplayID) {
        let b = CGDisplayBounds(id)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for o in onlineDisplays() {
            let ob = CGDisplayBounds(o)
            CGConfigureDisplayOrigin(config, o, Int32(ob.minX - b.minX), Int32(ob.minY - b.minY))
        }
        _ = CGCompleteDisplayConfiguration(config, .forSession)
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
