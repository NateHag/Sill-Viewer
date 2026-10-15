//! Keys as USB HID usages (what Sill hosts take) and Sill's input JSON.

use eframe::egui::{Key, Modifiers};
use serde_json::{json, Value};

pub const HID_CTRL: u32 = 0xE0;
pub const HID_SHIFT: u32 = 0xE1;
pub const HID_ALT: u32 = 0xE2;
pub const HID_CMD: u32 = 0xE3;

pub fn hid(key: Key) -> Option<u32> {
    use Key::*;
    let letters = [A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z];
    if let Some(i) = letters.iter().position(|k| *k == key) {
        return Some(0x04 + i as u32);
    }
    let nums = [Num1, Num2, Num3, Num4, Num5, Num6, Num7, Num8, Num9, Num0];
    if let Some(i) = nums.iter().position(|k| *k == key) {
        return Some(0x1E + i as u32);
    }
    let f = [F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12];
    if let Some(i) = f.iter().position(|k| *k == key) {
        return Some(0x3A + i as u32);
    }
    let f2 = [F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24];
    if let Some(i) = f2.iter().position(|k| *k == key) {
        return Some(0x68 + i as u32);
    }
    Some(match key {
        Enter => 0x28,
        Escape => 0x29,
        Backspace => 0x2A,
        Tab => 0x2B,
        Space => 0x2C,
        Minus => 0x2D,
        Equals | Plus => 0x2E,
        OpenBracket => 0x2F,
        CloseBracket => 0x30,
        Backslash | Pipe => 0x31,
        Semicolon | Colon => 0x33,
        Quote => 0x34,
        Backtick => 0x35,
        Comma => 0x36,
        Period => 0x37,
        Slash | Questionmark => 0x38,
        Insert => 0x49,
        Home => 0x4A,
        PageUp => 0x4B,
        Delete => 0x4C,
        End => 0x4D,
        PageDown => 0x4E,
        ArrowRight => 0x4F,
        ArrowLeft => 0x50,
        ArrowDown => 0x51,
        ArrowUp => 0x52,
        _ => return None,
    })
}

/// UIKeyModifierFlags bits, as Sill sends them.
pub fn flags(m: &Modifiers) -> u64 {
    let mut f = 0;
    if m.shift { f |= 0x20000 }
    if m.ctrl { f |= 0x40000 }
    if m.alt { f |= 0x80000 }
    if m.mac_cmd { f |= 0x100000 }
    f
}

pub fn key(usage: u32, down: bool, m: &Modifiers) -> Value {
    json!({"key": {"hidUsage": usage, "down": down, "modifiers": flags(m)}})
}

pub fn pointer(action: &str, x: f64, y: f64) -> Value {
    json!({"pointer": {"_0": action, "x": x, "y": y}})
}

pub fn scroll(x: f64, y: f64, dx: f64, dy: f64) -> Value {
    json!({"scroll": {"x": x, "y": y, "dx": dx, "dy": dy}})
}

pub fn scroll_phase(phase: &str, x: f64, y: f64) -> Value {
    json!({"scrollGesture": {"_0": phase, "x": x, "y": y}})
}

/// The modifier keys whose state changed, as (usage, down).
pub fn modifier_changes(old: &Modifiers, new: &Modifiers) -> Vec<(u32, bool)> {
    let mut out = Vec::new();
    for (was, is, usage) in [(old.shift, new.shift, HID_SHIFT), (old.ctrl, new.ctrl, HID_CTRL),
                             (old.alt, new.alt, HID_ALT), (old.mac_cmd, new.mac_cmd, HID_CMD)] {
        if was != is {
            out.push((usage, is));
        }
    }
    out
}
