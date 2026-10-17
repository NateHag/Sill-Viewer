import Foundation

/// Where a connection comes from, told from its addresses and the interface it arrived on, and
/// which door admits it (docs/remote-access-plan.md §4.4). The home door (plain TCP, Bonjour)
/// serves only loopback, link-local (AWDL included) and this Mac's own networks; the remote door
/// (TLS, paired devices) also serves VPNs, and internet sources only with the Mac's internet switch.
///
/// Defence in depth, not the boundary: a router that source-NATs or hairpins a port forward makes
/// an internet peer look like `lan`. Pairing is the boundary.
///
/// Pure (Foundation and inet_pton only), so it is checked on its own with swiftc. The live
/// interface table comes from `InterfaceSnapshot`.
enum OriginPolicy {
    enum Origin: String, Sendable {
        case loopback, direct, vpn, lan, internet
    }

    enum InterfaceKind: Sendable {
        case loopback, lan, tunnel, peerToPeer, other
    }

    /// A snapshot of the Mac's interfaces, as `classify` needs it.
    struct Interfaces: Sendable {
        /// "en0": .lan, "utun4": .tunnel, "awdl0": .peerToPeer.
        var kind: [String: InterfaceKind] = [:]
        /// A local address (4 or 16 bytes) → the interface that owns it.
        var owner: [[UInt8]: String] = [:]
        /// On-link prefixes of the interfaces that are not tunnels or loopback.
        var prefixes: [(interface: String, network: [UInt8], bits: Int)] = []

        init(kind: [String: InterfaceKind] = [:], owner: [[UInt8]: String] = [:],
             prefixes: [(interface: String, network: [UInt8], bits: Int)] = []) {
            self.kind = kind; self.owner = owner; self.prefixes = prefixes
        }
    }

    /// An interface's kind from its name (and whether it is point-to-point): the peer-to-peer Wi-Fi
    /// interfaces (awdl, llw) before anything else, then tunnels (utun, ipsec, ppp, tun, tap, wg,
    /// feth, zt, or any point-to-point link), then the LAN ones (en, bridge, anpi, anri).
    static func interfaceKind(name: String, pointToPoint: Bool = false, loopback: Bool = false) -> InterfaceKind {
        if loopback || name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return .peerToPeer }
        if pointToPoint || ["utun", "ipsec", "ppp", "tun", "tap", "wg", "feth", "zt"].contains(where: { name.hasPrefix($0) }) { return .tunnel }
        if ["en", "bridge", "anpi", "anri"].contains(where: { name.hasPrefix($0) }) { return .lan }
        return .other
    }

    /// Classifies a source. `remote` and `localAddress` are address strings (a zone after "%" and
    /// brackets are ignored); `scope` is the interface a link-local source is scoped to, when the
    /// endpoint says. First match wins:
    /// 1. an IPv4-mapped IPv6 source is its IPv4 address;
    /// 2. 127/8 or ::1 → loopback;
    /// 3. the arrival interface is the scope, else the owner of the local address, else unknown;
    /// 4. arrival on peer-to-peer Wi-Fi → direct;
    /// 5. arrival on a tunnel → vpn;
    /// 6. otherwise (a LAN interface or an unknown one): a link-local source, a source inside an
    ///    on-link prefix of that interface (of any LAN interface when unknown), or a private one
    ///    (RFC 1918, ULA: a VPN that ends on the home router) → lan; 100.64/10 that is not on-link
    ///    (carrier space from outside) and anything else → internet.
    static func classify(remote: String, localAddress: String?, scope: String?, interfaces: Interfaces) -> Origin {
        guard let source = IPBytes.parse(remote) else { return .internet }
        if IPBytes.isLoopback(source) { return .loopback }
        let arrival = arrivalInterface(localAddress: localAddress, scope: scope, interfaces: interfaces)
        let kind = arrival.map { interfaces.kind[$0] ?? interfaceKind(name: $0) }
        switch kind {
        case .peerToPeer: return .direct
        case .tunnel: return .vpn
        default: break
        }
        if IPBytes.isLinkLocal(source) { return .lan }
        // That interface's own prefixes when it is known (a LAN interface, or one of no known
        // kind); every LAN interface's when it is not (or when it is loopback, which no
        // non-loopback source really arrives on).
        let own = arrival.flatMap { a in kind == .lan || kind == .other ? a : nil }
        let onLink = interfaces.prefixes.contains { p in
            let candidate = own.map { p.interface == $0 } ?? ((interfaces.kind[p.interface] ?? interfaceKind(name: p.interface)) == .lan)
            return candidate && IPBytes.contains(network: p.network, bits: p.bits, address: source)
        }
        if onLink || IPBytes.isPrivate(source) { return .lan }
        return .internet
    }

    /// The interface a connection arrived on: the scope of a link-local source when it has one,
    /// else the interface that owns the local address it arrived at, else unknown.
    static func arrivalInterface(localAddress: String?, scope: String?, interfaces: Interfaces) -> String? {
        if let scope, !scope.isEmpty { return scope }
        return localAddress.flatMap(IPBytes.parse).flatMap { interfaces.owner[$0] }
    }

    /// The home door: loopback, direct (AWDL: Direct Wireless) and this Mac's own networks.
    static func homeAdmits(_ o: Origin) -> Bool {
        o == .loopback || o == .direct || o == .lan
    }

    /// The remote door: loopback, this Mac's networks and VPNs; the internet only with the Mac's
    /// switch; never peer-to-peer (Direct Wireless is the home door's).
    static func remoteAdmits(_ o: Origin, internetAccess: Bool) -> Bool {
        switch o {
        case .loopback, .lan, .vpn: return true
        case .internet: return internetAccess
        case .direct: return false
        }
    }

    /// How the Mac's card and log name a remote route: "through Tailscale" (the VPN service's own
    /// name when known), "through your VPN", "over the internet", "by address" (this network, or
    /// loopback). Nil for the home door's own origins that never reach the remote door.
    static func label(_ o: Origin, interface: String?, serviceName: String?) -> String? {
        switch o {
        case .vpn:
            if let serviceName, !serviceName.isEmpty { return "through \(serviceName)" }
            return "through your VPN"
        case .internet: return "over the internet"
        case .lan, .loopback: return "by address"
        case .direct: return nil
        }
    }

    /// The interface a link-local endpoint is scoped to, from its description: "awdl0" from
    /// "fe80::1%awdl0.52397" (Network prints the port after a dot) or "[fe80::1%awdl0]:52397". Nil
    /// without a scope (IPv4, a global IPv6 address) and for a numeric one ("%16"). The same rule as
    /// ClientLink.scope, kept here so that this file is checked on its own.
    static func scope(ofEndpoint description: String) -> String? {
        guard let percent = description.firstIndex(of: "%") else { return nil }
        let name = description[description.index(after: percent)...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard let first = name.first, first.isLetter else { return nil }
        return String(name)
    }
}

/// Addresses as raw bytes (4 for IPv4, 16 for IPv6), with the few tests the policy needs.
enum IPBytes {
    /// Parses "10.0.0.5", "fe80::1%en0", "[fd7a::1]" or "::ffff:1.2.3.4" (which becomes 4 bytes).
    static func parse(_ text: String) -> [UInt8]? {
        var s = text
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        var v4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        guard s.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return nil }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return Array(b[12...]) }
        return b
    }

    static func isLoopback(_ a: [UInt8]) -> Bool {
        a.count == 4 ? a[0] == 127 : a == [UInt8](repeating: 0, count: 15) + [1]
    }

    /// 169.254/16 or fe80::/10.
    static func isLinkLocal(_ a: [UInt8]) -> Bool {
        a.count == 4 ? (a[0] == 169 && a[1] == 254) : (a[0] == 0xFE && a[1] & 0xC0 == 0x80)
    }

    /// An IPv4-mapped IPv6 address (::ffff:a.b.c.d) as its 4 IPv4 bytes; any other address as it is.
    static func unmapped(_ a: [UInt8]) -> [UInt8] {
        guard a.count == 16, a[0..<10].allSatisfy({ $0 == 0 }), a[10] == 0xFF, a[11] == 0xFF else { return a }
        return Array(a[12...])
    }

    /// An IPv6 link-local address with bytes 2–3 cleared, where the kernel embeds the scope in
    /// the addresses getifaddrs returns (InterfaceSnapshot stores them so); any other address as
    /// it is. Comparing a source with this Mac's own addresses goes through it on both sides.
    static func unscoped(_ a: [UInt8]) -> [UInt8] {
        guard a.count == 16, isLinkLocal(a) else { return a }
        var b = a
        b[2] = 0; b[3] = 0
        return b
    }

    /// RFC 1918 (10/8, 172.16/12, 192.168/16) or a unique local IPv6 address (fc00::/7).
    static func isPrivate(_ a: [UInt8]) -> Bool {
        if a.count == 4 { return a[0] == 10 || (a[0] == 172 && a[1] & 0xF0 == 16) || (a[0] == 192 && a[1] == 168) }
        return a[0] & 0xFE == 0xFC
    }

    /// 100.64/10, shared address space (carrier NAT, and Tailscale's own range).
    static func isCarrierShared(_ a: [UInt8]) -> Bool {
        a.count == 4 && a[0] == 100 && a[1] & 0xC0 == 64
    }

    static func contains(network: [UInt8], bits: Int, address: [UInt8]) -> Bool {
        guard network.count == address.count, bits >= 0, bits <= network.count * 8 else { return false }
        var remaining = bits
        for i in 0..<network.count where remaining > 0 {
            let mask: UInt8 = remaining >= 8 ? 0xFF : UInt8(truncatingIfNeeded: 0xFF << (8 - remaining))
            if network[i] & mask != address[i] & mask { return false }
            remaining -= 8
        }
        return true
    }

    /// "10.0.0.5" or "fd7a::1" (compressed).
    static func text(_ a: [UInt8]) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if a.count == 4 {
            var v4 = in_addr(); withUnsafeMutableBytes(of: &v4) { $0.copyBytes(from: a) }
            return inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)).map { String(cString: $0) } ?? ""
        }
        guard a.count == 16 else { return "" }
        var v6 = in6_addr(); withUnsafeMutableBytes(of: &v6) { $0.copyBytes(from: a) }
        return inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)).map { String(cString: $0) } ?? ""
    }
}
