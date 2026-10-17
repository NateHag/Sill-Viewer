import Foundation

/// Text a device supplies about itself (its name and model in ClientStats and in a PairRequest)
/// before it reaches a log line, the Mac's status, its menu or its Settings. A device is free to
/// send anything: newlines that forge log lines, bidirectional overrides that make "iPad" read as
/// something else, or a megabyte of name. Shared, so the host and the device clean it the same way.
public enum SafeText {
    /// The longest label kept, in characters (grapheme clusters).
    public static let labelLimit = 64

    /// `text` as a one-line label: whitespace of every kind (tabs, newlines, line and paragraph
    /// separators, no-break and ideographic spaces) becomes one space, other control and format
    /// characters are removed (the bidirectional overrides and isolates U+202A–202E and
    /// U+2066–2069 among them, and zero-width characters), runs of spaces collapse to one, the ends
    /// are trimmed, and at most `limit` characters are kept. Empty when nothing printable was sent:
    /// the caller then shows something of its own (the device's address).
    public static func label(_ text: String, limit: Int = labelLimit) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for s in text.unicodeScalars {
            if s.properties.isWhitespace || s.properties.generalCategory == .lineSeparator
                || s.properties.generalCategory == .paragraphSeparator {
                pendingSpace = !scalars.isEmpty
                continue
            }
            switch s.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned:
                continue
            default:
                break
            }
            if pendingSpace { scalars.append(" "); pendingSpace = false }
            scalars.append(s)
        }
        var out = String(scalars)
        if out.count > limit {
            // By characters, so a letter and its combining marks or an emoji stay whole.
            out = String(out.prefix(limit))
            while out.last == " " { out.removeLast() }
        }
        return out
    }
}
