import Foundation
import StreamProtocol

// The Mac's menus (docs/menu-bar-plan.md §4.2): the mirror's decisions as values, so they can be
// checked without Accessibility. Pure: Foundation and StreamProtocol (the cache keeps the items a
// device is sent), checked on its own with swiftc (Tests/checks/menus).

/// One menu's items as last read, per id, with the title the menu had then. AppKit validates a menu
/// when it is read and throttles that to about once a second per menu (measured): a read within the
/// second returns the state computed at the last one. So the cache answers only where a read now
/// would return the same thing: a read of less than a second ago made while the app was frontmost
/// answers any fetch; one made while it was not (an inactive app's states) answers only while the
/// app is still not frontmost. Once the app has been brought forward, the menu is read again when
/// `revalidation` has passed since that read, so that AppKit validates it anew for an active app.
/// And only a fetch that shows the menu under the title it was read under: an id is a place, and
/// what a device asks for is the menu it was shown there.
package struct MenuCache {
    /// A read answers fetches for this long.
    package static let lifetime = 1.0
    /// AppKit validates a menu again only after about a second: the probe's reads 0.43 and 0.83 s
    /// after a validation got none, 1.03, 1.29 and 1.83 s after did.
    package static let revalidation = 1.05

    package struct Entry: Equatable {
        /// The menu's own title when it was read (the item that opens it, as a device is shown it).
        package let title: String
        package let items: [MacMenuItem]
        package let more: Int
        package let at: Double
        package let appWasFrontmost: Bool
        package init(title: String, items: [MacMenuItem], more: Int, at: Double, appWasFrontmost: Bool) {
            self.title = title; self.items = items; self.more = more; self.at = at; self.appWasFrontmost = appWasFrontmost
        }
    }

    private var entries: [String: Entry] = [:]

    package init() {}

    package mutating func store(_ id: String, _ entry: Entry) { entries[id] = entry }

    /// An entry to answer from: read less than `lifetime` ago while the app was frontmost; or while
    /// it was not, when `frontmostNow` is false too (AppKit would answer a read now from that same
    /// validation). Asked with `frontmostNow: true` before the app is brought forward, and again
    /// after with what that found. Only for `title`, the one the menu was read under.
    package func fresh(_ id: String, title: String, now: Double, frontmostNow: Bool) -> Entry? {
        guard let e = entries[id], ShownTitle.matches(now: e.title, shown: title), now - e.at < Self.lifetime,
              e.appWasFrontmost || !frontmostNow else { return nil }
        return e
    }

    /// How long to wait before reading `id` again, the app now frontmost: the rest of
    /// `revalidation` after a read made while it was not (a read sooner would return that inactive
    /// validation); else 0.
    package func wait(_ id: String, now: Double) -> Double {
        guard let e = entries[id], !e.appWasFrontmost, now - e.at < Self.revalidation else { return 0 }
        return Self.revalidation - (now - e.at)
    }

    package mutating func clear() { entries = [:] }
    package var isEmpty: Bool { entries.isEmpty }
}

/// Whether the item at an id is still the one a device was shown there: its title now (as a device is
/// shown it, `MenuFormat.displayTitle`) is the one the device showed. An empty or missing title never
/// matches: no device was shown one. A fetch's menu and a choice's item are judged by this.
package enum ShownTitle {
    package static func matches(now: String?, shown: String?) -> Bool {
        guard let now, !now.isEmpty else { return false }
        return now == shown
    }
}

/// How long a device waits for the answer to a fetch: 4 s, or four of its worst recent round trips
/// on a slow link (the device's MacMenuState rule 6, as a settings pick waits). The host knows the
/// round trip from the connection's client stats, once a second. Requests are served one at a time,
/// so a fetch can wait its turn behind others (a pointer sweeping the iPad's bar opens a menu at a
/// time, and a slow app takes a while each): one whose answer could no longer reach its device in
/// time is not read at all, since the device has settled it and drops the answer, and a read stops
/// in time for its answer to arrive. A choice has no timeout on the device, and one whose turn comes
/// that late is refused rather than made seconds after it was chosen.
package enum RequestDeadline {
    package static let deviceWait = 4.0
    /// An answer is sent at least this long before it would reach its device too late.
    package static let margin = 0.1

    /// The device's wait, from the connection's worst round trip of a recent second, in ms (nil or
    /// negative: none measured yet).
    package static func wait(rttMs: Int?) -> Double { max(deviceWait, 4 * seconds(rttMs)) }

    /// How long after a request arrived its answer can still go out: the device's wait, less one
    /// round trip (its clock started half of one before the request arrived, and the answer takes
    /// the other half) and `margin`.
    package static func answerBy(rttMs: Int?) -> Double { wait(rttMs: rttMs) - seconds(rttMs) - margin }

    /// Whether a request that has waited `waited` seconds for its turn is past `answerBy`.
    package static func expired(waited: Double, rttMs: Int?) -> Bool { waited >= answerBy(rttMs: rttMs) }

    private static func seconds(_ rttMs: Int?) -> Double { Double(max(0, rttMs ?? 0)) / 1000 }
}

/// The submenus read in the current tree version: at each id, the title a device was shown for it.
/// An id is a place (Accessibility's child indexes), and an app can add or remove items above a
/// submenu in place, which moves no top-level title: within one version an id must still name one
/// item for every device (docs/menu-bar-plan.md §3.3), so a read that finds, among the places it
/// covers, another title where a submenu was read, or no submenu there, means the tree changed under
/// the version, and the version moves (the mirror's `treeChanged`). Leaves are not recorded: nothing
/// is read below them, and a choice checks its own title. At most `limit` places: past that the
/// version moves too, and the record starts again.
package struct SubmenuRecord {
    package static let limit = 20_000
    /// By the menu's id, each submenu's title by its index there.
    private var byMenu: [String: [Int: String]] = [:]
    package private(set) var count = 0

    package init() {}

    /// A read of the menu `menu` found these items among its first `examined` children: each one's
    /// index, the title a device is shown, and whether it opens a menu. False when a submenu recorded
    /// at one of those places is not there now, or not under its title: the tree changed, and
    /// nothing is recorded. Otherwise every submenu found is recorded.
    package mutating func read(menu: String, found: [(index: Int, title: String, submenu: Bool)], examined: Int) -> Bool {
        let recorded = byMenu[menu] ?? [:]
        var now: [Int: String] = [:]
        for f in found where f.submenu && now[f.index] == nil { now[f.index] = f.title }
        for (index, title) in recorded where index < examined && now[index] != title { return false }
        let merged = recorded.merging(now) { _, new in new }
        let added = merged.count - recorded.count
        guard count + added <= Self.limit else { return false }
        count += added
        byMenu[menu] = merged
        return true
    }

    /// The title recorded for the submenu at `id` ("4.21"), or nil: none read there in this version
    /// (or `id` is one of the bar's menus, which the top level has).
    package func title(of id: String) -> String? {
        guard let dot = id.lastIndex(of: "."), let index = Int(id[id.index(after: dot)...]) else { return nil }
        return byMenu[String(id[..<dot])]?[index]
    }

    package mutating func clear() { byMenu = [:]; count = 0 }
}

/// Each connection's requests of the last second: at most 20 fetches and 4 presses (a sweep across
/// the iPad's bar opens a menu at a time; a person chooses far fewer), and one "ignored" line a
/// second at most. What is refused does not count.
package struct RequestRate {
    package static let fetchesPerSecond = 20, pressesPerSecond = 4

    private var fetches: [Double] = []
    private var presses: [Double] = []
    private var lastIgnoredLine: Double?

    package init() {}

    package mutating func allowFetch(now: Double) -> Bool { Self.allow(&fetches, limit: Self.fetchesPerSecond, now: now) }
    package mutating func allowPress(now: Double) -> Bool { Self.allow(&presses, limit: Self.pressesPerSecond, now: now) }

    /// True at most once a second: whether an "ignored" line may print now.
    package mutating func ignoredLineDue(now: Double) -> Bool {
        if let last = lastIgnoredLine, now - last < 1 { return false }
        lastIgnoredLine = now
        return true
    }

    private static func allow(_ arrivals: inout [Double], limit: Int, now: Double) -> Bool {
        arrivals.removeAll { now - $0 >= 1 }
        guard arrivals.count < limit else { return false }
        arrivals.append(now)
        return true
    }
}

/// The bar's menus as last read: only a change here (with the app's own change) moves the version.
package struct TopLevel: Equatable {
    package var titles: [String]
    package var enabled: [Bool]
    package init(titles: [String], enabled: [Bool]) { self.titles = titles; self.enabled = enabled }
}

/// Why a fetch or a press was not served: the words the device shows (`note`), and the log line's.
package enum MenuRefusal: Equatable {
    /// The item is disabled.
    case disabled
    /// Another version, an id that names nothing, or an item whose title is not the one shown.
    case changed
    /// The app quit.
    case gone
    /// The app did not answer Accessibility within the timeout (or is shown stale meanwhile).
    case notAnswering
    /// This Mac has not given Sill Accessibility.
    case notTrusted
    /// Over `RequestRate`'s limits.
    case tooMany
    /// A choice whose turn came this many seconds after it arrived, past its device's wait
    /// (`RequestDeadline`): refused rather than made so late.
    case late(Double)
    /// Any other Accessibility error, by its name.
    case failed(String)

    package static let changedNote = "The menus changed. Open the menu again."
    package static let unavailableNote = "It isn’t available right now."
    package static let tooManyNote = "Too many requests. Open the menu again."
    package static let noAccessNote = "Allow Accessibility for Sill on the Mac (System Settings › Privacy & Security › Accessibility)."
    package static func notRespondingNote(_ app: String) -> String { "\(app) isn’t responding." }
    package static func goneNote(_ app: String) -> String { "\(app) is no longer open." }

    /// What the device shows as it is.
    package func note(app: String) -> String {
        switch self {
        case .disabled, .failed: Self.unavailableNote
        case .changed: Self.changedNote
        case .gone: Self.goneNote(app)
        case .notAnswering: Self.notRespondingNote(app)
        case .notTrusted: Self.noAccessNote
        case .tooMany, .late: Self.tooManyNote
        }
    }

    /// The end of the host's "Menu from … refused: …" line.
    package func logReason(app: String) -> String {
        switch self {
        case .disabled: "disabled"
        case .changed: "the menus changed"
        case .gone: "\(app) is no longer open"
        case .notAnswering: "\(app) is not answering Accessibility"
        case .notTrusted: "no Accessibility permission"
        case .tooMany: "too many requests"
        case .late(let waited): "it waited \(String(format: "%.1f", waited)) s behind other requests"
        case .failed(let error): "Accessibility refused it (\(error))"
        }
    }
}

package enum PressDecision: Equatable {
    /// The kept element, its title still the one shown.
    case press
    /// Found again by its path, its title the one shown.
    case pressFound
    case refuse(MenuRefusal)

    /// `elementValid`: the kept element answered; `current`: the item's title now (the kept
    /// element's, or the one found at the path; nil: nothing there); `shown`: the device's;
    /// `enabled`: its AXEnabled; `hasChildren`: it has a submenu (or a custom view's children).
    /// In order:
    /// 1. The title now must be the one shown, for a kept element as for one found again: a
    ///    delegate that fills its menu with `menu:updateItem:atIndex:shouldCancel:` keeps its
    ///    NSMenuItems and rewrites them, so after the validation the press's own read sets off the
    ///    same element can stand for another command. An empty or missing title never matches: no
    ///    device was shown one. An item retitled meanwhile ("Undo Typing" → "Undo Paste") is
    ///    refused too, which is what a device that showed the old title should hear.
    /// 2. A leaf only: AXPress on an item with children opens its menu on the Mac, and the app then
    ///    sits in menu tracking until someone closes it.
    /// 3. Enabled: a disabled item is refused (after the title, so a retitled and disabled item
    ///    reads as changed).
    package static func decide(elementValid: Bool, current: String?, shown: String?, enabled: Bool?,
                               hasChildren: Bool) -> PressDecision {
        guard ShownTitle.matches(now: current, shown: shown) else { return .refuse(.changed) }
        if hasChildren { return .refuse(.changed) }
        if enabled == false { return .refuse(.disabled) }
        return elementValid ? .press : .pressFound
    }
}

/// The host's own words for an item in a log line: the app, then each menu on the way and the item,
/// "Code › File › Save", each cleaned to SafeText's 64 characters. Nil when any is unknown: the line
/// then gives the id.
package enum MenuLog {
    package static func path(app: String, titles: [String?]) -> String? {
        var parts = [SafeText.label(app)]
        for t in titles {
            guard let t else { return nil }
            let clean = SafeText.label(t)
            guard !clean.isEmpty else { return nil }
            parts.append(clean)
        }
        return parts.joined(separator: " › ")
    }
}
