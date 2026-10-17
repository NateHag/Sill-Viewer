import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One address a person typed, pasted or scanned, as Sill dials it: a host (an IPv4 or IPv6
/// address, or a DNS name) and an optional port.
public struct ParsedAddress: Hashable, Sendable {
    public enum Kind: String, Sendable { case ipv4, ipv6, name }
    /// "100.101.102.103", "fd7a:115c:a1e0::1234" (no brackets, compressed, lowercase) or
    /// "mac-mini.tail1234.ts.net" (as typed).
    public var host: String
    /// Nil: the Mac's remote port applies (7455 when unknown).
    public var port: Int?
    public var kind: Kind

    public init(host: String, port: Int?, kind: Kind) {
        self.host = host; self.port = port; self.kind = kind
    }

    /// "host" or "host:port", with an IPv6 address in brackets: the form a pairing link's `a`
    /// carries and a person types back in.
    public var text: String {
        let h = kind == .ipv6 ? "[\(host)]" : host
        return port.map { "\(h):\($0)" } ?? h
    }
}

/// The strict parser for every address Sill takes from a person or a link (the Add a Mac card, a
/// pairing link's `a`, the Mac's address name, DEBUG -SillConnect). Strict because the system is
/// lenient in ways that dial the wrong machine: `NWEndpoint.Host` silently reads "1.2.3" as
/// 1.2.0.3, "100.1" as 100.0.0.1 and "0x64.0x65.1.2" as 100.101.1.2, and a pasted " 100.1.1.1"
/// with a space inside would become a DNS name. Pure: Foundation and `inet_pton`/`inet_aton`.
public enum AddressParser {
    /// Why an input was refused. The device words each one (the plan's §7.8).
    public enum Failure: Error, Equatable, Sendable {
        /// Nothing but whitespace.
        case empty
        /// Whitespace inside, or a character no address has.
        case malformed
        /// "fe80::1%en0": a zone only means something on the network it was copied from.
        case zone
        /// A dotted number that is not exactly four decimal octets 0–255 without leading zeros, or
        /// anything else `inet_aton` would read as an IPv4 address ("1.2.3", "0x64.0x65.1.2").
        case ipv4
        /// Brackets around something that is not an IPv6 address, or several colons that are not one.
        case ipv6
        /// Not a name under RFC 1123 (labels of 1–63 letters, digits and hyphens, not at either end
        /// of a label, 253 characters in all), or every label numeric.
        case name
        /// A port outside 1–65535, or not decimal digits.
        case port
        /// A `sill://` link: the caller hands the whole text to `PairLink.parse`.
        case pairingLink
    }

    /// Parses `raw`. The ends are trimmed first; anything else that is whitespace refuses it.
    public static func parse(_ raw: String) -> Result<ParsedAddress, Failure> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.empty) }
        if s.lowercased().hasPrefix("sill:") { return .failure(.pairingLink) }
        if s.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F }) {
            return .failure(.malformed)
        }
        if s.contains("%") { return .failure(.zone) }

        var hostPart: Substring
        var portPart: Substring?
        if s.hasPrefix("[") {
            // "[v6]" or "[v6]:port".
            guard let close = s.firstIndex(of: "]") else { return .failure(.ipv6) }
            hostPart = s[s.index(after: s.startIndex)..<close]
            let rest = s[s.index(after: close)...]
            if !rest.isEmpty {
                guard rest.first == ":" else { return .failure(.malformed) }
                portPart = rest.dropFirst()
            }
            guard let v6 = ipv6(hostPart) else { return .failure(.ipv6) }
            if let port = portPart {
                guard let p = parsePort(port) else { return .failure(.port) }
                return .success(v6.withPort(p))
            }
            return .success(v6)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons >= 2 {
            // Two or more colons and no brackets: a bare IPv6 address, never an address plus a
            // port, so "fd7a::1:7455" is the address fd7a::1:7455.
            guard let v6 = ipv6(Substring(s)) else { return .failure(.ipv6) }
            return .success(v6)
        }
        if colons == 1, let colon = s.firstIndex(of: ":") {
            hostPart = s[..<colon]
            portPart = s[s.index(after: colon)...]
        } else {
            hostPart = Substring(s)
        }
        let host: ParsedAddress
        switch hostOnly(hostPart) {
        case .success(let h): host = h
        case .failure(let f): return .failure(f)
        }
        if let port = portPart {
            guard let p = parsePort(port) else { return .failure(.port) }
            return .success(host.withPort(p))
        }
        return .success(host)
    }

    /// An IPv4 address or a name, no port.
    private static func hostOnly(_ h: Substring) -> Result<ParsedAddress, Failure> {
        if h.isEmpty { return .failure(.malformed) }
        let labels = h.hasSuffix(".") ? h.dropLast().split(separator: ".", omittingEmptySubsequences: false)
                                       : h.split(separator: ".", omittingEmptySubsequences: false)
        let allNumeric = !labels.isEmpty && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        if allNumeric {
            // Only exactly four decimal octets, each 0–255 without a leading zero, and no trailing dot.
            guard !h.hasSuffix("."), labels.count == 4,
                  labels.allSatisfy({ ($0 == "0" || $0.first != "0") && $0.count <= 3 && Int($0).map { $0 <= 255 } == true })
            else { return .failure(.ipv4) }
            return .success(ParsedAddress(host: String(h), port: nil, kind: .ipv4))
        }
        // Whatever inet_aton would take as an IPv4 address ("0x64.0x65.1.2", "0x1", "1.2.3") and
        // is not the canonical form above is refused: the system would dial the number, not a name.
        if acceptedByInetAton(String(h)) { return .failure(.ipv4) }
        guard isName(h) else { return .failure(.name) }
        return .success(ParsedAddress(host: String(h), port: nil, kind: .name))
    }

    /// RFC 1123 host name: labels of 1–63 ASCII letters, digits and hyphens, a hyphen at neither end
    /// of a label, at most 253 characters without the optional trailing dot. Single labels are
    /// allowed ("localhost", a MagicDNS short name).
    private static func isName(_ h: Substring) -> Bool {
        let body = h.hasSuffix(".") ? h.dropLast() : h
        guard !body.isEmpty, body.count <= 253 else { return false }
        for label in body.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        }
        return true
    }

    /// A bare IPv6 address (no brackets, no zone): its compressed lowercase form, or IPv4 for an
    /// IPv4-mapped one (::ffff:a.b.c.d), which is how the system would dial it anyway.
    private static func ipv6(_ h: Substring) -> ParsedAddress? {
        guard !h.isEmpty, !h.contains("%") else { return nil }
        var addr = in6_addr()
        guard String(h).withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return ParsedAddress(host: bytes[12...].map(String.init).joined(separator: "."), port: nil, kind: .ipv4)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return ParsedAddress(host: String(cString: buffer), port: nil, kind: .ipv6)
    }

    private static func acceptedByInetAton(_ h: String) -> Bool {
        var a = in_addr()
        return h.withCString { inet_aton($0, &a) } == 1
    }

    private static func parsePort(_ p: Substring) -> Int? {
        guard !p.isEmpty, p.count <= 5, p.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(p), (1...65535).contains(v) else { return nil }
        return v
    }
}

private extension ParsedAddress {
    func withPort(_ p: Int) -> ParsedAddress { ParsedAddress(host: host, port: p, kind: kind) }
}
