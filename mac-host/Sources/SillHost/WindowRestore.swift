import Foundation
import CoreGraphics

/// A window Sill sized for a device goes back when it stops streaming (issue #57;
/// docs/restore-window-frames-plan.md). Pure: frames in, decisions out, and the two sequences that
/// read and move a window (`fit`, `stop`) over `Access`, which WindowSizer implements with
/// Accessibility (`WindowSizer.AXWindows`) and the check with a stand-in Mac. The coordinator calls
/// them (StreamCoordinator's `fitToViewport` through `WindowSizer.resize`, `restoreFits`, `stageHome`);
/// `Tests/checks/window-restore` checks this file alone.
///
/// In regular mode (Virtual Display off) Aa resizes the real window to the device's panel at the
/// text scale it asks for. The first fit records where the window was; when the window stops
/// streaming (another window or the Desktop picked, the last device gone, a stream that ended, Quit,
/// a signal) it goes back there, unless the person at the Mac has made it their own since: moved,
/// it keeps its new place and gets its own size back; resized, it is left alone. A window put on the
/// virtual display takes the frame it would have gone back to as its way home (`homeForStage`).
///
/// Frames are global CG points with a top-left origin, as Accessibility and the window server give
/// them.
enum WindowRestore {
    /// How far apart two frames, sizes or points may be and still be the same: Accessibility and the
    /// window server round differently, and an app may land a point off what it was asked.
    static let tolerance: CGFloat = 2

    /// One window Sill has sized.
    struct Record: Equatable {
        /// The frame before Sill first touched it (Accessibility's, read just before the first resize).
        var original: CGRect
        /// The frame Sill last left it at, as the app took it (read back after the resize: an app
        /// enforces a minimum, snaps to a grid, keeps the window on screen).
        var set: CGRect
        /// The size Sill last asked for: an app that applies a size after answering the write reads
        /// back its old one, and is at this size by the time it stops streaming.
        var asked: CGSize
        /// The window was away from where Sill left it when Sill fitted it again (the person at the
        /// Mac moved it, or its app did; `movedSince`): from then on it keeps its place when it goes back.
        var moved: Bool
    }

    /// A fit: Sill resized the window from `before` and the app took `after`, asked for `asked`. The
    /// first makes the record; a later one (a rotation, another Aa step, a restart that resized it)
    /// keeps the original frame and notes a move since the last (`movedSince`).
    static func fitted(_ r: Record?, before: CGRect, after: CGRect, asked: CGSize) -> Record {
        guard var r else { return Record(original: before, set: after, asked: asked, moved: false) }
        if movedSince(r, before) { r.moved = true }
        r.set = after
        r.asked = asked
        return r
    }

    /// Whether the window `r` describes was moved since Sill last fitted it, by the time it is at `now`.
    /// At Sill's size (read back or asked), when its top-left corner is elsewhere. At another size, the
    /// person resized it, and a resize from any edge or corner keeps the opposite edge where it was (with
    /// Option held, it moves the two apart or together): it moves the top-left corner without being a
    /// move, and the next fit undoes it (keeping that corner), so the window still goes back whole. A
    /// move then is both its left and right edges, or both its top and bottom, gone the same way from
    /// where Sill left it, at either of Sill's sizes (an app that applies a size after answering reads
    /// back its old one).
    static func movedSince(_ r: Record, _ now: CGRect) -> Bool {
        if same(now.size, r.set.size) || same(now.size, r.asked) { return !same(now.origin, r.set.origin) }
        return shifted(from: r.set, to: now) && shifted(from: CGRect(origin: r.set.origin, size: r.asked), to: now)
    }

    /// Both edges of an axis gone the same way, more than `tolerance` each.
    static func shifted(from a: CGRect, to b: CGRect) -> Bool {
        func went(_ near: CGFloat, _ far: CGFloat) -> Bool { abs(near) > tolerance && abs(far) > tolerance && (near > 0) == (far > 0) }
        return went(b.minX - a.minX, b.maxX - a.maxX) || went(b.minY - a.minY, b.maxY - a.maxY)
    }

    /// Why a window that stopped streaming is left as it is.
    enum Reason: Equatable {
        /// In a full-screen Space: it refuses moves and sizes, and leaving it is the person's call.
        case fullScreen
        /// Its size is no longer Sill's: resized on the Mac after Sill last fitted it.
        case resized
    }

    /// What becomes of a window when it stops streaming.
    enum Decision: Equatable {
        /// Closed, or its app quit: nothing left to restore.
        case gone
        /// Already where it would go: nothing to do.
        case home
        /// Where it was, as far as can be seen, but Sill's size may still be on its way: an app that
        /// applies a size after answering the write, stopped within that moment, would otherwise
        /// take it after this and keep it. The frame is written again, without a line.
        case settle(CGRect)
        case leave(Reason)
        /// Moved and sized to this frame: the original (`whole`), or its own size where it was moved.
        case restore(CGRect, whole: Bool)
    }

    /// The window `r` describes stops streaming, `current` its frame now (nil: gone), `area` the
    /// visible frame of the display it is on (for a moved window's nudge; nil: none).
    static func decide(_ r: Record, current: CGRect?, fullScreen: Bool, area: CGRect?) -> Decision {
        guard let current else { return .gone }
        if fullScreen { return .leave(.fullScreen) }
        if same(current, r.original) {
            // Sill asked for another size and the app never showed it: on its way, or refused (an app
            // at its minimum). Writing the original again costs nothing in either case.
            if !same(r.asked, r.original.size), same(r.set.size, r.original.size) { return .settle(r.original) }
            return .home
        }
        // Sill's size is the one it read back or the one it asked for; anything else is the person's.
        guard same(current.size, r.set.size) || same(current.size, r.asked) else { return .leave(.resized) }
        if !r.moved, same(current.origin, r.set.origin) { return .restore(r.original, whole: true) }
        // Moved: its own size where it is, kept on its display as a fit keeps it.
        var target = CGRect(origin: current.origin, size: r.original.size)
        if let area { target.origin = keep(target, in: area) }
        return same(target, current) ? .home : .restore(target, whole: false)
    }

    /// The way home the virtual display keeps for a window Sill had fitted when it stages it
    /// (`VirtualStage.prepare(…, home:)`): the frame it would have gone back to had it stopped
    /// streaming now. Nil: the stage takes the window's frame as it finds it (already home, left as
    /// it is, or gone).
    static func homeForStage(_ d: Decision) -> CGRect? {
        switch d {
        case .restore(let frame, _), .settle(let frame): return frame
        case .gone, .home, .leave: return nil
        }
    }

    /// The origin that keeps `frame` inside `area`, moving it as little as possible. A frame bigger
    /// than the area keeps its top-left corner in it, so the title bar stays reachable. A fit's nudge
    /// (WindowSizer.resize) and a moved window's way back.
    static func keep(_ frame: CGRect, in area: CGRect) -> CGPoint {
        var origin = frame.origin
        if frame.maxX > area.maxX { origin.x = area.maxX - frame.width }
        if frame.maxY > area.maxY { origin.y = area.maxY - frame.height }
        origin.x = max(origin.x, area.minX)
        origin.y = max(origin.y, area.minY)
        return origin
    }

    static func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance }
    static func same(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance }
    static func same(_ a: CGRect, _ b: CGRect) -> Bool { same(a.origin, b.origin) && same(a.size, b.size) }

    // MARK: Reading and moving a window

    /// What a write to a window's position or size came to.
    enum Write: Equatable {
        case done
        /// Accessibility's error: the app said no (a window that cannot be resized answers -25200), or
        /// the window is gone.
        case refused(Int32)
        /// No answer within the element's timeout (Accessibility's cannotComplete): a busy app may still
        /// apply it once it gets to it.
        case timedOut
    }

    /// The reads and writes a fit and a window's way back make: Accessibility on the Mac
    /// (WindowSizer.AXWindows), a stand-in Mac in the check. `W` is one window, as the ledger keeps it.
    protocol Access {
        associatedtype W
        /// Accessibility's frame now; nil when it does not answer, or the window is gone.
        mutating func frame(_ w: W) -> CGRect?
        /// In a full-screen Space (AppKit's AXFullScreen).
        mutating func isFullScreen(_ w: W) -> Bool
        /// The window server still lists it (a closed window is not listed).
        mutating func isListed(_ w: W) -> Bool
        /// The visible frame of the display holding most of `r`; nil with no display.
        mutating func visibleArea(around r: CGRect) -> CGRect?
        mutating func setPosition(_ w: W, _ p: CGPoint) -> Write
        mutating func setSize(_ w: W, _ s: CGSize) -> Write
        /// Moves and sizes it to `frame` as the virtual display's restore does (position, size,
        /// position, one more try for a busy app, never left off every display): true when it went
        /// through, or there is nothing left to move.
        mutating func put(_ w: W, at frame: CGRect) -> Bool
        /// "Safari — Apple Developer" (`name(app:title:)`), for the lines.
        func name(_ w: W) -> String
    }

    /// What a fit (`fit`) came to.
    enum FitResult: Equatable {
        /// Not tried: the window is in a full-screen Space. It may refuse the writes or answer them and
        /// change nothing; recorded, the display's frame would be taken for the window's own.
        case fullScreen
        /// The app refused the size (Accessibility's error); a nudge made for it was put back.
        case refused(Int32)
        /// Sill resized it from `before` and it took `after`: Accessibility's frame, read back. When the
        /// size went through but its read-back did not, the frame it had where Sill put it, as a
        /// read-back that has not shown the size yet would be (the record's `asked` covers the size, as
        /// for an app that applies a size after answering). `timedOut`: the size went unanswered, the
        /// nudge was put back and `after` is `before`; a busy app may still take it.
        case fitted(before: CGRect, after: CGRect, timedOut: Bool)
    }

    /// One fit, as WindowSizer.resize makes it once it has matched the window's element: never of a
    /// window in full screen (nothing written); the frame before (`fallback`, the window server's, when
    /// Accessibility gives none), a nudge so the asked frame stays on its display (an app that clamps
    /// its frame to the screen would shrink the window instead of letting it move), the size, then the
    /// size the app took (a minimum, a grid) and a second nudge for that.
    static func fit<A: Access>(_ w: A.W, to size: CGSize, fallback: CGRect, on a: inout A) -> FitResult {
        if a.isFullScreen(w) { return .fullScreen }
        let read = a.frame(w)
        let before = read ?? fallback
        let area = a.visibleArea(around: before)
        var nudgedFrom: CGPoint?
        var at = before.origin
        if let from = read?.origin, let area {
            let to = keep(CGRect(origin: from, size: size), in: area)
            // A window that will not move may still resize.
            if to != from, a.setPosition(w, to) == .done { nudgedFrom = from; at = to }
        }
        switch a.setSize(w, size) {
        case .done:
            break
        case .refused(let code):
            // The move was for the new size: without it, the window goes back where it was.
            if let nudgedFrom { _ = a.setPosition(w, nudgedFrom) }
            return .refused(code)
        case .timedOut:
            // A busy app may take the size once it gets to it: recorded as asked, from where it was.
            if let nudgedFrom { _ = a.setPosition(w, nudgedFrom) }
            return .fitted(before: before, after: before, timedOut: true)
        }
        // The write went through, the read-back did not: as if it had not shown the size yet.
        guard let took = a.frame(w) else { return .fitted(before: before, after: CGRect(origin: at, size: before.size), timedOut: false) }
        if let area {
            let to = keep(took, in: area)
            if to != took.origin, a.setPosition(w, to) == .done {
                return .fitted(before: before, after: a.frame(w) ?? CGRect(origin: to, size: took.size), timedOut: false)
            }
        }
        return .fitted(before: before, after: took, timedOut: false)
    }

    /// What became of one window that stopped streaming (`stop`), for the coordinator's line and stats.
    struct Stopped: Equatable {
        let id: CGWindowID
        /// Nil: its app did not answer, and it was left where it is.
        let decision: Decision?
        /// Whether the move the decision called for went through.
        let done: Bool
        let line: String?
    }

    /// One window Sill fitted stops streaming: its frame now, the rule (`decide`) and the move that
    /// calls for, through the element its first fit matched. No frame from a window the window server
    /// no longer lists: gone. None from one it lists: its app does not answer (a beach ball), and the
    /// window is left with a line rather than have each write wait out a second.
    static func stop<A: Access>(_ id: CGWindowID, _ w: A.W, _ r: Record, on a: inout A) -> Stopped {
        let name = a.name(w)
        guard let current = a.frame(w) else {
            if a.isListed(w) { return Stopped(id: id, decision: nil, done: false, line: notAnsweringLine(name: name)) }
            return Stopped(id: id, decision: .gone, done: false, line: nil)
        }
        let d = decide(r, current: current, fullScreen: a.isFullScreen(w), area: a.visibleArea(around: current))
        var done = false
        switch d {
        case .restore(let frame, _), .settle(let frame): done = a.put(w, at: frame)
        case .gone, .home, .leave: break
        }
        return Stopped(id: id, decision: d, done: done, line: line(d, name: name, current: current, done: done))
    }

    /// Where a window Sill fitted would go back to now (`stop`'s decision; nothing is moved), for the
    /// virtual display to keep as its way home when it takes the window; nil: as the stage finds it.
    static func stageHome<A: Access>(_ w: A.W, _ r: Record, on a: inout A) -> CGRect? {
        guard let current = a.frame(w) else { return nil }
        return homeForStage(decide(r, current: current, fullScreen: a.isFullScreen(w), area: a.visibleArea(around: current)))
    }

    // MARK: A window entering or leaving full screen

    /// How many of the catalog's looks a streamed window entering or leaving full screen may be off
    /// the on-screen list and still stream: the virtual display's three polls for a staged window.
    static let fullScreenGrace = 3

    /// The window streaming in regular mode is missing from the catalog's on-screen list. A window
    /// entering or leaving full screen is off every list for a second or two, and stopping it then
    /// would decide its way back mid-change (still full screen, or at the display's frame: left at
    /// the device's size for good). So it keeps streaming through `fullScreenGrace` such looks when it
    /// was full screen when last listed (`wasFullScreen`) or, when Sill fitted it (`w`, its element),
    /// Accessibility says it is full screen now; unless it is gone (no frame, and the window server no
    /// longer lists it). Anything else stops at once, as before.
    static func keepsStreaming<A: Access>(_ w: A.W?, looks: Int, wasFullScreen: Bool, on a: inout A) -> Bool {
        guard looks <= fullScreenGrace else { return false }
        guard let w else { return wasFullScreen }
        if a.frame(w) == nil, !a.isListed(w) { return false }
        return wasFullScreen || a.isFullScreen(w)
    }

    /// Whether a listed frame is a full-screen window's: it covers one of `displays` (CG global
    /// frames), its top at the display's top, 98 % of it or more (a window filling the area under the
    /// menu bar covers 98 % of a laptop's display and must not count), as VirtualStage.windowCoversDisplay
    /// has it for a staged window.
    static func coversDisplay(_ frame: CGRect, _ displays: [CGRect]) -> Bool {
        displays.contains { d in
            let i = d.intersection(frame)
            guard !i.isNull, d.width > 0, d.height > 0 else { return false }
            return frame.minY <= d.minY + 1 && i.width * i.height >= 0.98 * d.width * d.height
        }
    }

    // MARK: The windows Sill sized

    /// The records by window ID, each with what the coordinator needs to move the window (`Handle`:
    /// a WindowSizer.Placement there, anything in the check). In memory only: a frame applied at the
    /// next launch, perhaps days later, would be worse than none.
    struct Ledger<Handle> {
        struct Entry {
            var record: Record
            /// The first fit's: an Accessibility element stays valid as long as its window exists.
            let handle: Handle
        }
        private(set) var entries: [CGWindowID: Entry] = [:]

        var isEmpty: Bool { entries.isEmpty }

        func record(_ id: CGWindowID) -> Record? { entries[id]?.record }

        /// A fit of window `id` (see `WindowRestore.fitted`).
        mutating func fitted(_ id: CGWindowID, handle: Handle, before: CGRect, after: CGRect, asked: CGSize) {
            let old = entries[id]
            entries[id] = Entry(record: WindowRestore.fitted(old?.record, before: before, after: after, asked: asked),
                                handle: old?.handle ?? handle)
        }

        /// The windows that stop streaming when `keep` streams next (nil: none streams), taken out
        /// in window ID order, for the coordinator to put back.
        mutating func stopping(keeping keep: CGWindowID?) -> [(id: CGWindowID, entry: Entry)] {
            let ids = entries.keys.filter { $0 != keep }.sorted()
            var out: [(id: CGWindowID, entry: Entry)] = []
            for id in ids { if let e = entries.removeValue(forKey: id) { out.append((id, e)) } }
            return out
        }

        /// Window `id` went onto the virtual display, whose stage now keeps its way home.
        mutating func take(_ id: CGWindowID) -> Entry? { entries.removeValue(forKey: id) }

        /// Every window that stops streaming when `keep` streams next (`stopping`) put back
        /// (`WindowRestore.stop`), but the one the virtual display holds (`staged`: only when Quit or a
        /// signal lands while the stage takes it), which goes home with the stage.
        mutating func restore<A: Access>(keeping keep: CGWindowID?, staged: CGWindowID?, on a: inout A) -> [Stopped] where A.W == Handle {
            var out: [Stopped] = []
            for (id, entry) in stopping(keeping: keep) where id != staged {
                out.append(WindowRestore.stop(id, entry.handle, entry.record, on: &a))
            }
            return out
        }
    }

    // MARK: The log

    /// "Safari — Apple Developer", or the app alone for an untitled window.
    static func name(app: String, title: String) -> String { title.isEmpty ? app : "\(app) — \(title)" }

    /// "(212,95,1280×800)", as the virtual display's lines give a frame.
    static func text(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f,%.0f×%.0f)", r.minX, r.minY, r.width, r.height)
    }

    /// The coordinator's one line about a window that stopped streaming: what it did, or why not.
    /// Nil when nothing happened as far as can be seen (gone, already home, or settled where it was).
    /// `done`: whether the restore went through.
    static func line(_ d: Decision, name: String, current: CGRect?, done: Bool) -> String? {
        switch d {
        case .gone, .home, .settle:
            return nil
        case .leave(.fullScreen):
            return "Left \(name) as it is: it is full screen"
        case .leave(.resized):
            return "Left \(name) at \(current.map(text) ?? "its frame"): it was resized on the Mac"
        case .restore(let frame, let whole):
            guard done else { return "Could not restore \(name) to \(text(frame))" }
            return whole ? "Restored \(name) to \(text(frame))" : "Restored \(name) to \(text(frame)), its own size where it was moved"
        }
    }

    /// The line for a window whose app does not answer Accessibility at the stop (a beach ball): it
    /// is left where it is rather than have each write wait out its timeout.
    static func notAnsweringLine(name: String) -> String {
        "Could not restore \(name): it is not answering Accessibility"
    }
}
