import CoreGraphics
import Foundation
import StreamProtocol

/// Who is moving the Mac's pointer: the Mac (its own mouse or trackpad, or anything that is not
/// Sill, such as an app warping it) or the device whose input the host read last
/// (docs/pointer-visibility-plan.md §4.1). The host keeps one controller and sends where the pointer
/// is (kind 26) to every device but that one.
///
/// It goes by the pointer's position alone, which every process may read with no permission: the
/// host reads it at each sample (`read`), and a read at least `minMove` from the last position that
/// counted (where Sill's own motion left the pointer, or the last real move) is the Mac's, unless it
/// falls in the settle: the `settle` seconds after the host read a pointer or scroll input
/// (`inputArrived`), or was about to post one or warp the cursor (`sillMoved`). Sill's own events
/// move the pointer too, absolutely and not always at once (a click past a display's edge lands
/// clamped; a click held while its app activates is posted a second or more after it was read), and
/// the settle absorbs them. Measured from the last position that counted rather than from the
/// previous read, a slow drag (under 0.5 pt a sample) still adds up, while a still mouse reads the
/// same point every time, so nothing creeps.
///
/// Any input (kind 8) hands the pointer to the device that sent it; only one that can move the
/// pointer (a pointer, scroll or scroll-gesture event) opens the settle, so after a key or typed text
/// the Mac's next real move shows its arrow at once. A device that leaves while driving hands it back
/// to the Mac.
///
/// What it cannot see (accepted): a click or scroll on the Mac without motion; motion within the
/// settle of the device's last input (the device is still driving); a move and back between two
/// reads.
///
/// A value type; PointerWatch holds it under its lock. Pure: Foundation, CoreGraphics and
/// StreamProtocol, checked on its own with swiftc (Tests/checks/pointer-control).
struct PointerControl {
    enum Controller: Equatable { case mac, client(ObjectIdentifier) }

    /// At launch nobody has driven: the Mac has the pointer.
    private(set) var controller: Controller = .mac
    /// Motion before this time may be Sill's own: input read and not yet posted, or posted and still
    /// landing (a clamped or late position).
    private var sillUntil = -Double.infinity
    /// The last position that counted: where Sill's own motion left the pointer, or the last real
    /// move. Nil until the first read.
    private var last: CGPoint?
    /// The read before, whatever it was, and when it was taken.
    private var previous: CGPoint?
    private var previousAt = -Double.infinity
    /// When a read last differed from the one before it (`isMoving`).
    private var changedAt = -Double.infinity

    /// Seconds after Sill's own input or motion during which a move is taken for Sill's.
    static let settle = 0.25
    /// Points from the last position that counted; reads carry fractions of a point.
    static let minMove: CGFloat = 0.5
    /// Seconds without a change after which the pointer counts as still (`isMoving`).
    static let stillAfter = 0.1

    /// A kind 8 read from `client` (sill.net, in the receive loop). Every kind hands it the pointer;
    /// only one that can move the pointer opens the settle (`movesPointer`).
    mutating func inputArrived(from client: ObjectIdentifier, movesPointer: Bool, now: Double) {
        controller = .client(client)
        if movesPointer { sillUntil = max(sillUntil, now + Self.settle) }
    }

    /// Sill is about to move the pointer itself: post a pointer or scroll event, or warp the cursor
    /// (main, through PointerWatch, just before it does). The controller stays: a held click's late
    /// post, or VirtualStage's warp home, never hands the pointer to anyone.
    mutating func sillMoved(now: Double) {
        sillUntil = max(sillUntil, now + Self.settle)
    }

    /// One read of the pointer's location (top-left global points), at a sample. True when the
    /// pointer passed to the Mac with it.
    ///
    /// - Within the settle, the read becomes the last position that counted and nothing else
    ///   changes, so the settle ends at the position where Sill left the pointer.
    /// - After it, a read at least `minMove` from the last position that counted is the Mac's: it
    ///   becomes that position, and the Mac the controller. A smaller difference changes nothing, the
    ///   last position included, so a slow drag adds up over a few reads instead of hiding under
    ///   `minMove` at every one.
    /// - The first read, and any read more than `settle` after the one before it, only sets the last
    ///   position that counted: the pointer was not watched in between, and Sill may have moved it
    ///   then with its settle over before the next read (VirtualStage's warp home as a stream stops,
    ///   while no sample runs). A real move in such a gap counts at its next read instead.
    @discardableResult
    mutating func read(_ p: CGPoint, now: Double) -> Bool {
        let watched = now - previousAt <= Self.settle
        if watched, let before = previous, before != p { changedAt = now }
        previous = p
        previousAt = now
        guard watched, let from = last else {
            last = p
            return false
        }
        if now < sillUntil {
            last = p
            return false
        }
        guard hypot(p.x - from.x, p.y - from.y) >= Self.minMove else { return false }
        last = p
        let handedOver = controller != .mac
        controller = .mac
        return handedOver
    }

    /// A device left; if it was driving, the Mac has the pointer again.
    mutating func clientLeft(_ client: ObjectIdentifier) {
        if controller == .client(client) { controller = .mac }
    }

    /// Whether the pointer is moving, whoever moves it: a read differed from the one before it in the
    /// last `stillAfter` seconds. While it moves over the source the host samples at the stream's
    /// frame rate, not only at the 30 ms tick (the plan's Q4, decided 2026-09-26), so the devices
    /// watching see it as smoothly as the picture (PointerWatch.samplerInterval).
    func isMoving(now: Double) -> Bool {
        now - changedAt <= Self.stillAfter
    }

    /// Whether an input can move the pointer, and so opens the settle: a pointer, scroll or
    /// scroll-gesture event. Keys and typed text cannot.
    static func movesPointer(_ event: InputEvent) -> Bool {
        switch event {
        case .pointer, .scroll, .scrollGesture: return true
        case .text, .key: return false
        }
    }

    /// The same for a kind 8 payload as the host reads it; one that does not decode moves nothing
    /// (it still hands its device the pointer, as every kind 8 does).
    static func movesPointer(payload: Data) -> Bool {
        Wire.decode(InputEvent.self, from: payload).map(movesPointer) ?? false
    }

    /// Where `p` is in the streamed source's rectangle `r` (both in top-left global points, the
    /// injector's), as the fractions kind 26 carries: rounded to 4 decimal places, and `inside` when
    /// both are at least 0 and below 1, judged before rounding. The far edges are out: the column at
    /// `maxX` is the next display's first (or past a window's edge), and the row at `maxY` the same.
    /// An empty, infinite or non-finite rectangle, or a non-finite point, is never inside.
    static func fraction(of p: CGPoint, in r: CGRect) -> (x: Double, y: Double, inside: Bool) {
        guard !r.isEmpty, !r.isInfinite,
              [r.minX, r.minY, r.width, r.height, p.x, p.y].allSatisfy({ $0.isFinite }) else { return (0, 0, false) }
        let x = Double((p.x - r.minX) / r.width)
        let y = Double((p.y - r.minY) / r.height)
        let inside = x >= 0 && x < 1 && y >= 0 && y < 1
        return (MacPointer.rounded(x), MacPointer.rounded(y), inside)
    }
}
