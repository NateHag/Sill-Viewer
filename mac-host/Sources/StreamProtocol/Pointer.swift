import Foundation

// The Mac's pointer on the device (docs/pointer-visibility-plan.md §3): kind 26. The rules of
// HostSettings.swift apply (JSON only; every field optional, and fields added later too; no enums on
// the wire, strings instead; never rename or retype a field). A later "who moved it" field (the Mac or
// another device) would be an optional string.
//
// Pure: Foundation only, so it is checked on its own with swiftc (Tests/checks/pointer-control).

/// Host → device (kind 26): the Mac's pointer while this device is not the one moving it: the Mac's
/// own mouse or trackpad moved it last (or an app warped it), or another device did. The host sends
/// it to every device but the one driving, only when it changed. JSON; every field optional, so `{}`
/// decodes and an older host's absence of a field reads as nil.
///
/// Two payloads: over the stream `{"inside":true,"seen":12,"x":0.4213,"y":0.1873}`, off it
/// `{"inside":false,"seen":12}`.
public struct MacPointer: Codable, Hashable, Sendable {
    /// Where the pointer is, as a fraction of the streamed frame: InputEvent's space, 0…1 across its
    /// width and height (Input.swift). Rounded to 4 decimal places (`rounded`: 0.3 px on a 3000 px
    /// frame, and short JSON). Nil when `inside` is false.
    public var x: Double?
    public var y: Double?
    /// Over the streamed source: inside its rectangle, and for a window in regular mode, that window
    /// on screen. Nil counts as false.
    public var inside: Bool?
    /// How many input messages (kind 8) the host had read on this connection when it sent this. A
    /// device that has sent more on the connection since drops it: it was built before the host read
    /// that device's latest input (§3.3). Nil counts as 0.
    public var seen: Int?

    public init(x: Double? = nil, y: Double? = nil, inside: Bool? = nil, seen: Int? = nil) {
        self.x = x; self.y = y; self.inside = inside; self.seen = seen
    }

    /// A fraction as the wire carries it: 4 decimal places.
    public static func rounded(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

    /// Where a device draws the Mac's pointer: x and y when `inside` is true and both are there and
    /// finite; nil otherwise (off the stream, or a payload that says less than it should).
    public var position: (x: Double, y: Double)? {
        guard inside == true, let x, let y, x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }
}
