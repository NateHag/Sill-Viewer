import Foundation
import StreamProtocol

// The Mac's menus (docs/menu-bar-plan.md §4.1): what Accessibility gives for one menu item, turned
// into what a device is sent (MacMenuItem, kind 24), and the ids that name items. Pure: Foundation
// and StreamProtocol, checked on its own with swiftc (Tests/checks/menus), which its `package`
// access needs -package-name for.

/// What Accessibility gave for one menu item, before anything is decided about it.
package struct RawMenuItem: Equatable {
    /// Nil: no AXTitle at all (NoValue); "" is a separator's.
    package var title: String?
    /// AXDescription (setAccessibilityLabel).
    package var description: String?
    package var enabled: Bool?
    /// AXMenuItemMarkChar.
    package var mark: String?
    /// AXMenuItemCmdChar.
    package var char: String?
    /// AXMenuItemCmdModifiers.
    package var modifiers: Int?
    /// AXMenuItemCmdVirtualKey.
    package var virtualKey: Int?
    /// AXMenuItemCmdGlyph.
    package var glyph: Int?
    package var childCount: Int
    /// "AXMenu" for a submenu.
    package var firstChildRole: String?

    package init(title: String? = nil, description: String? = nil, enabled: Bool? = nil, mark: String? = nil,
                 char: String? = nil, modifiers: Int? = nil, virtualKey: Int? = nil, glyph: Int? = nil,
                 childCount: Int = 0, firstChildRole: String? = nil) {
        self.title = title; self.description = description; self.enabled = enabled; self.mark = mark
        self.char = char; self.modifiers = modifiers; self.virtualKey = virtualKey; self.glyph = glyph
        self.childCount = childCount; self.firstChildRole = firstChildRole
    }
}

package enum MenuFormat {
    /// A title's longest, in characters (SafeText.label); a log line's are SafeText's 64.
    package static let titleLimit = 100
    /// A shortcut's longest, in characters: a longer one is not shown.
    package static let keyLimit = 16

    /// The item as the device gets it, or nil for one it never shows. In order:
    /// 1. A separator: a title of "" (empty, not missing), disabled, with no children. An enabled
    ///    item titled "" is not one: it is an image-only item, and rule 2 decides it.
    /// 2. The title: `displayTitle`. Empty after that: nil (a custom view such as Finder's Tags, an
    ///    image-only item, an untitled item with no description).
    /// 3. A submenu: children, the first an AXMenu. Children of any other role (a custom view's): nil.
    /// 4. Enabled: false only when Accessibility said false; a missing value counts as enabled.
    /// 5. The mark: its first character, cleaned ("✓", "-", "•"); nil when missing or empty.
    /// 6. The key: `shortcut`, nil when there is none.
    package static func item(_ raw: RawMenuItem, id: String) -> MacMenuItem? {
        if raw.title == "", raw.enabled == false, raw.childCount == 0 { return MacMenuItem(separator: true) }
        let title = displayTitle(title: raw.title, description: raw.description)
        guard !title.isEmpty else { return nil }
        var submenu = false
        if raw.childCount > 0 {
            guard raw.firstChildRole == "AXMenu" else { return nil }
            submenu = true
        }
        let mark = SafeText.label(raw.mark ?? "", limit: 1)
        return MacMenuItem(id: id, title: title, enabled: raw.enabled == false ? false : nil,
                           mark: mark.isEmpty ? nil : mark,
                           key: shortcut(char: raw.char, modifiers: raw.modifiers, virtualKey: raw.virtualKey, glyph: raw.glyph),
                           submenu: submenu ? true : nil)
    }

    /// One of the bar's menus (the top level), or nil when it has no title to show. Every one is a
    /// submenu, fetched when the device opens it.
    package static func topItem(_ raw: RawMenuItem, index: Int) -> MacMenuItem? {
        let title = displayTitle(title: raw.title, description: raw.description)
        guard !title.isEmpty else { return nil }
        return MacMenuItem(id: "\(index)", title: title, enabled: raw.enabled == false ? false : nil, submenu: true)
    }

    /// The title a device is shown, and the one a press found again by its path is compared with:
    /// AXTitle, else AXDescription (Chrome's untitled bookmarks), one clean line of at most 100
    /// characters. A title of "" stays "": an image-only item's description does not stand in.
    package static func displayTitle(title: String?, description: String?) -> String {
        SafeText.label(title ?? description ?? "", limit: titleLimit)
    }

    /// The shortcut as the Mac draws it, or nil for none. The key, first match wins: the glyph when
    /// it has a name in `glyphs`; else the character (a special one from `characters`, U+F704–U+F726
    /// as F1–F35, any other private-use character as no key at all, a printable one as itself, as
    /// Accessibility gives it: uppercase letters, as the Mac draws them); else the virtual key from
    /// `virtualKeys`. A glyph not in the table (dictation's 150) falls to its character ("🎤").
    /// Then the modifiers in Apple's order: "fn " (bit 16), ⌃ (4), ⌥ (2), ⇧ (1), then ⌘ unless
    /// bit 8 (no Command) is set. Modifiers alone decide nothing: every item has them (0 or 8).
    /// At most `keyLimit` characters, else nil.
    package static func shortcut(char: String?, modifiers: Int?, virtualKey: Int?, glyph: Int?) -> String? {
        let char = (char?.isEmpty ?? true) ? nil : char
        guard char != nil || virtualKey != nil || glyph != nil else { return nil }
        var key: String?
        if let glyph, let name = glyphs[glyph] {
            key = name
        } else if let char {
            if let name = characters[char] {
                key = name
            } else if let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1,
                      (0xF704...0xF726).contains(scalar.value) {
                key = "F\(scalar.value - 0xF704 + 1)"
            } else if char.unicodeScalars.contains(where: { $0.properties.generalCategory == .privateUse }) {
                return nil                   // a function key with no name here: nothing readable remains
            } else {
                let printable = SafeText.label(char, limit: keyLimit + 1)
                if !printable.isEmpty { key = printable }
            }
        }
        if key == nil, let virtualKey, let name = virtualKeys[virtualKey] { key = name }
        guard let key else { return nil }
        let m = modifiers ?? 0
        var text = ""
        if m & 16 != 0 { text += "fn " }
        if m & 4 != 0 { text += "⌃" }
        if m & 2 != 0 { text += "⌥" }
        if m & 1 != 0 { text += "⇧" }
        if m & 8 == 0 { text += "⌘" }
        text += key
        return text.count <= keyLimit ? text : nil
    }

    /// AXMenuItemCmdChar's special characters.
    package static let characters: [String: String] = [
        "\u{8}": "⌫", "\u{7f}": "⌫", "\u{1b}": "⎋", "\r": "↩", "\u{3}": "⌤", "\t": "⇥", " ": "Space",
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\u{F728}": "⌦",
        "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
    ]

    /// AXMenuItemCmdGlyph: Carbon's Menus.h glyph codes.
    package static let glyphs: [Int: String] = {
        var g: [Int: String] = [2: "⇥", 4: "⌤", 9: "Space", 10: "⌦", 11: "↩", 23: "⌫", 27: "⎋", 28: "⌧", 98: "⇞",
                                100: "←", 101: "→", 102: "↖", 104: "↑", 105: "↘", 106: "↓", 107: "⇟"]
        for n in 1...12 { g[110 + n] = "F\(n)" }           // 111–122: F1–F12
        for n in 13...15 { g[122 + n] = "F\(n)" }          // 135–137: F13–F15
        return g
    }()

    /// AXMenuItemCmdVirtualKey: Events.h key codes.
    package static let virtualKeys: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12",
    ]
}

/// An id: an item's indexes from the menu bar, "3.4.1", as Accessibility lists them (separators
/// count). The first is at least 1 (0 is the Apple menu, never mirrored); 1 to 8 parts of 1 to 4
/// ASCII digits, without leading zeros, so each item has exactly one id.
package struct MenuPath: Hashable {
    package static let maxDepth = 8
    package let indexes: [Int]

    package init?(_ id: String) {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...Self.maxDepth).contains(parts.count) else { return nil }
        var indexes: [Int] = []
        for part in parts {
            guard (1...4).contains(part.count),
                  part.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
                  part == "0" || part.first != "0",
                  let n = Int(part) else { return nil }
            indexes.append(n)
        }
        guard indexes[0] >= 1 else { return nil }
        self.indexes = indexes
    }

    package init?(indexes: [Int]) {
        guard (1...Self.maxDepth).contains(indexes.count), indexes[0] >= 1,
              indexes.allSatisfy({ (0...9999).contains($0) }) else { return nil }
        self.indexes = indexes
    }

    package var id: String { indexes.map(String.init).joined(separator: ".") }
    /// The menu it is in: nil for one of the bar's menus.
    package var parent: MenuPath? { indexes.count > 1 ? MenuPath(indexes: Array(indexes.dropLast())) : nil }
    /// An item of this menu; nil past the depth or index limits.
    package func child(_ i: Int) -> MenuPath? { MenuPath(indexes: indexes + [i]) }
    /// Every menu on the way from the bar, this one last: "4.21.0" → 4, 4.21, 4.21.0.
    package var lineage: [MenuPath] {
        (1...indexes.count).compactMap { MenuPath(indexes: Array(indexes.prefix($0))) }
    }
}
