import Foundation

/// The Mac's Keyboard Shortcuts as the window server keeps them (its "symbolic hotkeys"), read
/// through SkyLight's two getters for the ids a trackpad gesture can use (GestureChords.hotKeyIDs),
/// at each gesture: a few microseconds, and a shortcut changed while a device is connected is
/// followed. Read-only: nothing here sets a hotkey, posts an event or asks for a permission.
///
/// Private, as the CGVirtualDisplay the host already uses is: `CGSGetSymbolicHotKeyValue` and
/// `CGSIsSymbolicHotKeyEnabled`, looked up with `dlsym` in the already loaded SkyLight. A macOS
/// without them gets nil, and the coordinator uses `GestureChords.defaults` (macOS 27's own values)
/// and says so once.
enum SymbolicHotKeys {
    /// `CGError CGSGetSymbolicHotKeyValue(CGSSymbolicHotKey, unichar *keyEquivalent,
    /// unichar *virtualKeyCode, CGSModifierFlags *modifiers)`; the flags are an unsigned long.
    private typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>,
                                                 UnsafeMutablePointer<UInt64>) -> Int32
    /// `bool CGSIsSymbolicHotKeyEnabled(CGSSymbolicHotKey)`.
    private typealias IsEnabled = @convention(c) (Int32) -> Bool

    private static let getters: (value: GetValue, enabled: IsEnabled)? = {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else { return nil }
        guard let value = dlsym(sky, "CGSGetSymbolicHotKeyValue"),
              let enabled = dlsym(sky, "CGSIsSymbolicHotKeyEnabled") else { return nil }
        return (unsafeBitCast(value, to: GetValue.self), unsafeBitCast(enabled, to: IsEnabled.self))
    }()

    /// Each id the window server answers for: on or off, its virtual keycode (65535 when no key is
    /// set) and its stored modifiers. An id it has no value for is left out, which the resolver
    /// takes as not on. Nil when the getters are missing.
    static func read(_ ids: [Int]) -> [Int: HotKey]? {
        guard let getters else { return nil }
        var table: [Int: HotKey] = [:]
        for id in ids {
            var character: UInt16 = 0, keyCode: UInt16 = 0, modifiers: UInt64 = 0
            guard getters.value(Int32(id), &character, &keyCode, &modifiers) == 0 else { continue }
            table[id] = HotKey(enabled: getters.enabled(Int32(id)), keyCode: keyCode, modifiers: modifiers)
        }
        return table
    }
}
