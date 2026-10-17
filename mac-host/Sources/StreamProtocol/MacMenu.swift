import Foundation

// The Mac's menus on the device (kinds 24, 25 and 27, see StreamMessage.swift; docs/menu-bar-plan.md
// §3): the streamed app's menu bar, read on the Mac over Accessibility, one menu at a time when the
// device opens it, and an item chosen there pressed on the Mac. HostSettings.swift's rules apply to
// all four types: JSON only; fields added later are optional; strings, not enums; never rename or
// retype a field. A later "alternate of the item above" flag, or an SF Symbol name from a Catalyst
// app, would be an optional field.
//
// Who is sent what:
// • A device asks once per connection, with a kind 27 without an id, after its first window list.
//   Only such a connection (a subscriber) is ever sent a top level, and the host reads nothing for
//   a connection that never asked: an older device, which sends no kind 27, costs the Mac nothing.
// • The version is the host's, one for all devices (there is one stream, so one app). It moves
//   whenever the app whose menus these are changes (to none included), or a re-read finds the top
//   level's titles, count or enabled flags changed. An id is good only within its version: a kind
//   25 or 27 with another version is answered at once and never read or pressed.
// • Within one version an id names one item for every device: an app can add or remove items
//   above a submenu without changing the top level, and a read that finds another submenu where
//   one was read before moves the version too. A fetch and a choice carry the title the device
//   showed, and the host acts only while the item at the id still has it.
// • Tokens are the device's, strictly increasing per connection, as kind 17's are; the host only
//   echoes them in `answering`.
// • Only a connection that asked for the top level (a subscriber) is served a menu or a choice;
//   any other is answered "The menus changed…" at once.
//
// Pure: Foundation only, so it is checked on its own with swiftc (Tests/checks/menus).

/// Host → device (kind 24). One of three shapes, told apart by which fields are set: a top level
/// (`menus`, and `answering` only when it replies to the kind 27 that asked for it), the answer to
/// a kind 27 for one menu (`answering`, `menu`, `items`), the answer to a kind 25 (`answering`,
/// `pressed`). Every field optional (HostSettings.swift's rules).
public struct MacMenu: Codable, Hashable, Sendable {
    /// The tree this belongs to. The host adds 1 whenever the app whose menus these are changes, or
    /// its top level does; ids are good only within one version. In every kind 24.
    public var version: Int?
    /// "Code", "com.microsoft.VSCode": the app, in a top level only.
    public var app: String?
    public var bundleID: String?
    /// The top level in the Mac's order, the Apple menu left out: each a submenu whose items come
    /// with kind 27. Empty when there are no menus (nothing streams, Sill's own app, no menu bar,
    /// no Accessibility: `note` says which when the device should show it).
    public var menus: [MacMenuItem]?
    /// The token of the kind 27 or 25 this answers.
    public var answering: Int?
    /// The answer to a kind 27: the menu's id, its items (at most 500), and how many more it has.
    public var menu: String?
    public var items: [MacMenuItem]?
    public var more: Int?
    /// The answer to a kind 25: whether the host pressed the item.
    public var pressed: Bool?
    /// The app did not answer the last read within 1 s: what is shown may be old, and presses are
    /// refused until it answers again. The device shows every item disabled.
    public var stale: Bool?
    /// Words the device shows as they are: why there are no menus, why a press was refused, why a
    /// menu could not be read.
    public var note: String?

    public init(version: Int? = nil, app: String? = nil, bundleID: String? = nil, menus: [MacMenuItem]? = nil,
                answering: Int? = nil, menu: String? = nil, items: [MacMenuItem]? = nil, more: Int? = nil,
                pressed: Bool? = nil, stale: Bool? = nil, note: String? = nil) {
        self.version = version; self.app = app; self.bundleID = bundleID; self.menus = menus
        self.answering = answering; self.menu = menu; self.items = items; self.more = more
        self.pressed = pressed; self.stale = stale; self.note = note
    }
}

/// One menu or item, as the Mac draws it.
public struct MacMenuItem: Codable, Hashable, Sendable {
    /// "3.4": the item's indexes from the menu bar, 0-based as Accessibility lists them (separators
    /// count; the Apple menu is 0, so the first mirrored menu is 1). Good within one version.
    public var id: String?
    public var title: String?
    /// A separator: no id, no title.
    public var separator: Bool?
    /// Nil counts as true.
    public var enabled: Bool?
    /// The Mac's mark: "✓" (on), "-" (mixed), or another single character an app set; nil unmarked.
    public var mark: String?
    /// The shortcut as the Mac draws it: "⇧⌘S", "⌃⌘←", "F5", "fn ⌃F". Display only: the device never
    /// makes it a key command of its own.
    public var key: String?
    /// Has items of its own, fetched with kind 27 when the device opens it.
    public var submenu: Bool?

    public init(id: String? = nil, title: String? = nil, separator: Bool? = nil, enabled: Bool? = nil,
                mark: String? = nil, key: String? = nil, submenu: Bool? = nil) {
        self.id = id; self.title = title; self.separator = separator; self.enabled = enabled
        self.mark = mark; self.key = key; self.submenu = submenu
    }
}

/// Device → host (kind 27). No `id`: the top level, and every later top level on this connection
/// (the subscription). With an `id`: that menu's current items, from a read of at most 1 s ago.
public struct FetchMenu: Codable, Hashable, Sendable {
    /// The version the id was shown in; ignored without an id.
    public var version: Int?
    public var id: String?
    /// The title the device showed for that menu. The host reads it only while the item at `id` still
    /// has this title (an app can add or remove items above a submenu in place, and an id is a place):
    /// otherwise, and without a title, the answer is "The menus changed…" and nothing is read. Never
    /// logged. Ignored without an id.
    public var title: String?
    public var token: Int?

    public init(version: Int? = nil, id: String? = nil, title: String? = nil, token: Int? = nil) {
        self.version = version; self.id = id; self.title = title; self.token = token
    }
}

/// Device → host (kind 25): choose one item.
public struct PressMenuItem: Codable, Hashable, Sendable {
    /// The version the id was shown in.
    public var version: Int?
    public var id: String?
    /// The title the device showed: the item is pressed only while its title is still this one, and
    /// never without one. Never logged: the host's lines give its own titles.
    public var title: String?
    public var token: Int?

    public init(version: Int? = nil, id: String? = nil, title: String? = nil, token: Int? = nil) {
        self.version = version; self.id = id; self.title = title; self.token = token
    }
}
