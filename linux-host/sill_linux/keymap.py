"""USB HID keyboard usages (what the iPad sends) to Linux evdev key codes (what GNOME takes)."""

_LETTERS = [30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44]

HID_TO_EVDEV = {0x04 + i: code for i, code in enumerate(_LETTERS)}
HID_TO_EVDEV.update({0x1E + i: 2 + i for i in range(10)})          # 1..9, 0
HID_TO_EVDEV.update({
    0x28: 28, 0x29: 1, 0x2A: 14, 0x2B: 15, 0x2C: 57, 0x2D: 12, 0x2E: 13, 0x2F: 26, 0x30: 27, 0x31: 43,
    0x32: 43, 0x33: 39, 0x34: 40, 0x35: 41, 0x36: 51, 0x37: 52, 0x38: 53, 0x39: 58,
    0x3A: 59, 0x3B: 60, 0x3C: 61, 0x3D: 62, 0x3E: 63, 0x3F: 64, 0x40: 65, 0x41: 66, 0x42: 67, 0x43: 68,
    0x44: 87, 0x45: 88,
    0x46: 99, 0x47: 70, 0x48: 119, 0x49: 110, 0x4A: 102, 0x4B: 104, 0x4C: 111, 0x4D: 107, 0x4E: 109,
    0x4F: 106, 0x50: 105, 0x51: 108, 0x52: 103,
    0x53: 69, 0x54: 98, 0x55: 55, 0x56: 74, 0x57: 78, 0x58: 96, 0x59: 79, 0x5A: 80, 0x5B: 81, 0x5C: 75,
    0x5D: 76, 0x5E: 77, 0x5F: 71, 0x60: 72, 0x61: 73, 0x62: 82, 0x63: 83, 0x64: 86, 0x65: 127, 0x66: 116,
    0x67: 117,
    0x7F: 113, 0x80: 115, 0x81: 114,
    0x87: 89, 0x88: 93, 0x89: 124, 0x8A: 92, 0x8B: 94, 0x90: 122, 0x91: 123,
    0xE0: 29, 0xE1: 42, 0xE2: 56, 0xE3: 125, 0xE4: 97, 0xE5: 54, 0xE6: 100, 0xE7: 126,
})
HID_TO_EVDEV.update({0x68 + i: 183 + i for i in range(12)})        # F13..F24

KEY_ENTER, KEY_TAB, KEY_BACKSPACE = 28, 15, 14
MODIFIER_CODES = {29, 42, 56, 125, 97, 54, 100, 126}


def evdev_code(hid_usage, command_key="ctrl"):
    """The evdev code for a HID usage, or None. command_key: what the Mac Command key becomes on
    Linux: "ctrl" (Cmd+C copies, as on a Mac) or "super" (the GNOME Activities key)."""
    if command_key == "ctrl" and hid_usage in (0xE3, 0xE7):
        return 29 if hid_usage == 0xE3 else 97
    return HID_TO_EVDEV.get(hid_usage)


def keysym_for(ch):
    """X11 keysym for one Unicode character."""
    cp = ord(ch)
    if 0x20 <= cp <= 0x7E or 0xA0 <= cp <= 0xFF:
        return cp
    return 0x01000000 + cp
