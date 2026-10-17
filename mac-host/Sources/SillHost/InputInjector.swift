import Foundation
import QuartzCore
import CoreGraphics
import ApplicationServices
import Darwin
import StreamProtocol

/// Turns client input into CGEvents aimed at the streamed source.
///
/// The client sends positions as fractions of the video frame (0…1); everything here maps them
/// onto `rect`, the source's current screen rectangle in CG global coordinates (points, top-left
/// origin — the same space CGEvent uses), so the phone never learns anything about Mac geometry
/// and a window that moves or resizes just changes `rect`.
///
/// Threading: main actor. Input arrives on the network queue and hops here through the
/// coordinator, and posting CGEvents from the main thread is fine.
///
/// Every post of a pointer or scroll event is noted in the PointerWatch just before it happens
/// (`watch`), so the pointer moving under it reads as Sill's own motion, not the Mac's. A synthetic
/// host posts nothing (`dryRun`).
@MainActor
final class InputInjector {
    /// Two downs of the same button within this time and distance are a double (then triple) click.
    private static let multiClickInterval: CFTimeInterval = 0.35
    private static let multiClickSlop: CGFloat = 12

    private struct ButtonState {
        var isDown = false
        var clicks: Int64 = 1
        var lastDownAt: CFAbsoluteTime = -1_000
        var lastDownPoint: CGPoint = .zero
    }

    /// `.hidSystemState` merges with the real HID state, so a modifier physically held on the Mac
    /// still applies to an injected click. Keyboard events below set their flags explicitly anyway.
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastMoveArrival: CFTimeInterval = 0   // jitter probe, see apply()
    private var left = ButtonState()
    private var right = ButtonState()

    /// The Mac's pointer (docs/pointer-visibility-plan.md §4.5): told just before each post of a
    /// pointer or scroll event, never after. The network queue reads the pointer while this posts,
    /// so a read could fall between the post taking effect and a note made after it, and take
    /// Sill's own move for the Mac's; that matters most for a held click, posted a second or more
    /// after it was read, when the arrival's settle is long over. Keys and text note nothing: they
    /// do not move the pointer.
    var watch: PointerWatch?
    /// A synthetic host (the plan's Q10): every event that would be posted is counted (`in.dry`,
    /// one per post: a pointer or scroll event one, a typed character or a Return two) and none
    /// reaches the Mac, since the test pattern is not the screen; the per-type counters stay at
    /// zero and no Accessibility reminder prints. With the TEST ONLY scripted pointer a pointer
    /// event moves that pointer to its position instead (PointerWatch.sillMoved(to:)).
    var dryRun = false
    /// TEST ONLY (SILL_TEST_INPUT_LOG=1, a synthetic host, which posts nothing: `testInputLog`): each
    /// event a dry run would post is printed, a keyboard event with the flags it was made with ("Test
    /// input: key 49 up (none)"), a pointer or scroll event with those the last keyboard event would
    /// have left in the HID state table, which it would start from ("Test input: left mouse down
    /// (none) at 756,474", a button's with where it goes): what a device's keys leave for its next
    /// click, without posting anything; and the check a key's up arms (`KeyUpCheck`).
    var testLog = false
    /// The flags of the last keyboard event posted (a dry run's: that would have been), which the HID
    /// state table holds by KeyStrokes' inference: the check after a key's up reads the table against
    /// it, and the TEST ONLY log gives it to each pointer event.
    private var lastKeyFlags: UInt64 = 0
    /// Where the last pointer event went: a synthetic host's pointer, which it never reads.
    private var lastPointerLocation: CGPoint = .zero

    // MARK: Entry point

    /// One device's input. `device` is its connection, whose keys KeyStrokes keeps down until they
    /// come up or it leaves (`releaseKeys`). `rect` is the streamed source's rectangle, or `.null` for
    /// input with nowhere to land that still goes (`isUpOfSomethingDown`: StreamCoordinator), a
    /// button's up then going where the pointer is.
    func apply(_ event: InputEvent, in rect: CGRect, from device: KeyStrokes.Device) {
        if !dryRun { remindAboutAccessibilityIfNeeded() }
        switch event {
        case .pointer(let action, let x, let y):
            // Jitter probe: how evenly do pointer moves arrive? A Pencil or trackpad drag should
            // land every 8–16 ms; buckets above that are the stutter the device user feels.
            if action == .move {
                let now = CACurrentMediaTime()
                let gap = now - lastMoveArrival
                lastMoveArrival = now
                if gap < 1.0 {
                    if gap > 0.100 { Stats.shared.bump("in.gap>100ms") }
                    else if gap > 0.050 { Stats.shared.bump("in.gap>50ms") }
                    else if gap > 0.025 { Stats.shared.bump("in.gap>25ms") }
                }
            }
            pointer(action, at: point(x, y, in: rect))
        case .scroll(let x, let y, let dx, let dy):
            scroll(at: point(x, y, in: rect), dx: dx * rect.width, dy: dy * rect.height)
        case .text(let string):
            type(string, from: device)
        case .scrollGesture(let phase, let x, let y):
            scrollGesture(phase, at: point(x, y, in: rect))
        case .key(let hidUsage, let down, let modifiers):
            key(hidUsage: hidUsage, down: down, modifiers: modifiers, from: device)
        }
    }

    /// Where a device's position lands on the Mac: its fraction of `rect`; with no source to place it
    /// on (`.null`), where the pointer is now.
    private func point(_ x: Double, _ y: Double, in rect: CGRect) -> CGPoint {
        if rect.isNull { return pointerNow() }
        return CGPoint(x: rect.minX + CGFloat(x) * rect.width, y: rect.minY + CGFloat(y) * rect.height)
    }

    /// Where the Mac's pointer is: read (no permission) on a host that posts; on a synthetic host,
    /// which never reads the real pointer, where its last pointer event went.
    private func pointerNow() -> CGPoint {
        if !dryRun, let location = CGEvent(source: nil)?.location { return location }
        return lastPointerLocation
    }

    /// The one place an event reaches the Mac: posted, or in a dry run only counted. True when it
    /// was posted.
    private func post(_ event: CGEvent) -> Bool {
        if Self.isKeyboard(event.type) { lastKeyFlags = event.flags.rawValue & (KeyStrokes.capsLock | Self.modifierBits) }
        if dryRun {
            if testLog { logTest(event) }
            Stats.shared.bump("in.dry")
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func isKeyboard(_ type: CGEventType) -> Bool { type == .keyDown || type == .keyUp || type == .flagsChanged }

    /// TEST ONLY: one line for an event a dry run would have posted (`testLog`).
    private func logTest(_ event: CGEvent) {
        let what: String
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            what = "key \(key) " + (event.type == .keyDown ? "down" : event.type == .keyUp ? "up" : "flags changed")
            print("Test input: \(what) (\(KeyStrokes.names(lastKeyFlags)))")
            return
        case .mouseMoved: what = "pointer move"
        case .leftMouseDown: what = "left mouse down"
        case .leftMouseUp: what = "left mouse up"
        case .leftMouseDragged: what = "left mouse drag"
        case .rightMouseDown: what = "right mouse down"
        case .rightMouseUp: what = "right mouse up"
        case .rightMouseDragged: what = "right mouse drag"
        case .scrollWheel: what = "scroll"
        default: what = "event \(event.type.rawValue)"
        }
        // A button's event says where it goes: a button's up with no source goes where the pointer is.
        let button = event.type != .mouseMoved && event.type != .scrollWheel
        let at = button ? " at \(Int(event.location.x.rounded())),\(Int(event.location.y.rounded()))" : ""
        print("Test input: \(what) (\(KeyStrokes.names(lastKeyFlags)))\(at)")
    }

    /// TEST ONLY: SILL_TEST_INPUT_LOG, read once at the coordinator's start. "1" on a synthetic host
    /// (which posts nothing) turns the log on; anything else, or any other host, is ignored with one
    /// line. Nothing prints without the variable.
    static func testInputLog(synthetic: Bool, environment env: [String: String]) -> (on: Bool, line: String?) {
        guard let value = env["SILL_TEST_INPUT_LOG"], !value.isEmpty else { return (false, nil) }
        guard synthetic else { return (false, "SILL_TEST_INPUT_LOG ignored: only a --synthetic host takes it.") }
        guard value == "1" else { return (false, "SILL_TEST_INPUT_LOG=\(value) ignored: 1 turns it on.") }
        return (true, "Test input log: each event this host would post is printed; a --synthetic host posts none.")
    }

    // MARK: Pointer

    private func pointer(_ action: PointerAction, at location: CGPoint) {
        let type: CGEventType
        let button: CGMouseButton
        var clicks: Int64 = 1

        switch action {
        case .move:
            // A move with a button held is a drag; sending .mouseMoved instead would break
            // text selection and window dragging.
            if left.isDown { type = .leftMouseDragged; button = .left; clicks = left.clicks }
            else if right.isDown { type = .rightMouseDragged; button = .right; clicks = right.clicks }
            else { type = .mouseMoved; button = .left }
        case .leftDown:
            beginClick(&left, at: location)
            type = .leftMouseDown; button = .left; clicks = left.clicks
        case .leftUp:
            left.isDown = false
            type = .leftMouseUp; button = .left; clicks = left.clicks   // the up carries the down's count
        case .rightDown:
            beginClick(&right, at: location)
            type = .rightMouseDown; button = .right; clicks = right.clicks
        case .rightUp:
            right.isDown = false
            type = .rightMouseUp; button = .right; clicks = right.clicks
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: button) else { return }
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: clicks) }
        // One synthetic "finger": a constant event number keeps a down/drag/up sequence coherent.
        event.setIntegerValueField(.mouseEventNumber, value: 0)
        watch?.sillMoved(to: location)   // before the post (see `watch`); a dry run moves the scripted pointer
        lastPointerLocation = location
        if post(event) { Stats.shared.bump("in.pointer") }
    }

    /// Whether this input is the up of a key or a button the Mac has down, which still goes when the
    /// input has nowhere to land (DroppedInput, StreamCoordinator): its down was posted, its up has
    /// not been.
    func isUpOfSomethingDown(_ event: InputEvent) -> Bool {
        DroppedInput.stillGoes(event, keyDown: keys.isDown, leftDown: left.isDown, rightDown: right.isDown)
    }

    private func beginClick(_ state: inout ButtonState, at location: CGPoint) {
        let now = CFAbsoluteTimeGetCurrent()
        let moved = hypot(location.x - state.lastDownPoint.x, location.y - state.lastDownPoint.y)
        if now - state.lastDownAt <= Self.multiClickInterval && moved <= Self.multiClickSlop {
            state.clicks += 1            // 2 = double-click, 3 = triple, and on up from there
        } else {
            state.clicks = 1
        }
        state.isDown = true
        state.lastDownAt = now
        state.lastDownPoint = location
    }

    // MARK: Scroll

    /// `dx`/`dy` are already in points of the source rectangle, with the protocol's natural sign:
    /// positive dy means the content should move down the screen.
    ///
    /// That matches kCGScrollWheelEventDeltaAxis1 as-is: a positive axis-1 delta is "scroll up",
    /// i.e. the viewport moves toward the top of the document and the content slides down — the
    /// same result as a natural-scrolling trackpad swipe downwards. Axis 2 works the same way
    /// (positive scrolls left, so the content slides right), so neither value is negated. The
    /// system's natural-scrolling preference flips the hardware driver's deltas, not ours, so a
    /// synthetic event means the same thing whichever way the Mac is set.
    ///
    /// Inside a gesture the delta is stamped with the phase the Mac expects from a trackpad (see
    /// `ScrollState`); outside one it goes out exactly as before, a bare pixel wheel event.
    private func scroll(at location: CGPoint, dx: Double, dy: Double) {
        // The wheel fields are whole points. Carry the rounding remainder into the next event, or
        // a slow drag (and the end of every momentum tail) made of sub-point steps scrolls nothing.
        // Int(Double) traps on NaN, infinity and anything past Int's range, so a malformed delta
        // from the wire is dropped and a huge one clamped before converting.
        guard dx.isFinite, dy.isFinite else { return }
        let limit = Double(Int32.max)
        let exact = CGPoint(x: dx + scrollRemainder.x, y: dy + scrollRemainder.y)
        let wheel1 = min(max(exact.y.rounded(), -limit), limit)
        let wheel2 = min(max(exact.x.rounded(), -limit), limit)
        scrollRemainder = CGPoint(x: exact.x - wheel2, y: exact.y - wheel1)
        if abs(scrollRemainder.x) >= 1 || abs(scrollRemainder.y) >= 1 { scrollRemainder = .zero }  // after a clamp
        let w1 = Int32(wheel1), w2 = Int32(wheel2)

        switch scrollState {
        case .idle:
            postScroll(at: location, wheel1: w1, wheel2: w2, phase: nil, momentum: nil)
        case .gesture(let begun):
            postScroll(at: location, wheel1: w1, wheel2: w2,
                       phase: begun ? .changed : .began, momentum: nil)
            scrollState = .gesture(begun: true)
        case .momentum(let begun):
            postScroll(at: location, wheel1: w1, wheel2: w2,
                       phase: nil, momentum: begun ? .continuous : .begin)
            scrollState = .momentum(begun: true)
        }
        lastScrollLocation = location
        rearmScrollWatchdog()
        if !dryRun { Stats.shared.bump("in.scroll") }
    }

    /// Where the scroll gesture in progress is. One at a time: the client has one scroll surface
    /// in use, and its gestures never overlap (it ends momentum before beginning a new gesture).
    ///
    /// A Mac trackpad scroll is not a stream of wheel ticks but a phased gesture, and AppKit keys
    /// its behaviour off the phases: it rubber-bands past an edge only while a gesture is under
    /// way, springs back on Ended unless momentum follows, and treats momentum events as the
    /// coast after lift-off. The client brackets its deltas with `.scrollGesture` messages; this
    /// turns them into the phase fields:
    ///
    ///   began          → nothing yet; the first delta goes out as kCGScrollPhaseBegan (1)
    ///   deltas         → kCGScrollPhaseChanged (2)
    ///   ended          → one zero-delta event, kCGScrollPhaseEnded (4)
    ///   momentumBegan  → nothing yet; the first delta is kCGMomentumScrollPhaseBegin (1)
    ///   deltas         → kCGMomentumScrollPhaseContinue (2), scroll phase 0
    ///   momentumEnded  → one zero-delta event, kCGMomentumScrollPhaseEnd (3)
    ///
    /// A boundary with no delta inside it (a gesture that never moved) posts nothing, so the Mac
    /// never sees an Ended without its Began.
    private enum ScrollState {
        case idle                     // bare wheel deltas: an older client, or a lone tick
        case gesture(begun: Bool)     // fingers down; begun once the Began event is out
        case momentum(begun: Bool)    // fingers up, client-generated coast
    }

    private var scrollState = ScrollState.idle
    private var scrollRemainder = CGPoint.zero
    /// Where the last scroll event went, for the closing event the watchdog posts.
    private var lastScrollLocation = CGPoint.zero
    private var scrollWatchdog: Task<Void, Never>?

    /// A gesture or coast whose closing message never comes (the client dropped off mid-scroll)
    /// would leave the Mac's content stretched past its edge indefinitely. If a gesture goes this
    /// long with no traffic it is closed here. Fingers resting mid-scroll send nothing, so the
    /// gesture limit is generous; momentum ticks at 60 Hz, so a half-second gap means it died.
    private static let gestureIdleTimeout: Double = 2
    private static let momentumIdleTimeout: Double = 0.5

    private func scrollGesture(_ phase: ScrollPhase, at location: CGPoint) {
        Stats.shared.bump("in.scrollPhase")
        switch phase {
        case .began:
            closeScroll(at: location)   // defensive: anything still open ends first
            scrollState = .gesture(begun: false)
            scrollRemainder = .zero
        case .ended:
            if case .gesture(begun: true) = scrollState {
                postScroll(at: location, wheel1: 0, wheel2: 0, phase: .ended, momentum: nil)
            }
            scrollState = .idle
        case .momentumBegan:
            closeScroll(at: location)
            scrollState = .momentum(begun: false)
        case .momentumEnded:
            if case .momentum(begun: true) = scrollState {
                postScroll(at: location, wheel1: 0, wheel2: 0, phase: nil, momentum: .end)
            }
            scrollState = .idle
        }
        lastScrollLocation = location
        rearmScrollWatchdog()
    }

    /// Posts the closing event for whatever phase is open, then goes idle.
    private func closeScroll(at location: CGPoint) {
        switch scrollState {
        case .gesture(begun: true):
            postScroll(at: location, wheel1: 0, wheel2: 0, phase: .ended, momentum: nil)
        case .momentum(begun: true):
            postScroll(at: location, wheel1: 0, wheel2: 0, phase: nil, momentum: .end)
        default:
            break
        }
        scrollState = .idle
    }

    private func rearmScrollWatchdog() {
        scrollWatchdog?.cancel()
        let timeout: Double
        switch scrollState {
        case .idle: scrollWatchdog = nil; return
        case .gesture: timeout = Self.gestureIdleTimeout
        case .momentum: timeout = Self.momentumIdleTimeout
        }
        // Main actor, inherited from this method: the state it touches is never shared.
        scrollWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.scrollWentQuiet()
        }
    }

    /// Closes the open phase on the Mac but keeps the gesture's shape, un-begun: if the client
    /// was only resting and deltas resume, they start a fresh Began (or momentum Begin) rather
    /// than continuing a phase the Mac has already seen end.
    private func scrollWentQuiet() {
        let state = scrollState
        closeScroll(at: lastScrollLocation)
        switch state {
        case .gesture: scrollState = .gesture(begun: false)
        case .momentum: scrollState = .momentum(begun: false)
        case .idle: break
        }
        Stats.shared.bump("in.scrollTimeout")
    }

    /// One scroll-wheel CGEvent. With neither phase set it is the plain pixel wheel event this
    /// injector always sent; with either, the trackpad fields go on top.
    ///
    /// What the pixel-unit constructor already fills in (checked by reading the fields back):
    /// IsContinuous = 1, PointDeltaAxis1/2 = wheel1/2, DeltaAxis1/2 = a line count, and
    /// FixedPtDeltaAxis1/2 = the same motion in *lines* (pixels / 10, 16.16 fixed point — 7 px
    /// reads back as 0.7). So:
    ///   • IsContinuous and PointDelta are set explicitly anyway: they are what makes this a
    ///     precise trackpad scroll to AppKit (`hasPreciseScrollingDeltas`, `scrollingDeltaY`), and
    ///     the gesture must not depend on a constructor default.
    ///   • FixedPtDelta is deliberately left as the constructor made it. It backs NSEvent's legacy
    ///     line-based `deltaY`; writing the point deltas there would inflate that tenfold for
    ///     every app still reading it. (`setDoubleValueField` would do the 16.16 conversion if it
    ///     ever needs setting — CGEventField exposes all of these in Swift, nothing is missing.)
    private func postScroll(at location: CGPoint, wheel1: Int32, wheel2: Int32,
                            phase: CGScrollPhase?, momentum: CGMomentumScrollPhase?) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: wheel1, wheel2: wheel2, wheel3: 0) else { return }
        // A scroll event carries its own location; without it the scroll lands wherever the
        // cursor happens to be rather than under the client's finger. Every event, the closing
        // zero-delta ones included, so the whole gesture is routed to the same window.
        event.location = location
        if phase != nil || momentum != nil {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(wheel1))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(wheel2))
            // Exactly one of the two is non-zero: momentum events carry scroll phase 0.
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum?.rawValue ?? 0))
        }
        // Whether a scroll event posted with a location moves the cursor is not known: the note
        // comes first either way (see `watch`).
        watch?.sillMoved()
        _ = post(event)
    }

    // MARK: Text

    private func type(_ string: String, from device: KeyStrokes.Device) {
        // A device types text with none of its modifier keys down: any it still holds goes up first
        // (KeyStrokes.text), as the characters carry no flags either.
        post(keys.text(from: device))
        for character in string {
            switch character {
            case "\n": tap(virtualKey: 36)          // Return
            case "\t": tap(virtualKey: 48)          // Tab
            case "\u{8}": tap(virtualKey: 51)       // Delete (backspace)
            default:
                // Virtual key 0 with a Unicode string: the character arrives whatever the Mac's
                // keyboard layout is, which is what a software keyboard on the phone means.
                let units = Array(character.utf16)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                // No modifiers, explicitly: the character carries its own case, and an event made
                // from this source after a ⌘Space (the Spotlight key) could otherwise inherit ⌘,
                // which Spotlight's field ignores (typing into Spotlight did nothing, 2026-09-23).
                down.flags = []
                up.flags = []
                _ = post(down)
                _ = post(up)
            }
            if !dryRun { Stats.shared.bump("in.text") }
        }
    }

    private func tap(virtualKey: CGKeyCode) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { continue }
            event.flags = []       // plain Return, Tab, Delete: never a leftover modifier
            _ = post(event)
        }
    }

    // MARK: Keys

    /// Which Mac key each device key is, the flags each event carries, and the keys down (KeyStrokes,
    /// pure): a key's up leaves only what modifier keys still hold, so no chord leaves its modifiers
    /// in the HID state table that the next click and scroll start from.
    private var keys = KeyStrokes()

    private func key(hidUsage: UInt16, down: Bool, modifiers: UInt64, from device: KeyStrokes.Device) {
        guard let strokes = keys.key(usage: hidUsage, down: down, modifiers: modifiers, from: device) else {
            Stats.shared.bump("in.unknownKey")
            return
        }
        post(strokes)
    }

    /// Posts KeyStrokes' events in order, each made from `source` with exactly its flags (a modifier's
    /// own keycode makes a flags-changed event), and has each up checked a quarter of a second later
    /// (KeyUpCheck: the table read just before each down, a read that needs no permission).
    private func post(_ strokes: [KeyStroke], letGo: Bool = false) {
        for stroke in strokes {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.virtualKey, keyDown: stroke.down) else { continue }
            event.flags = CGEventFlags(rawValue: stroke.flags)
            // A dry run reads no table: what it would hold is the last event's flags, none of them the Mac's own.
            let table = stroke.down && !dryRun ? CGEventSource.flagsState(.hidSystemState).rawValue : lastKeyFlags
            let check = upCheck.posting(stroke, table: table, posted: lastKeyFlags)
            if post(event) { Stats.shared.bump(letGo ? "in.keyLetGo" : "in.key") }
            guard let check else { continue }
            if !dryRun { checkKeyModifiersLeft(check.id, key: stroke.virtualKey); continue }
            // A dry run's table is its own: the check reads it at once, and it holds nothing it should not.
            _ = upCheck.read(check.id, table: lastKeyFlags, posted: lastKeyFlags, held: keys.heldFlags)
            if testLog { print("Test input: key \(stroke.virtualKey) up: the table read again in 0.25 s for \(KeyStrokes.names(check.cleared))") }
        }
    }

    /// A device left: every key it still holds down goes up (KeyStrokes.release), so a key or a
    /// modifier whose up it never sent (its connection ended in between) does not stay down on the
    /// Mac and make the next click a ⌘-click. Counted, `in.keyLetGo`, when posted.
    func releaseKeys(of device: KeyStrokes.Device) {
        post(keys.release(device), letGo: true)
    }

    /// The host is going: every key any device holds down goes up (KeyStrokes.releaseAll), then a
    /// button still down, where the pointer is, so nothing a device pressed outlives Sill on the Mac.
    func releaseAll() {
        post(keys.releaseAll(), letGo: true)
        if left.isDown { pointer(.leftUp, at: pointerNow()) }
        if right.isDown { pointer(.rightUp, at: pointerNow()) }
    }

    /// Shift, control, option and command: the modifiers that change a click or a scroll.
    private static let modifierBits = KeyStrokes.shift | KeyStrokes.control | KeyStrokes.option | KeyStrokes.command
    /// Each key down on the Mac with the modifiers its down put in the table: what its up should take
    /// out, for `checkKeyModifiersLeft`.
    private var upCheck = KeyUpCheck()
    /// Said once a run: a key's up left modifiers set.
    private var saidKeyModifiersLeft = false

    /// A quarter of a second after a key's up that should have taken modifiers out of the HID state
    /// table (check `id`, KeyUpCheck.posting), the table is read again (a read, no permission): what
    /// it still holds of them, that no key down on the Mac holds and no key posted since carried
    /// (KeyUpCheck.read), is counted, `in.keyModifiersLeft`, and said the first time with the key. A
    /// key's up is meant to put the table back (KeyStrokes, inferred); a device test shows at once if
    /// it does not. As the gestures' chords do (docs/trackpad-gestures-plan.md §7.3, their
    /// `checkModifiersLeft`).
    private func checkKeyModifiersLeft(_ id: Int, key: UInt16) {
        // Main actor, inherited from this method, as the scroll watchdog's.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            let still = self.upCheck.read(id, table: CGEventSource.flagsState(.hidSystemState).rawValue,
                                          posted: self.lastKeyFlags, held: self.keys.heldFlags)
            guard still != 0 else { return }
            Stats.shared.bump("in.keyModifiersLeft")
            guard !self.saidKeyModifiersLeft else { return }
            self.saidKeyModifiersLeft = true
            print("Keys: a quarter of a second after a device's key \(key) came up, this Mac's modifier keys still read "
                  + "\(KeyStrokes.names(still)) (not before it went down); a click or a scroll may act as if they were held "
                  + "until a key is typed.")
        }
    }

    // MARK: Gestures

    /// A trackpad gesture's shortcut (kind 28, docs/trackpad-gestures-plan.md §7.3): the key down
    /// with exactly the flags the Mac stored for it (GestureChords), fn included, which the key path
    /// above cannot carry, and the key up. Keycodes 160 and 131 are the Mission Control and
    /// Launchpad keys of Apple keyboards, which no HID usage from a device names. Accessibility, as
    /// all input. The coordinator calls it only on a host that advertises; a dry run posts nothing
    /// here either.
    ///
    /// The key up carries the flags the HID system's state table held before the chord, not the
    /// chord's (KeyStrokes.chord): what the devices' modifier keys hold, and the Mac's own keyboard.
    /// Events posted from `source` leave their flags in that table (CGEventSource.h: its
    /// "accumulated information on modifier flag state … placed in effect by posting events"), and
    /// every pointer and scroll event made from `source` afterwards starts from them: a key up with
    /// control and fn would make the device's next tap a control-click (a context menu) and its next
    /// scroll a control-scroll (the screen zooms where Accessibility's zoom uses control), as the
    /// Spotlight key's ⌘ once reached the text typed after it (`type`). The shortcut acts on the key
    /// down. `checkModifiersLeft` says so in the log if the table still holds the chord's modifiers.
    func chord(keyCode: UInt16, flags: UInt64) {
        if !dryRun { remindAboutAccessibilityIfNeeded() }
        let before = CGEventSource.flagsState(.hidSystemState).rawValue
        let strokes = KeyStrokes.chord(virtualKey: keyCode, flags: flags, before: before)
        // Both made before either is posted, so a key never goes down without its up.
        let events = strokes.compactMap { CGEvent(keyboardEventSource: source, virtualKey: $0.virtualKey, keyDown: $0.down) }
        guard events.count == strokes.count else { return }
        for (event, stroke) in zip(events, strokes) { event.flags = CGEventFlags(rawValue: stroke.flags) }
        let posted = post(events[0])
        _ = post(events[1])
        guard posted else { return }
        Stats.shared.bump("in.gesture")
        checkModifiersLeft(chord: flags, before: before)
    }

    /// Said once a run: a chord left modifiers set that were not set before it.
    private var saidModifiersLeft = false

    /// A quarter of a second after a posted chord, the HID state table is read again (a read, which
    /// needs no permission): a modifier the chord carried (shift, control, option, command or fn)
    /// that is set now and was not before is counted, `in.gestureModifiersLeft`, and said the first
    /// time. A device test (docs/trackpad-gestures-plan.md §9.5, P2) then shows at once whether the
    /// key up put the table back.
    private func checkModifiersLeft(chord: UInt64, before: UInt64) {
        let carried = chord & GestureChords.modifierBits & ~before
        guard carried != 0 else { return }
        // Main actor, inherited from this method, as the scroll watchdog's.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            let left = CGEventSource.flagsState(.hidSystemState).rawValue & carried
            guard left != 0 else { return }
            Stats.shared.bump("in.gestureModifiersLeft")
            guard !self.saidModifiersLeft else { return }
            self.saidModifiersLeft = true
            print("Gestures: after a gesture's shortcut this Mac's modifier keys still read \(GestureChords.modifierNames(left)) "
                  + "(not before it); a click or a scroll may act as if they were held until a key is typed.")
        }
    }

    // MARK: Accessibility permission

    private static var lastReminder: CFAbsoluteTime = 0

    /// Without Accessibility trust the window server drops every event we post, silently: no
    /// error, no callback, just a cursor that never moves. Ask once at startup, and say plainly
    /// which app has to be ticked (the permission belongs to whatever launched this process).
    static func ensureAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { return }
        print("""
        Input needs Accessibility permission, and it is not granted yet: CGEvents will be \
        dropped silently until it is.
        System Settings › Privacy & Security › Accessibility, then enable \(launchingAppName()) \
        (the app this host was launched from — Terminal, iTerm, or the Claude app's terminal — \
        not SillHost itself). Restart the host afterwards.
        """)
    }

    /// One line every 30 s while input is arriving and still going nowhere, so the phone tapping
    /// at a dead Mac is visible in the host's log instead of looking like a network problem.
    private func remindAboutAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - Self.lastReminder > 30 else { return }
        Self.lastReminder = now
        print("Input is arriving but Accessibility is still off: enable \(Self.launchingAppName()) "
              + "in System Settings › Privacy & Security › Accessibility.")
    }

    /// The parent process, which is the app the permission actually attaches to. Launched by
    /// LaunchServices (Finder, `open`, a login item) the parent is launchd and the permission
    /// belongs to the app bundle itself: name it ("Sill") rather than "launchd".
    private static func launchingAppName() -> String {
        if getppid() == 1, let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return "\"\(name)\""
        }
        let fallback = "the app that launched this host"
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, ProcessInfo.processInfo.processIdentifier]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return fallback }
        let parent = info.kp_eproc.e_ppid
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(parent, &buffer, UInt32(buffer.count)) > 0 else { return fallback }
        let name = String(cString: buffer)
        return name.isEmpty ? fallback : "\"\(name)\""
    }
}
