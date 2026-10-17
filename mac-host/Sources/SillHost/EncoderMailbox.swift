import Foundation
import CoreMedia

/// HEVCEncoder's frames on their way into VideoToolbox, kept apart from VideoToolbox itself: the
/// one frame inside it, the one-slot mailbox behind it (a newer frame replaces a waiting one), the
/// watchdog's clock, and what the next frame to go in carries (a timestamp later than the last
/// one's, a requested keyframe). No locking and no dispatching: HEVCEncoder keeps it under its
/// lock, makes the VideoToolbox calls and queues the hand-overs on its serial `encodeQueue`.
///
/// One frame inside at a time, on the hardware and the software encoder alike: the next goes in
/// when the last came back. Two at once was measured against the hardware's slow state and
/// dropped (CLAUDE.md, "The 33 fps plateau").
///
/// Foundation and CoreMedia only, so it is checked on its own with swiftc against a stand-in for
/// VideoToolbox that returns frames after programmable delays, in virtual time
/// (`Tests/checks/encoder-mailbox`, which CI runs).
struct EncoderMailbox<Frame> {
    /// The frame let in and not yet back.
    struct Inside: Equatable {
        let id: Int
        /// When its watchdog clock started: when it was let in, and again when `submit` handed it
        /// to VideoToolbox.
        var since: CFTimeInterval
        /// `submit` has handed it to VideoToolbox. Until then it is on `encodeQueue`, and once the
        /// session is dead it never goes in.
        var handed: Bool
    }
    /// The frame let in and not yet back; nil while the place is free. A dead session never clears
    /// it.
    private(set) var inside: Inside?
    /// The newest frame that found the place taken.
    private(set) var waiting: Frame?
    /// The watchdog gave up on this session, or its owner did: nothing goes in or out any more.
    private(set) var dead = false
    /// The last timestamp handed to VideoToolbox. Timestamps never go backwards (frame reordering
    /// is off): see `handOver`.
    private(set) var lastPTS: CMTime = .invalid
    /// The next frame to go in becomes a keyframe.
    var keyframeRequested = false
    /// The last id given out: 1 for the first frame let in, 2 for the next, and so on.
    private var lastID = 0

    enum Admission: Equatable {
        /// Let in as frame `id`: hand it to VideoToolbox (`handOver`, then the encode call).
        case goesIn(id: Int)
        /// The place is taken: it waits in the mailbox. `replaced`: it pushed out an older waiting
        /// frame, which is dropped (the newer frame wins).
        case waits(replaced: Bool)
        /// The session is dead: dropped.
        case dropped
    }

    /// A new frame, from the capture or a keyframe's re-encode.
    mutating func admit(_ frame: Frame, now: CFTimeInterval) -> Admission {
        guard !dead else { return .dropped }
        if inside == nil { return .goesIn(id: letIn(now: now)) }
        let replaced = waiting != nil
        waiting = frame
        return .waits(replaced: replaced)
    }

    private mutating func letIn(now: CFTimeInterval) -> Int {
        lastID += 1
        inside = Inside(id: lastID, since: now, handed: false)
        return lastID
    }

    struct HandOver: Equatable {
        let pts: CMTime
        let keyframe: Bool
        /// The frame's own timestamp was not later than the last one handed over.
        let ptsFixed: Bool
    }

    /// `submit`, on the serial `encodeQueue`, is about to hand frame `id` to VideoToolbox: its
    /// clock starts again, its timestamp is made later than the last one handed over (a keyframe's
    /// re-encode is stamped just after the last frame that went in, and a frame let in before it
    /// may go in first), and a requested keyframe goes with it. Nil when the session died after
    /// the frame was let in.
    mutating func handOver(_ id: Int, pts requested: CMTime, now: CFTimeInterval) -> HandOver? {
        guard !dead else { return nil }
        if inside?.id == id { inside = Inside(id: id, since: now, handed: true) }
        var pts = requested
        var fixed = false
        if lastPTS.isValid, CMTimeCompare(pts, lastPTS) <= 0 {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000))
            fixed = true
        }
        lastPTS = pts
        let keyframe = keyframeRequested
        keyframeRequested = false
        return HandOver(pts: pts, keyframe: keyframe, ptsFixed: fixed)
    }

    enum Return {
        /// The session is dead: its late output must never be forwarded (its devices have moved on
        /// to a new session, with a new size and new parameter sets).
        case late
        /// A second notice for a frame already back (an error status and a handler call for the
        /// same frame): nothing is freed twice.
        case duplicate
        /// The place is free.
        case freed
        /// The waiting frame takes the place as frame `id`: hand it to VideoToolbox.
        case next(Frame, id: Int)
    }

    /// VideoToolbox let go of frame `id`: its output came, or the encode call refused it.
    mutating func returned(_ id: Int, now: CFTimeInterval) -> Return {
        guard !dead else { return .late }
        guard inside?.id == id else { return .duplicate }
        inside = nil
        guard let frame = waiting else { return .freed }
        waiting = nil
        return .next(frame, id: letIn(now: now))
    }

    /// A frame is on its way to VideoToolbox: let in and not handed over yet (on `encodeQueue`), or
    /// waiting in the mailbox. The next hand-over then carries a requested keyframe, with no
    /// re-encode needed (HEVCEncoder.keyframeCheck).
    var frameOnItsWay: Bool { waiting != nil || inside?.handed == false }

    /// The watchdog: true, once, when the frame inside has been there more than `after` seconds
    /// by its clock without coming back. The session is dead from then on.
    mutating func giveUpIfHung(now: CFTimeInterval, after: CFTimeInterval) -> Bool {
        guard !dead, let inside, now - inside.since > after else { return false }
        giveUp()
        return true
    }

    /// Nothing more goes in, and the waiting frame is dropped. True when a frame is still inside
    /// VideoToolbox (handed over and not back); a frame still on `encodeQueue` never goes in now.
    @discardableResult
    mutating func giveUp() -> Bool {
        dead = true; waiting = nil
        return inside?.handed == true
    }

    enum Teardown: Equatable {
        /// Nothing to wait for: invalidate the session.
        case idle
        /// A live session with a frame let in: let VideoToolbox finish it first.
        case drain
        /// Given up on with a frame inside VideoToolbox: never wait for it (a stuck encoder never
        /// lets go). Its clock started at `since`, when it was handed over.
        case stalled(since: CFTimeInterval)
    }

    /// What the session's teardown does (HEVCEncoder's deinit).
    var teardown: Teardown {
        guard let inside else { return .idle }
        guard dead else { return .drain }
        return inside.handed ? .stalled(since: inside.since) : .idle
    }
}
