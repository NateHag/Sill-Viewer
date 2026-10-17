import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// `SillHost --virtual-display-selftest`: creates one 1000×700 pt @2× virtual display from a
/// process that runs the AppKit event loop exactly as `--virtual-display` does, reports what this
/// process, CoreGraphics, AppKit and ScreenCaptureKit see of it, destroys it and exits. The
/// display part needs no permission; SCShareableContent needs Screen Recording and the report
/// says so when it is missing. Exit code 0 when the display came up and went away cleanly.
package enum VirtualDisplaySelfTest {
    package static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await go()
            exit(code)
        }
        app.run()
        exit(0)   // app.run() does not return
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }

    @MainActor
    private static func go() async -> Int32 {
        print("Virtual display self-test (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        print("  Screen Recording preflight: \(CGPreflightScreenCaptureAccess()), Accessibility trusted: \(AXIsProcessTrusted()) [informational]")
        let problems = VirtualDisplay.checkPrivateAPI()
        guard problems.isEmpty else {
            for p in problems { print("  FAIL \(p)") }
            return 1
        }
        print("  private API: all \(VirtualDisplay.privateAPISurface.count) selectors present")
        let before = onlineDisplays()
        print("  displays before: \(before)")

        let t0 = Date()
        let d: VirtualDisplay
        do {
            // `--virtual-display-selftest 120` asks for a 120 Hz display (what a ProMotion device gets).
            let args = CommandLine.arguments
            let hz = args.firstIndex(of: "--virtual-display-selftest").flatMap { i in args.count > i + 1 ? Double(args[i + 1]) : nil } ?? 60
            d = try VirtualDisplay(name: "Sill", widthPt: 1000, heightPt: 700, scale: 2, refreshHz: hz,
                                   vendorID: VirtualStage.vendorID, productID: VirtualStage.productID, serialNum: VirtualStage.serialNum)
            print("  requested refresh: \(Int(hz)) Hz")
        } catch {
            print("  FAIL create: \(error)")
            return 2
        }
        let createdMs = Int(Date().timeIntervalSince(t0) * 1000)
        let online = await d.waitUntilOnline(timeout: 3)
        let onlineMs = Int(Date().timeIntervalSince(t0) * 1000)
        let px = d.pixelSize
        print("  created id \(d.displayID) in \(createdMs) ms; online at requested mode: \(online) after \(onlineMs) ms")
        print("  bounds \(d.bounds), backing \(px.width)×\(px.height) px")
        if let mode = CGDisplayCopyDisplayMode(d.displayID) { print("  current mode refresh: \(Int(mode.refreshRate)) Hz") }
        // Input reachability: the host maps device touches to global coordinates on this display
        // and posts HID mouse events there. If the window server keeps the cursor off virtual
        // displays, every click lands somewhere else. Warp, post a move, read back, restore.
        if let before = CGEvent(source: nil)?.location {
            let target = CGPoint(x: d.bounds.midX, y: d.bounds.midY)
            CGWarpMouseCursorPosition(target)
            usleep(30_000)
            let afterWarp = CGEvent(source: nil)?.location ?? .zero
            if let mv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left) {
                mv.post(tap: .cghidEventTap)
            }
            usleep(30_000)
            let afterPost = CGEvent(source: nil)?.location ?? .zero
            CGWarpMouseCursorPosition(before)
            let onIt = { (p: CGPoint) in d.bounds.contains(p) }
            print("  cursor reach: warp to \(target) → \(afterWarp) (on display: \(onIt(afterWarp))); HID move → \(afterPost) (on display: \(onIt(afterPost))); cursor restored to \(before)")
        }
        print("  CGGetOnlineDisplayList contains it: \(onlineDisplays().contains(d.displayID)); CGDisplayIsActive \(CGDisplayIsActive(d.displayID) != 0)")
        let modes = d.availableModes()
        print("  modes (\(modes.count)): \(modes.joined(separator: "; "))")

        // AppKit's view, which the stage uses for the menu-bar inset.
        let deadline = Date().addingTimeInterval(1)
        while VirtualStage.screen(for: d.displayID) == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if let s = VirtualStage.screen(for: d.displayID) {
            print("  NSScreen: frame \(s.frame), visibleFrame \(s.visibleFrame), menu bar \(Int(s.frame.maxY - s.visibleFrame.maxY)) pt, usable (CG) \(VirtualStage.usableArea(of: d.displayID) ?? .zero)")
        } else {
            print("  NSScreen: not listed after 1 s (the stage would assume a 24 pt menu bar)")
        }

        // ScreenCaptureKit's view. Needs Screen Recording; without it the call has been seen to
        // never return while a virtual display exists, hence the bound (the same one the stage uses).
        let t1 = Date()
        var listed = false
        var answered = false
        while Date().timeIntervalSince(t1) < 3, !listed {
            if let c = await WindowCatalog.shareableContent(excludingDesktopWindows: true, onScreenWindowsOnly: true, timeout: 3) {
                answered = true
                if c.displays.contains(where: { $0.displayID == d.displayID }) { listed = true; break }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if listed {
            print("  SCShareableContent lists it after \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
        } else if answered {
            print("  SCShareableContent answered but did not list it within 3 s")
        } else {
            print("  SCShareableContent did not answer within \(Int(Date().timeIntervalSince(t1) * 1000)) ms (Screen Recording preflight \(CGPreflightScreenCaptureAccess())); the stage would fall back to the real window")
        }

        let id = d.displayID
        d.destroy()
        let t2 = Date()
        while onlineDisplays().contains(id), Date().timeIntervalSince(t2) < 3 { try? await Task.sleep(for: .milliseconds(50)) }
        let gone = !onlineDisplays().contains(id)
        print("  destroyed: gone from CGGetOnlineDisplayList after \(Int(Date().timeIntervalSince(t2) * 1000)) ms: \(gone)")
        print("  displays after: \(onlineDisplays())")
        return (online || px.width > 0) && gone ? 0 : 3
    }
}
