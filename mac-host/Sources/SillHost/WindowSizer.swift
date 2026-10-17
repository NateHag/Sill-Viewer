import Foundation
import StreamProtocol
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Milestone 3's fallback scaling: instead of a virtual display per device, resize the real window
/// through Accessibility so it fits the client's panel at the text scale the client asked for.
///
/// Main actor, like the coordinator that calls it. The AX calls are synchronous IPC into the target
/// app, so each app element *and* the matched window element get a short messaging timeout (a
/// timeout set on one element covers that element only, per AXUIElement.h): a hung app costs a
/// second per call, not the host.
@MainActor
final class WindowSizer {
    /// AX refuses everything while the host is untrusted; say so once, not on every viewport.
    private var warnedUntrusted = false

    /// How far apart (in points) the SCWindow's frame and an AX window's frame may be and still be
    /// the same window. Covers rounding between the two APIs, not a window that moved.
    private static let frameTolerance: CGFloat = 4

    /// What `resize` did, for the window's way back (WindowRestore, issue #57): the window's element,
    /// matched once, with the frame it had before this resize (`placement.originalFrame`), and the
    /// frame the app took (Accessibility's, read back: an app enforces a minimum, snaps to a grid).
    struct Fit {
        let placement: Placement
        let after: CGRect
        var before: CGRect { placement.originalFrame }
    }

    /// Resizes `window` to `size` in Mac points (top-left anchored), nudging it back onto its
    /// display if the new size would hang off the edge (WindowRestore.fit, the sequence). Returns what
    /// it did (`Fit`: the size the app actually took is `after.size`; apps enforce minimums and some
    /// snap to a grid; for a size that went unanswered, the frame it had, in case it takes the size
    /// later), or nil if Accessibility is off, the window cannot be found through AX, it is in full
    /// screen (left alone: nothing written, nothing to record), or the app refused the size; a nudge
    /// made for a refused or unanswered size is put back at once.
    func resize(window: SCWindow, to size: CGSize) -> Fit? {
        guard AXIsProcessTrusted() else {
            if !warnedUntrusted {
                warnedUntrusted = true
                print("Window sizing needs Accessibility permission (the same one input needs); leaving windows at their size.")
            }
            return nil
        }
        guard let pid = window.owningApplication?.processID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let ax = Self.axWindow(matching: window, in: app) else {
            print("Window sizing: no Accessibility window matches \"\(window.title ?? "")\"; not resizing.")
            return nil
        }
        AXUIElementSetMessagingTimeout(ax, 1.0)
        // The frame before is read in the sequence: the AX frame is live; the SCWindow's (the fallback)
        // can be two seconds stale.
        let p = Placement(windowID: window.windowID, pid: pid, element: ax, originalFrame: .null,
                          appName: window.owningApplication?.applicationName ?? "?", title: window.title ?? "")
        var windows = AXWindows(sizer: self)
        switch WindowRestore.fit(p, to: size, fallback: Self.liveBounds(of: window.windowID) ?? window.frame, on: &windows) {
        case .fullScreen:
            print("Window sizing: \(windows.name(p)) is full screen; not resizing.")
            return nil
        case .refused(let code):
            print("Window sizing: AX refused the size (error \(code)).")
            return nil
        case .fitted(let before, let after, let timedOut):
            if timedOut { print("Window sizing: \(windows.name(p)) did not answer the size in time; if it takes it later, it still goes back.") }
            return Fit(placement: p.homed(at: before), after: after)
        }
    }

    /// WindowRestore's reads and writes through Accessibility (a fit, a fitted window's way back),
    /// on the element a placement holds. The window server says whether the window is still listed.
    @MainActor struct AXWindows: @MainActor WindowRestore.Access {
        let sizer: WindowSizer
        func frame(_ p: Placement) -> CGRect? { WindowSizer.frame(of: p.element) }
        func isFullScreen(_ p: Placement) -> Bool { WindowSizer.isFullScreen(p.element) }
        func isListed(_ p: Placement) -> Bool { WindowSizer.liveBounds(of: p.windowID) != nil }
        func visibleArea(around r: CGRect) -> CGRect? { WindowSizer.visibleArea(around: r) }
        func setPosition(_ p: Placement, _ origin: CGPoint) -> WindowRestore.Write { WindowSizer.write(WindowSizer.set(p.element, position: origin)) }
        func setSize(_ p: Placement, _ size: CGSize) -> WindowRestore.Write { WindowSizer.write(WindowSizer.set(p.element, size: size)) }
        func put(_ p: Placement, at frame: CGRect) -> Bool { sizer.restore(p.homed(at: frame)) }
        func name(_ p: Placement) -> String { WindowRestore.name(app: p.appName, title: p.title) }
    }

    /// An Accessibility write's answer as WindowRestore takes it: cannotComplete is what a messaging
    /// timeout returns (a busy app, which may still apply the write).
    private static func write(_ e: AXError) -> WindowRestore.Write {
        switch e {
        case .success: return .done
        case .cannotComplete: return .timedOut
        default: return .refused(e.rawValue)
        }
    }

    // MARK: Placing a window on the virtual display (--virtual-display)

    /// A window the host has taken hold of through Accessibility, with where it came from. The
    /// element is resolved once, at placement time: matching by title/frame again after the move
    /// would fail (the frame changed) and the element stays valid as long as the window exists.
    struct Placement {
        let windowID: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        /// Where the window was before the host touched it (CG global points).
        let originalFrame: CGRect
        let appName: String
        let title: String

        /// The same window with `frame` as its way home: the virtual display staging a window Sill
        /// had fitted, and a fitted window going back (WindowRestore).
        func homed(at frame: CGRect) -> Placement {
            Placement(windowID: windowID, pid: pid, element: element, originalFrame: frame, appName: appName, title: title)
        }
    }

    /// The Accessibility window of `pid` whose frame is `rect` (a stranger found on the virtual
    /// display through the window list), or nil.
    static func axWindow(pid: pid_t, frame rect: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let candidates = value as? [AXUIElement] else { return nil }
        for c in candidates { AXUIElementSetMessagingTimeout(c, 0.5) }
        return candidates.first { c in
            guard let f = frame(of: c) else { return false }
            return abs(f.minX - rect.minX) <= frameTolerance && abs(f.minY - rect.minY) <= frameTolerance
                && abs(f.width - rect.width) <= frameTolerance && abs(f.height - rect.height) <= frameTolerance
        }
    }

    /// Moves a window's top-left corner (CG global points).
    static func setPosition(_ element: AXUIElement, _ origin: CGPoint) -> AXError { set(element, position: origin) }

    /// A frame of `size` centred below the main display's menu bar: home for a window whose real
    /// home is unknown or was itself on a virtual display.
    static func homeFrame(size: CGSize) -> CGRect {
        let main = CGDisplayBounds(CGMainDisplayID())
        let menuBar: CGFloat = 33
        let w = min(size.width, main.width), h = min(size.height, main.height - menuBar)
        return CGRect(x: (main.midX - w / 2).rounded(), y: (main.minY + menuBar + (main.height - menuBar - h) / 2).rounded(), width: w, height: h)
    }

    /// Close, minimize or toggle full screen on a window, as its own traffic lights would.
    static func perform(_ action: WindowCommand.Action, element: AXUIElement) -> Bool {
        switch action {
        case .close:
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
                  let button else { return false }
            return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
        case .minimize:
            return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        case .fullScreen:
            let leaving = isFullScreen(element)
            return AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, leaving ? kCFBooleanFalse : kCFBooleanTrue) == .success
        }
    }

    /// `perform` for a window known only by its ScreenCaptureKit description.
    func perform(_ action: WindowCommand.Action, on window: SCWindow) -> Bool {
        guard AXIsProcessTrusted(), let pid = window.owningApplication?.processID else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let ax = Self.axWindow(matching: window, in: app) else { return false }
        return Self.perform(action, element: ax)
    }

    /// Whether the window is in a full-screen Space (the AXFullScreen attribute AppKit windows expose).
    static func isFullScreen(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    /// Makes an app window its app's main and key window (Accessibility), so a click into it acts
    /// instead of merely focusing it. Cheap: two attribute writes on an element already matched.
    static func makeKey(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Brings a window to the front of its app's windows (Accessibility raise; activating the app
    /// is the coordinator's job). Regular path only: when a pick brings the window forward, and
    /// when another window covers the spot the device clicked or scrolled (otherwise the event
    /// lands on the cover, and a covered window stops repainting anyway).
    static func raise(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    /// The AX element of a window known only by its ScreenCaptureKit description, for `raise` and
    /// `makeKey`. Matched once for both: each match (see `axWindow`) is synchronous IPC into the
    /// app, a second when it hangs. Nil if Accessibility is off or no window matches.
    func element(for window: SCWindow) -> AXUIElement? {
        guard AXIsProcessTrusted(), let pid = window.owningApplication?.processID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        return Self.axWindow(matching: window, in: app)
    }

    /// Resolves `window` to its AX element and records its current frame, without moving it.
    /// Nil if Accessibility is off or the window cannot be matched (see `axWindow`).
    func placement(for window: SCWindow) -> Placement? {
        guard AXIsProcessTrusted() else {
            if !warnedUntrusted {
                warnedUntrusted = true
                print("Window sizing needs Accessibility permission (the same one input needs); leaving windows at their size.")
            }
            return nil
        }
        guard let pid = window.owningApplication?.processID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let ax = Self.axWindow(matching: window, in: app) else {
            print("Window placement: no Accessibility window matches \"\(window.title ?? "")\"; not moving it.")
            return nil
        }
        // Every later move/restore (and the atexit emergency restore) goes through this element.
        AXUIElementSetMessagingTimeout(ax, 1.0)
        // The AX frame is live; the SCWindow's can be two seconds stale (the catalog's poll).
        let original = Self.frame(of: ax) ?? Self.liveBounds(of: window.windowID) ?? window.frame
        return Placement(windowID: window.windowID, pid: pid, element: ax, originalFrame: original,
                         appName: window.owningApplication?.applicationName ?? "?", title: window.title ?? "")
    }

    /// Moves and resizes the window to `frame`, wherever that is: no on-screen clamping here, the
    /// destination is off the real displays by design. Position, size, position: an app that
    /// clamps the size may shift the origin (the probe's order). Returns the first AX error.
    @discardableResult
    func move(_ p: Placement, to frame: CGRect) -> AXError {
        var first = AXError.success
        func note(_ e: AXError) { if first == .success, e != .success { first = e } }
        note(Self.set(p.element, position: frame.origin))
        note(Self.set(p.element, size: frame.size))
        note(Self.set(p.element, position: frame.origin))
        return first
    }

    /// Puts the window back where `placement(for:)` found it. True when it is back, or there is
    /// nothing left to restore (window closed, app quit). Never leaves a live window off every
    /// real display: if its original display has gone meanwhile, it is nudged onto the main one.
    @discardableResult
    func restore(_ p: Placement) -> Bool {
        var err = move(p, to: p.originalFrame)
        if err == .invalidUIElement { return true }   // gone: nothing to restore
        if err == .cannotComplete {
            // Also what a messaging timeout returns, so ask the window server whether the window
            // still exists before treating it as gone; a busy app gets one more try.
            guard Self.liveBounds(of: p.windowID) != nil else { return true }
            err = move(p, to: p.originalFrame)
        }
        if let live = Self.liveBounds(of: p.windowID), !Self.onAnyScreen(live),
           let area = Self.visibleArea(around: CGDisplayBounds(CGMainDisplayID())) {
            // The original display was unplugged while the window was away: keep it reachable.
            let origin = WindowRestore.keep(live, in: area)
            _ = Self.set(p.element, position: origin)
            print("Window placement: \(p.appName)'s original display is gone; moved it onto the main display at \(Int(origin.x)),\(Int(origin.y)).")
        }
        return err == .success
    }

    /// AXError for the log.
    nonisolated static func axErrorName(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .apiDisabled: return "apiDisabled (Accessibility not granted)"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .notImplemented: return "notImplemented"
        case .failure: return "failure"
        default: return "AXError \(e.rawValue)"
        }
    }

    /// Does `rect` touch any display NSScreen knows (CG coordinates)? The virtual display counts
    /// while it exists, which is what `restore` wants: a stale read of the window still on it is
    /// not "off every screen".
    private static func onAnyScreen(_ rect: CGRect) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return true }
        return NSScreen.screens.contains { screen in
            let f = screen.frame
            return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height).intersects(rect)
        }
    }

    // MARK: Finding the AX window

    /// There is no public way to go from a CGWindowID to its AXUIElement (`_AXUIElementGetWindow`
    /// is private), so match on what both APIs can see:
    ///
    /// 1. Title. If exactly one of the app's AX windows has the SCWindow's title, that is it — the
    ///    title is live on both sides, while the SCWindow's frame can be two seconds stale.
    /// 2. Frame. With several windows sharing the title ("Untitled", or a browser's two windows on
    ///    the same page) or none matching (an empty title, or it changed since the catalog polled),
    ///    pick the one whose origin and size are within a few points of the window's live bounds,
    ///    among the title matches if there were any, else among all of the app's windows.
    /// 3. Otherwise nil: resizing the wrong window is worse than not resizing.
    private static func axWindow(matching window: SCWindow, in app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let candidates = value as? [AXUIElement], !candidates.isEmpty else { return nil }
        // The timeout on `app` does not carry over to its windows: a busy app would otherwise hold
        // the main thread for the ~1.5 s default per candidate.
        for c in candidates { AXUIElementSetMessagingTimeout(c, 0.5) }

        let title = window.title ?? ""
        let titled = title.isEmpty ? [] : candidates.filter { string(of: $0, kAXTitleAttribute) == title }
        if titled.count == 1 { return titled[0] }

        let bounds = liveBounds(of: window.windowID) ?? window.frame
        let pool = titled.isEmpty ? candidates : titled
        return pool.first { candidate in
            guard let f = frame(of: candidate) else { return false }
            return abs(f.minX - bounds.minX) <= frameTolerance && abs(f.minY - bounds.minY) <= frameTolerance
                && abs(f.width - bounds.width) <= frameTolerance && abs(f.height - bounds.height) <= frameTolerance
        }
    }

    /// The window server's current bounds (CG global, top-left origin — the same space AX uses).
    static func liveBounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    // MARK: Staying on screen

    /// The active displays' frames (CG global points, the virtual display's while it exists), for
    /// telling a full-screen window from its listed frame (WindowRestore.coversDisplay).
    static func displayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// The visible frame (menu bar and Dock excluded) of the display holding most of `rect`, in
    /// CG global coordinates. NSScreen is bottom-left based on the primary display; flip it. Also
    /// the area a moved window's way back is kept in (StreamCoordinator.restoreFits).
    static func visibleArea(around rect: CGRect) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let areas = NSScreen.screens.map { screen -> CGRect in
            let v = screen.visibleFrame
            return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
        }
        let overlap = { (area: CGRect) -> CGFloat in
            let i = area.intersection(rect)
            return i.isNull ? 0 : i.width * i.height
        }
        return areas.max { overlap($0) < overlap($1) }
    }

    // MARK: AX attribute plumbing

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = axValue(of: element, kAXPositionAttribute),
              AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        var size = CGSize.zero
        guard let value = axValue(of: element, kAXSizeAttribute),
              AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    /// The window's AX frame (CG global points). It reads a move as soon as the app accepted it,
    /// before the window list shows it (VirtualStage's settle loop and eviction scan rely on that).
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = position(of: element), let size = size(of: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func axValue(of element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func set(_ element: AXUIElement, position: CGPoint) -> AXError {
        var point = position
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private static func set(_ element: AXUIElement, size: CGSize) -> AXError {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}
