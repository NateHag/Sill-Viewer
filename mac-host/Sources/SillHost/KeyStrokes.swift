import Foundation
import StreamProtocol

// A device's key (kind 8's `.key`: a USB HID usage going down or up, with UIKeyModifierFlags bits) as
// the keyboard events InputInjector posts for it: the Mac's virtual key, and the flags each carries.
// Beside it, the check a quarter of a second after each key's up (`KeyUpCheck`) and what of the input
// with nowhere to land still goes (`DroppedInput`).
//
// The flags are what a keyboard would give (2026-09-27, the stuck command after Spotlight). The Mac
// keeps the modifier state of the source InputInjector posts from in the HID system's state table:
// each keyboard event posted leaves its flags there (CGEventSource.h: the source's "accumulated
// information on modifier flag state", placed in effect by posting events), and every pointer and
// scroll event made from the source afterwards starts from them. A device sends a shortcut as one
// key down and up, each carrying its modifiers (the Spotlight key's ⌘Space, the key row's ⌘esc, a
// latched ⌘S), not with the modifier's own key pressed around it as a keyboard does; posted as it
// came, the up left command in the table, and the next tap was a ⌘-click until typed text (posted
// with no flags) cleared it. So:
//   - a key's down carries the modifiers its device sent and whatever modifier keys are down (a
//     Mac with two keyboards does the same): the shortcut acts on the down;
//   - a key's up carries only the modifiers the modifier keys down hold, never its chord's own;
//   - a modifier's own key (a latched modifier pressed around a click, a hardware keyboard's) is a
//     flags-changed event with what is held once it is down or up: never its own flag after its up
//     (unless the same modifier's other key is down), whatever the device said;
//   - a device's key or text saying it no longer holds a modifier lets go of that modifier's key
//     first (a device from before this fix never sent a hardware ⌘'s release);
//   - a device that leaves has every key it still holds down let go, and so does the host at its end
//     (Sill.app's Quit, and a signal: the CLI's default path lets go of them and then dies of it);
//   - a trackpad gesture's shortcut (`chord`) goes down with its own flags and up with those the table
//     held before it.
// Pointer and scroll events are made from the source as before, so they start from what is held.
// Inferred, not observed: nothing may be posted while this is built, so every key's up is checked a
// quarter of a second later (`KeyUpCheck`). Typed text is InputInjector's: it goes out with no flags,
// after `text` has let go of the device's modifier keys.
//
// Pure: Foundation and StreamProtocol only, checked on its own with swiftc (Tests/checks/key-strokes;
// its `package` access needs -package-name sill). Nothing here posts anything: InputInjector makes
// each event from its source and posts it.

/// One keyboard event to post: a virtual key (Carbon's kVK_*) going down or up, carrying these flags
/// (CGEventFlags bits). A modifier's own key (54 to 62) becomes a flags-changed event: CoreGraphics
/// makes one for those keycodes.
package struct KeyStroke: Equatable, Sendable {
    package var virtualKey: UInt16
    package var down: Bool
    package var flags: UInt64

    package init(virtualKey: UInt16, down: Bool, flags: UInt64) {
        self.virtualKey = virtualKey; self.down = down; self.flags = flags
    }
}

package struct KeyStrokes: Sendable {
    /// A device's connection (the ObjectIdentifier of its NWConnection): whose key is down.
    package typealias Device = ObjectIdentifier

    /// Every key whose down went to the Mac and whose up has not, with the device that pressed it
    /// (the last to, if two did). Only usages with a Mac key (`virtualKeys`), so at most 82.
    package private(set) var down: [UInt16: Device] = [:]

    package init() {}

    /// The flags the modifier keys down hold between them.
    package var heldFlags: UInt64 { down.keys.reduce(0) { $0 | (Self.modifierKeys[$1] ?? 0) } }

    /// Whether `usage`'s down went to the Mac and its up has not.
    package func isDown(_ usage: UInt16) -> Bool { down[usage] != nil }

    /// A device's key: the events to post, in order, or nil for a usage no Mac key answers to (the
    /// injector drops it and counts it; nothing changes). First the ups of this device's modifier keys
    /// that `modifiers` no longer has (but this key), then the key: a modifier key with what is held
    /// once it is down or up, any other key's down with the device's modifiers and what is held, and
    /// its up with what is held.
    package mutating func key(usage: UInt16, down isDown: Bool, modifiers: UInt64, from device: Device) -> [KeyStroke]? {
        guard let virtualKey = Self.virtualKeys[usage] else { return nil }
        let said = Self.flags(fromDevice: modifiers)
        var strokes = letGo(of: device, keeping: said, except: usage)
        let flags: UInt64
        if Self.modifierKeys[usage] != nil {
            down[usage] = isDown ? device : nil
            flags = heldFlags
        } else if isDown {
            down[usage] = device
            flags = said | heldFlags
        } else {
            down[usage] = nil
            flags = heldFlags
        }
        strokes.append(KeyStroke(virtualKey: virtualKey, down: isDown, flags: flags))
        return strokes
    }

    /// Text from a device, which InputInjector types with no flags: the events to post first. A
    /// device types text only while it holds no ⌘, ⌃ or ⌥ (those make its keys shortcuts) and never
    /// holds a modifier's own key for it, so its modifier keys still down go up.
    package mutating func text(from device: Device) -> [KeyStroke] {
        letGo(of: device, keeping: 0, except: nil)
    }

    /// A device left (its connection closed): the ups of every key it still holds down, its other
    /// keys first with what is still held, then its modifier keys, each leaving the rest. A key
    /// another device pressed last stays down.
    package mutating func release(_ device: Device) -> [KeyStroke] { letGoOfKeys { $0 == device } }

    /// The host is going (the app's Quit, a signal): the ups of every key down, whoever pressed it, in
    /// `release`'s order, so no modifier outlives Sill on the Mac.
    package mutating func releaseAll() -> [KeyStroke] { letGoOfKeys { _ in true } }

    private mutating func letGoOfKeys(pressedBy owner: (Device) -> Bool) -> [KeyStroke] {
        var strokes: [KeyStroke] = []
        for usage in down.keys.sorted() where Self.modifierKeys[usage] == nil {
            guard let who = down[usage], owner(who) else { continue }
            down[usage] = nil
            strokes.append(KeyStroke(virtualKey: Self.virtualKeys[usage] ?? 0, down: false, flags: heldFlags))
        }
        for usage in down.keys.sorted(by: >) where Self.modifierKeys[usage] != nil {
            guard let who = down[usage], owner(who) else { continue }
            down[usage] = nil
            strokes.append(KeyStroke(virtualKey: Self.virtualKeys[usage] ?? 0, down: false, flags: heldFlags))
        }
        return strokes
    }

    /// A trackpad gesture's shortcut (InputInjector.chord, GestureChords): its key down with exactly
    /// the flags the Mac stored for it (fn included; no other modifier, or it would be another
    /// shortcut), and its up with `before`, the flags the HID state table held just before the chord
    /// (what the devices' modifier keys hold, and the Mac's own keyboard), so the chord leaves none of
    /// its own. The key is none of a device's, and goes down and up at once.
    package static func chord(virtualKey: UInt16, flags: UInt64, before: UInt64) -> [KeyStroke] {
        [KeyStroke(virtualKey: virtualKey, down: true, flags: flags),
         KeyStroke(virtualKey: virtualKey, down: false, flags: before)]
    }

    /// The ups of `device`'s modifier keys down whose flag `keeping` lacks, `except` left alone: from
    /// 0xE7 down (the right-hand keys, then command, option, shift and control: the reverse of the
    /// order the trackpad presses them in), each with what is held after it.
    private mutating func letGo(of device: Device, keeping: UInt64, except: UInt16?) -> [KeyStroke] {
        var strokes: [KeyStroke] = []
        for usage in down.keys.sorted(by: >) where usage != except && down[usage] == device {
            guard let flag = Self.modifierKeys[usage], keeping & flag == 0 else { continue }
            down[usage] = nil
            strokes.append(KeyStroke(virtualKey: Self.virtualKeys[usage] ?? 0, down: false, flags: heldFlags))
        }
        return strokes
    }

    /// "command", "control + shift" (in the Mac's order: caps lock, control, option, shift,
    /// command), or "none": for the log.
    package static func names(_ flags: UInt64) -> String {
        let named: [(UInt64, String)] = [(capsLock, "caps lock"), (control, "control"), (option, "option"),
                                         (shift, "shift"), (command, "command")]
        let held = named.filter { flags & $0.0 != 0 }.map(\.1)
        return held.isEmpty ? "none" : held.joined(separator: " + ")
    }

    /// The modifiers' own keys (HID usages 0xE0 to 0xE7: left and right control, shift, option and
    /// command) and the flag each holds while down.
    package static let modifierKeys: [UInt16: UInt64] = [
        0xE0: control, 0xE1: shift, 0xE2: option, 0xE3: command,
        0xE4: control, 0xE5: shift, 0xE6: option, 0xE7: command,
    ]

    /// The client sends UIKeyModifierFlags bits. They sit at the same bit positions as the
    /// CGEventFlags masks, but build the flags explicitly rather than reinterpreting the number:
    /// anything else in there (numeric pad, iOS-only bits) has no business reaching the Mac.
    package static func flags(fromDevice modifiers: UInt64) -> UInt64 {
        var flags: UInt64 = 0
        if modifiers & (1 << 16) != 0 { flags |= capsLock }
        if modifiers & (1 << 17) != 0 { flags |= shift }
        if modifiers & (1 << 18) != 0 { flags |= control }
        if modifiers & (1 << 19) != 0 { flags |= option }
        if modifiers & (1 << 20) != 0 { flags |= command }
        return flags
    }

    /// CGEventFlags' masks, as plain bits (CoreGraphics is not imported here): maskAlphaShift,
    /// maskShift, maskControl, maskAlternate, maskCommand.
    package static let capsLock: UInt64 = 0x01_0000
    package static let shift: UInt64 = 0x02_0000
    package static let control: UInt64 = 0x04_0000
    package static let option: UInt64 = 0x08_0000
    package static let command: UInt64 = 0x10_0000

    /// USB HID usage (UIKeyboardHIDUsage on the client) → macOS virtual keycode (Carbon kVK_*).
    /// Only the keys a phone keyboard can send; anything else is dropped and counted.
    package static let virtualKeys: [UInt16: UInt16] = [
        // Letters, 0x04…0x1D = A…Z
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3, 0x0A: 5, 0x0B: 4, 0x0C: 34,
        0x0D: 38, 0x0E: 40, 0x0F: 37, 0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12,
        0x15: 15, 0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7, 0x1C: 16, 0x1D: 6,
        // Digits, 0x1E…0x27 = 1…9 then 0
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23, 0x23: 22, 0x24: 26, 0x25: 28,
        0x26: 25, 0x27: 29,
        // Editing and punctuation
        0x28: 36,   // Return
        0x29: 53,   // Escape
        0x2A: 51,   // Delete (backspace)
        0x2B: 48,   // Tab
        0x2C: 49,   // Space
        0x2D: 27,   // -
        0x2E: 24,   // =
        0x2F: 33,   // [
        0x30: 30,   // ]
        0x31: 42,   // \
        0x33: 41,   // ;
        0x34: 39,   // '
        0x35: 50,   // `
        0x36: 43,   // ,
        0x37: 47,   // .
        0x38: 44,   // /
        0x39: 57,   // Caps Lock
        // F1…F12
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97,
        0x40: 98, 0x41: 100, 0x42: 101, 0x43: 109, 0x44: 103, 0x45: 111,
        // Navigation
        0x4A: 115,  // Home
        0x4B: 116,  // Page Up
        0x4C: 117,  // Forward Delete
        0x4D: 119,  // End
        0x4E: 121,  // Page Down
        0x4F: 124,  // Right
        0x50: 123,  // Left
        0x51: 125,  // Down
        0x52: 126,  // Up
        // Modifiers, in case the client sends them as keys as well as flags
        0xE0: 59,   // Left Control
        0xE1: 56,   // Left Shift
        0xE2: 58,   // Left Option
        0xE3: 55,   // Left Command
        0xE4: 62,   // Right Control
        0xE5: 60,   // Right Shift
        0xE6: 61,   // Right Option
        0xE7: 54,   // Right Command
    ]
}

/// The check a quarter of a second after a key's up (InputInjector, `in.keyModifiersLeft`): whether
/// the up took out of the HID state table the modifiers its down put there, as KeyStrokes' flags infer
/// it does. Every key's up is judged, whichever path made it: a modifier's own key (this device's
/// Spotlight key, the key row and a latched ⌘S press ⌘ around the key; the trackpad around a click; a
/// hardware ⌘), a shortcut's key (an older device's ⌘Space, whose up takes command out), and the ups
/// KeyStrokes makes itself (a lost release, a device that left). A device test then shows at once,
/// in the log, a key whose up did not put the table back. As the gestures' chords are checked
/// (InputInjector.checkModifiersLeft, #38).
package struct KeyUpCheck: Sendable {
    /// Each key whose down went to the Mac and whose up has not (by its Mac keycode, which names one
    /// key: KeyStrokes' table has no two alike): the modifiers the down carried, and those the table
    /// held that this host had not put there (the Mac's own keyboard), which its up leaves alone.
    private var downs: [UInt16: (carried: UInt64, outside: UInt64)] = [:]
    /// The checks armed and not read yet, by number, with the modifiers each reads for. A down meanwhile
    /// that finds them in the table cannot tell an up that left them from the Mac's own keyboard, and
    /// takes them for this host's: taken for the Mac's own, its up would go unchecked.
    private var unread: [Int: UInt64] = [:]
    private var armed = 0

    package init() {}

    /// A stroke about to be posted: `table` is the HID state table's flags read just before it (only
    /// a down's are used) and `posted` those of the last keyboard event this host posted. For an up
    /// whose post should take modifiers out of the table, the check to read later: its number and
    /// those modifiers, the ones its down carried that it does not, and that were not the Mac's own
    /// before the down. Nil for a down, and for an up that leaves every modifier where it is (Space's
    /// up while ⌘'s key is still down).
    package mutating func posting(_ stroke: KeyStroke, table: UInt64, posted: UInt64) -> (id: Int, cleared: UInt64)? {
        if stroke.down {
            let unreadFlags = unread.values.reduce(0, |)
            downs[stroke.virtualKey] = (stroke.flags & Self.modifiers, table & ~posted & ~unreadFlags & Self.modifiers)
            return nil
        }
        guard let down = downs.removeValue(forKey: stroke.virtualKey) else { return nil }
        let cleared = down.carried & ~stroke.flags & ~down.outside
        guard cleared != 0 else { return nil }
        armed += 1
        unread[armed] = cleared
        return (armed, cleared)
    }

    /// The read of check `id`, a quarter of a second after its up, with the table's flags now: what
    /// it still holds that it should not (`left`). The check is done.
    package mutating func read(_ id: Int, table: UInt64, posted: UInt64, held: UInt64) -> UInt64 {
        guard let cleared = unread.removeValue(forKey: id) else { return 0 }
        return Self.left(cleared, table: table, posted: posted, held: held)
    }

    /// Of `cleared`, what the table (`table`) still holds that neither the last keyboard event posted
    /// since (`posted`: a modifier pressed again meanwhile) nor a modifier key down on the Mac (`held`)
    /// accounts for. Not 0: the up did not put the table back.
    package static func left(_ cleared: UInt64, table: UInt64, posted: UInt64, held: UInt64) -> UInt64 {
        table & cleared & ~posted & ~held
    }

    /// Shift, control, option and command: the modifiers that change a click or a scroll.
    package static let modifiers = KeyStrokes.shift | KeyStrokes.control | KeyStrokes.option | KeyStrokes.command
}

/// Input with nowhere to land (StreamCoordinator): nothing streams (between sources, or the stream
/// stopped: the window closed under a drag), or a switch dropped what was held for an activation.
/// It is dropped, all but the up of a key or a button the Mac has down (its down was posted, its up
/// has not been), which still goes, a button's where the pointer is: a modifier left down makes every
/// later click a ⌘-click, and a button left down every later move a drag.
package enum DroppedInput {
    /// Whether `event` still goes: a key's up when `keyDown` says that key is down on the Mac, a
    /// button's up when that button is (`leftDown`, `rightDown`). Downs, moves, scrolls, text and a
    /// scroll gesture's boundaries never do (InputInjector's scroll watchdog closes a gesture left
    /// open).
    package static func stillGoes(_ event: InputEvent, keyDown: (UInt16) -> Bool, leftDown: Bool, rightDown: Bool) -> Bool {
        switch event {
        case .key(let usage, false, _): return keyDown(usage)
        case .pointer(.leftUp, _, _): return leftDown
        case .pointer(.rightUp, _, _): return rightDown
        default: return false
        }
    }
}
