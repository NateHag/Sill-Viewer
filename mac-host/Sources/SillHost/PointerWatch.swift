import CoreGraphics
import Foundation
import StreamProtocol

/// The Mac's pointer as the host samples it (docs/pointer-visibility-plan.md §4.2): PointerControl
/// (who moves it) under one lock, the streamed source's rectangle it is judged against, and on a
/// synthetic host the TEST ONLY scripted pointer that stands in for the real one.
///
/// Threads. `sample` runs on the network queue (StreamServer's `sill.net`), at each link tick and,
/// while the pointer moves over the source and a device is sent it, at the stream's frame rate
/// (`samplerInterval`); `inputArrived` and `clientLeft` run there too. `setGeometry` and
/// `sillMoved` come from the main actor (the coordinator, InputInjector, VirtualStage). Every
/// method holds the lock briefly and waits for nothing but the pointer's own
/// location (`CGEvent(source: nil)`, about a microsecond, no permission): a regular-mode window's
/// bounds are re-read on `sill.pointer`, a utility queue of its own, never on the network queue,
/// where a window-server round trip would sit in front of frames and pongs, and a sample uses the
/// newest bounds it has.
///
/// A synthetic host never reads the real pointer: the test pattern is not the screen. It has a
/// pointer only with SILL_TEST_POINTER_PATH (`TestPointerPath`), which the coordinator gives a
/// geometry only for the test pattern.
///
/// Pure but for the two readers and the clock it is given (the defaults read the window server
/// and the monotonic clock), so it is checked on its own with swiftc (Tests/checks/pointer-watch).
final class PointerWatch: @unchecked Sendable {   // every stored var is under `lock`
    /// What the pointer is judged against, in the injector's space: global points, top-left origin.
    enum Geometry: Equatable {
        /// A rectangle that holds while the source streams: the Desktop's display, a window staged
        /// on the virtual display (its crop, or its full-screen band), the test pattern.
        case rect(CGRect)
        /// A window in regular mode, where the pointer really moves over it: its bounds as the
        /// coordinator last read them, re-read here (`rereadAfterMove`, `rereadAnyway`); inside
        /// also needs it on screen (not minimized, not on another Space).
        case window(CGWindowID, CGRect)
    }

    /// A window's bounds and whether it is on screen, as the window server lists it.
    struct WindowState: Equatable {
        var bounds: CGRect
        var onScreen: Bool
    }

    /// One sample: where the pointer is in the source, who moves it, and whether it moves.
    struct Reading: Equatable {
        /// The fractions kind 26 carries (PointerControl.fraction: 4 decimal places).
        let x: Double
        let y: Double
        /// Over the source: inside its rectangle, and for a regular-mode window that window on screen.
        let inside: Bool
        let controller: PointerControl.Controller
        /// The pointer is moving, whoever moves it (PointerControl.isMoving): the host then samples
        /// at the stream's frame rate while it is over the source and a device is sent it
        /// (`samplerInterval`).
        let moving: Bool

        /// The kind 26 for the device `client`, whose input messages the host has read `seen` of:
        /// nil while it drives the pointer (it is sent nothing then); x and y only while inside.
        func report(for client: ObjectIdentifier, seen: Int) -> MacPointer? {
            guard controller != .client(client) else { return nil }
            return inside ? MacPointer(x: x, y: y, inside: true, seen: seen) : MacPointer(inside: false, seen: seen)
        }
    }

    /// A regular-mode window's bounds are re-read at most this often after a sample whose read
    /// moved, while some device is sent the pointer (the pointer's next move follows a window that
    /// moved under a still pointer)…
    let rereadAfterMove: Double
    /// …and at least this often whatever the pointer does, as the catalog polls (a window moved
    /// while the pointer stays still: up to this late).
    let rereadAnyway: Double

    private let synthetic: Bool
    private let path: TestPointerPath?
    private let readLocation: () -> CGPoint?
    private let readWindow: (CGWindowID) -> WindowState?
    private let clock: () -> Double
    private let rereadQueue = DispatchQueue(label: "sill.pointer", qos: .utility)

    private let lock = NSLock()
    // Under `lock`:
    private var control = PointerControl()
    private var geometry: Geometry?
    private var fps = 60
    /// The last location read (the real pointer's or the scripted one's), to tell a read that moved.
    private var lastRead: CGPoint?
    /// A regular-mode window's newest known state, and its re-read: running, when the last one
    /// started, and whether another is owed (the geometry changed while one ran).
    private var window: (id: CGWindowID, state: WindowState)?
    private var rereading = false
    private var rereadStartedAt = -Double.infinity
    private var rereadOwed = false
    /// The scripted pointer (a synthetic host with SILL_TEST_POINTER_PATH): the path's clock, from
    /// the first sample; the next step; where it is, and since when (the newer of a step and a dry
    /// run's move wins).
    private var pathStart: Double?
    private var nextStep = 0
    private var testPoint: CGPoint?
    private var testPointAt = -Double.infinity

    /// `synthetic`: never read the real pointer; `path`: the scripted one (a synthetic host only).
    init(synthetic: Bool, path: TestPointerPath? = nil,
         readLocation: @escaping () -> CGPoint? = PointerWatch.pointerLocation,
         readWindow: @escaping (CGWindowID) -> WindowState? = PointerWatch.windowState(of:),
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         rereadAfterMove: Double = 0.1, rereadAnyway: Double = 2) {
        self.synthetic = synthetic
        self.path = synthetic ? path : nil
        self.readLocation = readLocation
        self.readWindow = readWindow
        self.clock = clock
        self.rereadAfterMove = rereadAfterMove
        self.rereadAnyway = rereadAnyway
    }

    /// A synthetic host with the scripted pointer: the test pattern has a geometry, and the
    /// coordinator maps a test client's input into the same space.
    var hasTestPointer: Bool { path != nil }

    // MARK: From the coordinator and the injector (main)

    /// What the streamed source is, and its frame rate (the frame-rate sampler's). Nil: nothing to
    /// point into (nothing streams, or a synthetic host without the scripted pointer), and no read.
    /// A regular-mode window's state is re-read at once (off this thread).
    func setGeometry(_ g: Geometry?, fps: Int) {
        lock.lock()
        geometry = g
        self.fps = max(1, fps)
        var reread: CGWindowID?
        if case .window(let id, let rect)? = g {
            if let w = window, w.id == id {
                window = (id, WindowState(bounds: rect, onScreen: w.state.onScreen))
            } else {
                window = (id, WindowState(bounds: rect, onScreen: true))
            }
            reread = startRereadLocked(id)
        } else {
            window = nil
        }
        lock.unlock()
        if let reread { dispatchReread(reread) }
    }

    /// Sill is about to move the pointer: InputInjector just before it posts a pointer or scroll
    /// event, VirtualStage just before it warps the cursor home. The controller stays (PointerControl
    /// .sillMoved). On a synthetic host with the scripted pointer a pointer event's dry run moves
    /// that pointer to `p` instead of posting.
    func sillMoved(to p: CGPoint? = nil) {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        control.sillMoved(now: now)
        if let p, path != nil {
            testPoint = p
            testPointAt = now
        }
    }

    // MARK: From the network queue

    /// A kind 8 read from `client`, in the receive loop, in the same queue turn as its count.
    func inputArrived(from client: ObjectIdentifier, movesPointer: Bool) {
        lock.lock(); defer { lock.unlock() }
        control.inputArrived(from: client, movesPointer: movesPointer, now: clock())
    }

    /// A device left; if it was driving, the Mac has the pointer again.
    func clientLeft(_ client: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        control.clientLeft(client)
    }

    /// The stream's frame interval: how often the frame-rate sampler samples.
    var frameInterval: Double {
        lock.lock(); defer { lock.unlock() }
        return 1 / Double(fps)
    }

    /// How often the host samples the pointer after a sample that read this (StreamServer, the
    /// plan's Q4): every frame interval of the stream while the pointer moves over the source and
    /// some device is sent it (`watched`), when that is more often than the link tick; nil
    /// otherwise, and the tick samples. Off the source every device is told the same `inside:
    /// false`, so sampling faster there sends nothing: the sample that sees the pointer leave still
    /// tells them, and the next tick sees it come back. At a frame rate the tick keeps up with (33
    /// fps and below), a sampler would sample less often than the tick.
    static func samplerInterval(moving: Bool, inside: Bool, watched: Bool, frameInterval: Double,
                                tickInterval: Double) -> Double? {
        guard moving, inside, watched, frameInterval < tickInterval else { return nil }
        return frameInterval
    }

    /// One sample: one read of the pointer (the scripted one on a synthetic host), judged by
    /// PointerControl and placed in the source's rectangle. Nil, and no read, without a geometry,
    /// and on a synthetic host before the scripted pointer's first step. Counts `ptr.mac` when the
    /// read hands the pointer to the Mac. Never waits for the window server beyond the read.
    /// `devices`: those the host would send the pointer to (every ready one). A regular-mode
    /// window's bounds are re-read after a move only while one of them is not the one moving the
    /// pointer, since the re-read places the pointer for those that are sent it: a device driving
    /// alone moves it at every input and is sent nothing. The re-read every `rereadAnyway` seconds
    /// runs whoever is there.
    func sample(devices: [ObjectIdentifier]) -> Reading? {
        lock.lock()
        guard let geometry else { lock.unlock(); return nil }
        let now = clock()
        let read: CGPoint?
        if synthetic {
            read = path == nil ? nil : scriptedPointer(now: now)
        } else {
            read = readLocation()
        }
        guard let p = read else { lock.unlock(); return nil }
        let moved = lastRead.map { $0 != p } ?? true
        lastRead = p
        let handedOver = control.read(p, now: now)
        let watched = devices.contains { control.controller != .client($0) }
        var rect: CGRect
        var onScreen = true
        var reread: CGWindowID?
        switch geometry {
        case .rect(let r):
            rect = r
        case .window(let id, let r):
            rect = r
            if let w = window, w.id == id { rect = w.state.bounds; onScreen = w.state.onScreen }
            let since = now - rereadStartedAt
            if !rereading, (moved && watched && since >= rereadAfterMove) || since >= rereadAnyway {
                reread = startRereadLocked(id)
            }
        }
        let f = PointerControl.fraction(of: p, in: rect)
        let reading = Reading(x: f.x, y: f.y, inside: f.inside && onScreen, controller: control.controller,
                              moving: control.isMoving(now: now))
        lock.unlock()
        if let reread { dispatchReread(reread) }
        if handedOver { Stats.shared.bump("ptr.mac") }
        return reading
    }

    // MARK: The window's re-read (sill.pointer)

    /// Under `lock`: marks a re-read of `id` as started and returns the id to dispatch once the
    /// lock is released, or nil when one runs already (it is then owed once that one lands).
    private func startRereadLocked(_ id: CGWindowID) -> CGWindowID? {
        if rereading { rereadOwed = true; return nil }
        rereading = true
        rereadOwed = false
        rereadStartedAt = clock()
        return id
    }

    /// Reads the window's state on `sill.pointer` and keeps it when it is still the window judged
    /// against; then an owed re-read, if any.
    private func dispatchReread(_ id: CGWindowID) {
        rereadQueue.async { [self] in
            let state = readWindow(id)
            lock.lock()
            if let w = window, w.id == id {
                // Gone from the window server's list: off screen (closed, or not yet listed).
                window = (id, state ?? WindowState(bounds: w.state.bounds, onScreen: false))
            }
            rereading = false
            var again: CGWindowID?
            if rereadOwed, let w = window { again = startRereadLocked(w.id) }
            lock.unlock()
            if let again { dispatchReread(again) }
        }
    }

    // MARK: The scripted pointer (TEST ONLY)

    /// Under `lock`: where the scripted pointer is at `now`. Its clock starts at the first sample;
    /// each step whose time has come moves it there unless a dry run's move is newer. Nil before
    /// the first step (and before any move).
    private func scriptedPointer(now: Double) -> CGPoint? {
        guard let steps = path?.steps else { return nil }
        let start = pathStart ?? now
        pathStart = start
        while nextStep < steps.count, start + steps[nextStep].t <= now {
            let at = start + steps[nextStep].t
            if at >= testPointAt {
                testPoint = steps[nextStep].point
                testPointAt = at
            }
            nextStep += 1
        }
        return testPoint
    }

    // MARK: The window server (the defaults)

    /// The pointer's location in top-left global points, the injector's space. Every process may
    /// read it, with no permission (the plan's "Measured"); about a microsecond.
    static func pointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// One window's bounds and on-screen flag (110–144 µs on an idle Mac). Nil when the window
    /// server does not list it. `kCGWindowIsOnscreen` is present only while it is on screen.
    static func windowState(of id: CGWindowID) -> WindowState? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        return WindowState(bounds: bounds, onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
}

/// TEST ONLY (SILL_TEST_POINTER_PATH=<file>, a synthetic host only): a scripted pointer on the test
/// pattern, standing in for the Mac's own (docs/pointer-visibility-plan.md §4.10). Each line is
/// `T X Y`: T seconds since the host's first sample (never decreasing), X and Y points in the
/// 1512×949 pattern, any finite values (outside it too); `#` comments and blank lines are skipped.
/// At most `maxSteps` steps and `maxBytes` bytes; a file that breaks a rule is refused whole, with
/// one line. It turns the poll on there, so the gates can exercise Sill's own motion, the settle
/// and hand-backs without touching the real pointer.
struct TestPointerPath: Equatable {
    struct Step: Equatable {
        let t: Double
        let point: CGPoint
    }
    let steps: [Step]

    static let maxSteps = 10_000
    static let maxBytes = 1 << 20

    /// Why a file is refused, in the words of its line.
    enum Problem: Error, Equatable {
        case unreadable
        case tooBig
        case tooManySteps
        /// The line (1-based) is not three finite numbers, or its time is negative.
        case notStep(line: Int)
        /// The line's time is earlier than the step before it.
        case goesBack(line: Int)

        var words: String {
            switch self {
            case .unreadable: return "it cannot be read"
            case .tooBig: return "it is over 1 MiB"
            case .tooManySteps: return "it has over 10,000 steps"
            case .notStep(let n): return "line \(n) is not \"T X Y\" (seconds, then points)"
            case .goesBack(let n): return "line \(n) goes back in time"
            }
        }
    }

    /// The steps of a file's text.
    static func parse(_ text: String) -> Result<TestPointerPath, Problem> {
        var steps: [Step] = []
        // Split on each line's end as Swift sees it: "\r\n" is one Character, so splitting on "\n"
        // alone would leave a file written with CRLF one long line.
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let numbers = fields.compactMap { Double($0) }
            guard fields.count == 3, numbers.count == 3, numbers.allSatisfy({ $0.isFinite }), numbers[0] >= 0 else {
                return .failure(.notStep(line: i + 1))
            }
            if let last = steps.last, numbers[0] < last.t { return .failure(.goesBack(line: i + 1)) }
            guard steps.count < maxSteps else { return .failure(.tooManySteps) }
            steps.append(Step(t: numbers[0], point: CGPoint(x: numbers[1], y: numbers[2])))
        }
        return .success(TestPointerPath(steps: steps))
    }

    /// The steps of the file at `path`.
    static func load(_ path: String) -> Result<TestPointerPath, Problem> {
        guard let data = FileManager.default.contents(atPath: path) else { return .failure(.unreadable) }
        guard data.count <= maxBytes else { return .failure(.tooBig) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.unreadable) }
        return parse(text)
    }
}

/// The pointer step's two TEST ONLY hooks (docs/pointer-visibility-plan.md §4.10), read once at the
/// coordinator's start: honoured only by a synthetic host (which does not advertise), each ignored
/// with one line anywhere else. Neither prints anything without its variable.
enum PointerTestHooks {
    /// SILL_TEST_POINTER_PATH: the scripted pointer, and the line to print.
    static func pointerPath(synthetic: Bool, environment env: [String: String]) -> (path: TestPointerPath?, line: String?) {
        guard let file = env["SILL_TEST_POINTER_PATH"], !file.isEmpty else { return (nil, nil) }
        guard synthetic else { return (nil, "SILL_TEST_POINTER_PATH=\(file) ignored: only a --synthetic host takes it.") }
        switch TestPointerPath.load(file) {
        case .success(let path):
            let n = path.steps.count
            return (path, "Test pointer: \(n) step\(n == 1 ? "" : "s") from \(file); this host records input and never posts it.")
        case .failure(let problem):
            return (nil, "SILL_TEST_POINTER_PATH=\(file) ignored: \(problem.words).")
        }
    }

    /// SILL_TEST_SOFTWARE_ENCODER=1: streams start on the software encoder, the launch probe never
    /// runs and the re-check never starts, so a gate never touches the Mac's one hardware encoder
    /// while Noah streams. Any other value is ignored with one line.
    static func softwareEncoder(synthetic: Bool, environment env: [String: String]) -> (on: Bool, line: String?) {
        guard let value = env["SILL_TEST_SOFTWARE_ENCODER"], !value.isEmpty else { return (false, nil) }
        guard synthetic else { return (false, "SILL_TEST_SOFTWARE_ENCODER ignored: only a --synthetic host takes it.") }
        guard value == "1" else { return (false, "SILL_TEST_SOFTWARE_ENCODER=\(value) ignored: 1 turns it on.") }
        return (true, "Test encoder: software only (SILL_TEST_SOFTWARE_ENCODER); the hardware encoder is never probed.")
    }
}
