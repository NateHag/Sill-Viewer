import Foundation

// Compatibility between builds of the Mac and the device (docs/update-notice-plan.md §3): the
// device's hello (kind 23), the versions both ends compare, and the wire's generation. The rules of
// HostSettings.swift apply to every payload here (JSON only; fields added later are optional; no
// enums on the wire; never rename or retype a field), with three more:
//
// • A device's first message on a session connection is its hello. A host never assumes one
//   arrives: older devices send none.
// • `Goodbye.reason` is always sent (Remote.swift). A new reason carries a `message` that a device
//   from 2026-09-25 on can show as it is, and `reconnect`.
// • A refusal is kind 22 "update" with `"reconnect":false`, and nothing is sent before it.
//
// Pure: Foundation only, so it is checked on its own with swiftc.

/// The wire's generation. 1: the 14-byte header, kinds 0–23, and any later kind an older peer can
/// skip (24, 25 and 27, the Mac's menus: MacMenu.swift; 26, the Mac's pointer: Pointer.swift; 28,
/// the trackpad gesture: Gesture.swift; 32, the clipboard: Clipboard.swift, sent only to a peer that
/// said it takes it), and the JSON rules of HostSettings.swift, inside TLS 1.3
/// with both keys pinned at both doors, whose session protocol is the ALPN `sill/1`
/// (RemoteTLS.sessionALPN): the home door pairs as the remote door does, as the first public builds
/// ship it (docs/home-pairing-plan.md; the plain home door is development builds' and the CLI's).
/// Raised only by a change an older peer cannot skip (a new transport, a kind or rule it cannot
/// skip); an additive change never raises it. When it rises, a later session ALPN (`sill/2`) goes
/// beside `sill/1` and `sill-pair/1`, which every host offers for good (RemoteTLS.serverALPNs), and
/// the host's device floor rises with it (DeviceGate, docs/update-notice-plan.md §4.6): a device
/// from the first public build speaks only `sill/1`, and hears kind 22 "update" only inside it, so a
/// host that no longer serves it still completes that handshake, reads its hello through the gate
/// and refuses it with "update".
public enum SillProtocol {
    public static let current = 1
}

/// A version as tags, bundles and the wire write it: "v0.4.0", "0.4.0", "0.4", "1.2.3-beta.1".
///
/// Parsing: surrounding whitespace is trimmed and one leading "v" or "V" dropped; then the longest
/// prefix of ASCII digits and dots is kept, without the dots at its end. It must start with a digit,
/// and split on "." it must have at most 8 parts of 1–9 digits each; anything else is no version.
/// What follows the prefix is ignored: "1.2.3-beta.1" is 1.2.3 (a prerelease is GitHub's flag, not
/// the tag's suffix, and App Store versions are numeric), "0.3.0 (85)" is 0.3.0.
///
/// Compared part by part, a missing part counting as 0: "0.10" > "0.9", "1.0.1" > "1.0", and
/// "v0.4.0" == "0.4". Shown with at least two parts and no trailing zeros beyond them: 0.4.0 is
/// "0.4", 1 is "1.0", 1.0.1 is "1.0.1".
public struct SillVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// The parts, trailing zeros dropped, so "0.4" and "0.4.0" are equal; empty is 0.
    public let components: [Int]

    public init?(_ text: String) {
        func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }   // ASCII only
        var scalars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        if let first = scalars.first, first == "v" || first == "V" { scalars.removeFirst() }
        var prefix: [Unicode.Scalar] = []
        for s in scalars {
            guard isDigit(s) || s == "." else { break }
            prefix.append(s)
        }
        while prefix.last == "." { prefix.removeLast() }
        guard let first = prefix.first, isDigit(first) else { return nil }
        var digits = String.UnicodeScalarView()
        digits.append(contentsOf: prefix)
        let parts = String(digits).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 8 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...9).contains(part.count), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        self.init(components: numbers)
    }

    /// Any parts; trailing zeros are dropped.
    public init(components: [Int]) {
        var c = components
        while c.last == 0 { c.removeLast() }
        self.components = c
    }

    /// 0: what a device that sends no version counts as.
    public static let zero = SillVersion(components: [])

    public var description: String {
        var c = components
        while c.count < 2 { c.append(0) }
        return c.map(String.init).joined(separator: ".")
    }

    public static func < (a: SillVersion, b: SillVersion) -> Bool {
        for i in 0..<max(a.components.count, b.components.count) {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// Kind 23: the first message of every session connection a device makes (home door, remote door,
/// a move's network connection), written straight to that connection before anything else, so a
/// host can judge the device before it sends it anything (DeviceGate). Never on a pairing
/// connection, whose one message is kind 19. All four fields are optional: `{}` decodes, so a host
/// never fails on a thin hello.
public struct Hello: Codable, Sendable, Equatable {
    /// CFBundleShortVersionString: "1.0" (the iOS project's MARKETING_VERSION). What a host's floor
    /// compares (DeviceGate).
    public var appVersion: String?
    /// CFBundleVersion: "42". Logged only.
    public var build: String?
    /// SillProtocol.current: 1. Logged only in this build. The JSON key is "protocol".
    public var `protocol`: Int?
    /// "iPad (iPad14,1)", as ClientStats.device. The host cleans it (SafeText.label).
    public var device: String?

    public init(appVersion: String? = nil, build: String? = nil, protocol: Int? = nil, device: String? = nil) {
        self.appVersion = appVersion; self.build = build; self.protocol = `protocol`; self.device = device
    }
}
