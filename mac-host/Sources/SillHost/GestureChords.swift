import Foundation

// A trackpad gesture from a device (kind 28) as the Mac's own keyboard shortcut for its action
// (docs/trackpad-gestures-plan.md §7). The device names the gesture; this Mac decides what it does,
// from its own Keyboard Shortcuts as they are at that moment (SymbolicHotKeys reads them), so a
// shortcut changed there is followed and one turned off does nothing: never another action's
// shortcut, never a guess. It also remembers the view its last gesture opened, so the opposite
// gesture closes it, as on a Mac's trackpad, until something that can close the view comes from a
// device (a click, a key, text, a window picked, an app launched, one of the Mac's menu items
// chosen) or the last device leaves.
//
// Pure: Foundation only, checked on its own with swiftc (Tests/checks/gesture-chords; its
// `package` access needs -package-name). Nothing here posts anything: the coordinator posts the
// chord a `.chord` outcome names (InputInjector.chord), and a host that does not advertise posts
// none.

/// What a gesture does on the Mac.
package enum GestureAction: String, CaseIterable, Sendable {
    case missionControl, appExpose, nextSpace, previousSpace, apps, showDesktop

    /// For the log line: what the gesture reached.
    package var title: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .nextSpace: return "the Space on the right"
        case .previousSpace: return "the Space on the left"
        case .apps: return "Apps"
        case .showDesktop: return "Show Desktop"
        }
    }

    /// Its name in the Mac's Keyboard Shortcuts (System Settings › Keyboard), for the line that
    /// says none of its shortcuts is on.
    package var settingName: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appExpose: return "Application windows"
        case .nextSpace: return "Move right a space"
        case .previousSpace: return "Move left a space"
        case .apps: return "Show Apps"
        case .showDesktop: return "Show Desktop"
        }
    }

    /// A view that its own shortcut opens and, pressed again, closes: all but the Spaces.
    package var isView: Bool { self != .nextSpace && self != .previousSpace }
}

/// One of the window server's symbolic hotkeys, as it stores it: on or off, the Carbon virtual
/// keycode (`unbound` when none is set) and the modifier signature (CGEventFlags bits).
package struct HotKey: Equatable, Sendable {
    package var enabled: Bool
    package var keyCode: UInt16
    package var modifiers: UInt64

    package init(enabled: Bool, keyCode: UInt16, modifiers: UInt64) {
        self.enabled = enabled; self.keyCode = keyCode; self.modifiers = modifiers
    }

    /// The keycode of a hotkey with no key set.
    package static let unbound: UInt16 = 0xFFFF
}

/// What the Mac does with one gesture.
package enum GestureOutcome: Equatable, Sendable {
    /// Post this key down and up with exactly these flags: `action`'s shortcut `hotKey`.
    case chord(GestureAction, hotKey: Int, keyCode: UInt16, flags: UInt64)
    /// Post nothing, and why (for the log line). The action is nil for a name this Mac does not know.
    case nothing(GestureAction?, reason: String)
}

package struct GestureChords: Sendable {
    /// The shortcuts that perform each action, in order: the first that is on and bound wins. The
    /// Mission Control and Launchpad keys (160 and 131: 108, 115, 110 and 173) come first because no
    /// other shortcut shares them; the arrows with control and fn are also the window-tiling
    /// shortcuts' (Tile Left and Right Half), and the Spaces have no key of their own (§2.3).
    package static let preference: [GestureAction: [Int]] = [
        .missionControl: [108, 32],   // the Mission Control key; ⌃↑
        .appExpose: [115, 33],        // ⌃ and the Mission Control key; ⌃↓
        .nextSpace: [81],             // ⌃→, Move right a space
        .previousSpace: [79],         // ⌃←, Move left a space
        .apps: [173, 160],            // the Launchpad key; Show Apps (off and unbound as macOS ships it)
        .showDesktop: [36, 110],      // F11; ⌘ and the Mission Control key
    ]

    /// Every hotkey `preference` names, the ones to read from the Mac.
    package static let hotKeyIDs: [Int] = [108, 32, 115, 33, 81, 79, 173, 160, 36, 110]

    /// macOS 27's own values for them, as read on 2026-09-26 (§2.3), for a Mac whose getters are
    /// missing. The stored modifiers: fn 0x800000, control 0x040000, command 0x100000.
    package static let defaults: [Int: HotKey] = [
        108: HotKey(enabled: true, keyCode: 160, modifiers: 0x800000),
        32: HotKey(enabled: true, keyCode: 126, modifiers: 0x840000),
        115: HotKey(enabled: true, keyCode: 160, modifiers: 0x840000),
        33: HotKey(enabled: true, keyCode: 125, modifiers: 0x840000),
        81: HotKey(enabled: true, keyCode: 124, modifiers: 0x840000),
        79: HotKey(enabled: true, keyCode: 123, modifiers: 0x840000),
        173: HotKey(enabled: true, keyCode: 131, modifiers: 0x800000),
        160: HotKey(enabled: false, keyCode: HotKey.unbound, modifiers: 0),
        36: HotKey(enabled: true, keyCode: 103, modifiers: 0x800000),
        110: HotKey(enabled: true, keyCode: 160, modifiers: 0x900000),
    ]

    /// The flags a chord carries: the stored signature's device-independent bits (16–23: caps
    /// lock, shift, control, option, command, numeric pad, help, fn), nothing else.
    package static let deviceIndependentBits: UInt64 = 0x00FF_0000

    /// The view Sill's last gesture opened (Mission Control, App Exposé, Apps or Show Desktop), which
    /// its opposite gesture closes; nil when none is open, as far as Sill knows. The Mac's own
    /// keyboard and trackpad are not seen, so a view closed there still counts as open until a
    /// device's click, key or text (`input`), a device's pick or menu choice (`forget`), or the
    /// gesture that opened it made twice more (`repeated`).
    package private(set) var open: GestureAction?
    /// The gesture that opened `open` came again and did nothing, since the view is open. Made once
    /// more, straight after, Sill takes it that the view was closed where it cannot see (the Mac's own
    /// keyboard or trackpad) and opens it again: a view open for real stays open at the second try,
    /// as on a Mac, and one closed behind Sill's back comes back at the third.
    package private(set) var repeated = false

    package init() {}

    /// The gesture a view's opposite is: the swipe down closes Mission Control, the swipe up App
    /// Exposé, the spread Apps, the pinch Show Desktop (bringing the windows back).
    package static let closedBy: [GestureAction: String] = [
        .missionControl: "swipeDown", .appExpose: "swipeUp", .apps: "spread", .showDesktop: "pinch",
    ]

    /// The action a gesture name asks for before any view is open; nil for a name this Mac does not
    /// know. Natural direction: fingers moving left bring the Space on the right.
    package static func action(for gesture: String) -> GestureAction? {
        switch gesture {
        case "swipeUp": return .missionControl
        case "swipeDown": return .appExpose
        case "swipeLeft": return .nextSpace
        case "swipeRight": return .previousSpace
        case "pinch": return .apps
        case "spread": return .showDesktop
        default: return nil
        }
    }

    /// One gesture: what to post, if anything, with the Mac's table as it is now; `open` follows.
    /// With a view open, its opposite posts that view's shortcut again (each of them toggles) and
    /// forgets it; the gesture that opened it posts nothing, and made again right after that,
    /// posts its shortcut (`repeated`); a Space posts its own shortcut and leaves the view open; any
    /// other gesture posts its own and remembers its view instead. A shortcut that is off posts
    /// nothing and changes nothing.
    package mutating func resolve(_ gesture: String, table: [Int: HotKey]) -> GestureOutcome {
        let again = repeated
        repeated = false
        guard let base = Self.action(for: gesture) else {
            return .nothing(nil, reason: "not a gesture this Mac knows")
        }
        if let open, Self.closedBy[open] == gesture {
            let outcome = Self.chord(for: open, table: table)
            if case .chord = outcome { self.open = nil }
            return outcome
        }
        if let open, open == base, !again {
            repeated = true
            return .nothing(base, reason: "\(base.title) is already open")
        }
        let outcome = Self.chord(for: base, table: table)
        if case .chord = outcome, base.isView { open = base }
        return outcome
    }

    /// A device's input, as far as a view a gesture opened is concerned.
    package enum Input: Sendable {
        case pointerMove, buttonDown, buttonUp, scroll, keyDown, keyUp, text
    }

    /// A device's input (kind 8): a button or a key going down, or typed text, can close the view or
    /// act in it (a click in Mission Control picks a window and closes it, Esc closes any of them),
    /// so nothing counts as open after. Moving the pointer, scrolling (it pages through Apps, and
    /// closes none of them) and a button or key coming up leave it open, so the opposite gesture
    /// still closes it after a stroke that scrolled before it became a gesture.
    package mutating func input(_ input: Input) {
        switch input {
        case .buttonDown, .keyDown, .text: forget()
        case .pointerMove, .buttonUp, .scroll, .keyUp: break
        }
    }

    /// A device picked a window or launched an app (either comes forward on the Mac and closes the
    /// view), pressed a window's button or chose one of the Mac's menu items (as a click on it
    /// would), or the last device left (whoever comes next did not open it): nothing counts as open
    /// any more.
    package mutating func forget() {
        open = nil
        repeated = false
    }

    /// `action`'s first shortcut that is on and has a key, with its stored modifiers'
    /// device-independent bits; else nothing, never another action's shortcut.
    package static func chord(for action: GestureAction, table: [Int: HotKey]) -> GestureOutcome {
        for id in preference[action] ?? [] {
            guard let key = table[id], key.enabled, key.keyCode != HotKey.unbound else { continue }
            return .chord(action, hotKey: id, keyCode: key.keyCode, flags: key.modifiers & deviceIndependentBits)
        }
        return .nothing(action, reason: "no shortcut for \(action.settingName) is on in Keyboard Shortcuts")
    }

    // MARK: The log line

    /// "Gesture from iPad (iPad14,1): swipe up → Mission Control (shortcut 108: key 160, fn)", or
    /// "… swipe down → closes Mission Control (…)", or "… pinch → nothing: no shortcut for Show Apps
    /// is on in Keyboard Shortcuts". A host that posts nothing adds "(not posted: a test host)".
    /// `device` is already clean (the coordinator's names are); the gesture's name is the device's
    /// own text and is shown only as letters and digits, at most 32.
    package static func line(device: String, gesture: String, fingers: Int?, outcome: GestureOutcome,
                             dryRun: Bool) -> String {
        var what = spoken(gesture)
        if fingers == 4 { what += ", four fingers" }
        let result: String
        switch outcome {
        case .chord(let action, let id, let keyCode, let flags):
            // A view's shortcut from a gesture that is not its own closes it (the reversal).
            let closes = action.isView && Self.action(for: gesture) != action
            result = (closes ? "closes " : "") + action.title + " (shortcut \(id): " + describe(keyCode: keyCode, flags: flags) + ")"
                + (dryRun ? " (not posted: a test host)" : "")
        case .nothing(_, let reason):
            result = "nothing: " + reason
        }
        return "Gesture from \(device): \(what) → \(result)"
    }

    /// "swipe up", …; an unknown name quoted as letters and digits only.
    static func spoken(_ gesture: String) -> String {
        switch gesture {
        case "swipeUp": return "swipe up"
        case "swipeDown": return "swipe down"
        case "swipeLeft": return "swipe left"
        case "swipeRight": return "swipe right"
        case "pinch": return "pinch"
        case "spread": return "spread"
        default:
            var kept = String.UnicodeScalarView()
            for s in gesture.unicodeScalars where kept.count < 32 {
                let v = s.value
                if (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { kept.append(s) }
            }
            return "\"" + String(kept) + "\""
        }
    }

    /// "key 160, fn", "key 126, control + fn", "key 103" with no modifier.
    package static func describe(keyCode: UInt16, flags: UInt64) -> String {
        let held = modifierNames(flags)
        return "key \(keyCode)" + (held == "none" ? "" : ", " + held)
    }

    /// The modifiers a chord's key down carries that would change a click or a scroll if they stayed
    /// set after it: shift, control, option, command and fn (CGEventFlags; not caps lock, which a key
    /// down does not latch, nor the numeric pad and help bits).
    package static let modifierBits: UInt64 = 0x020000 | 0x040000 | 0x080000 | 0x100000 | 0x800000

    /// "control + fn", in the Mac's order (caps lock, control, option, shift, command, fn); "none".
    package static func modifierNames(_ flags: UInt64) -> String {
        let names: [(UInt64, String)] = [(0x010000, "caps lock"), (0x040000, "control"), (0x080000, "option"),
                                         (0x020000, "shift"), (0x100000, "command"), (0x800000, "fn")]
        let held = names.filter { flags & $0.0 != 0 }.map(\.1)
        return held.isEmpty ? "none" : held.joined(separator: " + ")
    }

    // MARK: TEST ONLY

    /// TEST ONLY (SILL_TEST_HOTKEYS, honoured only by a host that does not advertise): a table to use
    /// instead of this Mac's. "defaults" is `defaults`; otherwise entries separated by commas, each
    /// `ID=off` (turned off) or `ID=KEYCODE:MODIFIERS` (on, the modifiers in hex with 0x or decimal),
    /// laid over `defaults`. Nil for anything else.
    package static func testTable(_ spec: String) -> [Int: HotKey]? {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        if trimmed == "defaults" { return defaults }
        var table = defaults
        for entry in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2, let id = Int(parts[0]), id >= 0 else { return nil }
            if parts[1] == "off" {
                table[id] = HotKey(enabled: false, keyCode: table[id]?.keyCode ?? HotKey.unbound, modifiers: table[id]?.modifiers ?? 0)
                continue
            }
            let key = parts[1].split(separator: ":", omittingEmptySubsequences: false)
            guard key.count == 2, let code = UInt16(key[0]), let mods = number(String(key[1])) else { return nil }
            table[id] = HotKey(enabled: true, keyCode: code, modifiers: mods)
        }
        return table
    }

    private static func number(_ text: String) -> UInt64? {
        text.lowercased().hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }
}
