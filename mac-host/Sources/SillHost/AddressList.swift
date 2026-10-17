import Foundation
import StreamProtocol

/// Which of the Mac's addresses a device away from home can dial, in dial order
/// (docs/remote-access-plan.md §4.8). Pure: Reachability reads the system (SystemConfiguration,
/// getifaddrs, the MagicDNS lookup, the router) and hands the facts in; this decides. Checked on
/// its own with swiftc against fixtures shaped like Noah's dynamic store.
///
/// Shown: a named network service on a tunnel (its addresses, kind "vpn", via its name; 100.64/10
/// only there, and Tailscale's fd7a:115c:a1e0::/48), a point-to-point interface that no named
/// service covers but has a routable IPv4 ("VPN (utun6)"; Tailscale from the App Store has a
/// service with no Setup: key, so no name), and the primary Wi‑Fi or Ethernet service's IPv4
/// (kind "lan"). Hidden: loopback and link-local, peer-to-peer (awdl, llw, nan), unnamed tunnels
/// (utun0–3, the CoreDevice tunnel's ULA), temporary and deprecated IPv6, LAN ULAs. With the
/// internet switch on, then: the address name (with its own port), the router's IPv4 and one
/// stable global IPv6.
enum AddressList {
    /// An IPv6 address with its interface flags (IN6_IFF_*).
    struct IPv6Entry: Equatable, Sendable {
        var address: String
        var flags: Int
        static let temporary = 0x80, deprecated = 0x10
    }

    /// One network service, as SCDynamicStore reports it.
    struct Service: Equatable, Sendable {
        var id: String
        /// Its UserDefinedName ("Wi-Fi", "Tailscale", a WireGuard tunnel's own name); "" for none.
        var name: String
        var interface: String
        var ipv4: [String]
        var ipv6: [IPv6Entry]
        /// Its DNS SupplementalMatchDomains ("tail1234.ts.net."), for the MagicDNS name.
        var matchDomains: [String] = []
    }

    /// A point-to-point interface that is not a network service (Tunnelblick, ZeroTier).
    struct Tunnel: Equatable, Sendable {
        var interface: String
        var ipv4: [String]
    }

    struct Input: Sendable {
        var services: [Service] = []
        /// The interface of the primary service (State:/Network/Global/IPv4); a tunnel when a VPN
        /// exit node carries the default route.
        var primaryInterface: String?
        var tunnels: [Tunnel] = []
        /// Service ID → its MagicDNS name, only when it resolved to the tunnel's own address.
        var magicDNS: [String: String] = [:]
        var internet = false
        var addressName: ParsedAddress?
        var routerIPv4: String?
        /// TEST ONLY: a host that does not advertise lists 127.0.0.1 first, so the simulator can
        /// reach it.
        var testLoopback = false
    }

    static let maxCount = 12

    static func build(_ input: Input) -> [MacAddress] {
        var out: [MacAddress] = []
        func add(_ a: MacAddress) {
            guard out.count < maxCount, !out.contains(where: { $0.host.lowercased() == a.host.lowercased() && $0.port == a.port }) else { return }
            out.append(a)
        }
        if input.testLoopback { add(MacAddress(host: "127.0.0.1", kind: MacAddress.lan, via: "This Mac")) }
        let vpns = vpnServices(input.services)
        for s in vpns { if let name = input.magicDNS[s.id] { add(MacAddress(host: name, kind: MacAddress.vpn, via: s.name)) } }
        for s in vpns { for a in s.ipv4 where routableV4(a, onTunnel: true) { add(MacAddress(host: a, kind: MacAddress.vpn, via: s.name)) } }
        for t in input.tunnels.sorted(by: { $0.interface < $1.interface }) where !vpns.contains(where: { $0.interface == t.interface }) {
            for a in t.ipv4 where routableV4(a, onTunnel: true) { add(MacAddress(host: a, kind: MacAddress.vpn, via: "VPN (\(t.interface))")) }
        }
        for s in vpns { for e in s.ipv6 where usableV6(e) && !isLinkLocalV6(e.address) { add(MacAddress(host: e.address, kind: MacAddress.vpn, via: s.name)) } }
        if let lan = primaryLAN(input), let a = lan.ipv4.first(where: { routableV4($0, onTunnel: false) }) {
            add(MacAddress(host: a, kind: MacAddress.lan, via: lan.name.isEmpty ? lan.interface : lan.name))
        }
        if input.internet {
            if let name = input.addressName {
                add(MacAddress(host: name.host, port: name.port, kind: MacAddress.internet, via: "Address name"))
            }
            if let r = input.routerIPv4 { add(MacAddress(host: r, kind: MacAddress.internet, via: "Router")) }
            if let v6 = stableGlobalV6(input) { add(MacAddress(host: v6, kind: MacAddress.internet, via: "IPv6")) }
        }
        return out
    }

    /// Named services on tunnels that have at least one routable address, by name.
    static func vpnServices(_ services: [Service]) -> [Service] {
        services.filter { !$0.name.isEmpty && isTunnel($0.interface) }
            .sorted { ($0.name, $0.interface) < ($1.name, $1.interface) }
    }

    /// The primary Wi‑Fi or Ethernet service: the one on the primary interface when that is a LAN
    /// interface, else the first LAN service with a routable IPv4 (a VPN exit node can make a
    /// tunnel primary; the LAN is still there).
    static func primaryLAN(_ input: Input) -> Service? {
        let lans = input.services.filter { isLAN($0.interface) && $0.ipv4.contains(where: { routableV4($0, onTunnel: false) }) }
            .sorted { ($0.interface, $0.name) < ($1.interface, $1.name) }
        return lans.first { $0.interface == input.primaryInterface } ?? lans.first
    }

    /// This network's IPv4, for the port-forward instruction and the typed pairing path.
    static func lanAddress(_ input: Input) -> String? {
        primaryLAN(input)?.ipv4.first { routableV4($0, onTunnel: false) }
    }

    /// The primary non-tunnel interface, which the router is asked on.
    static func routerInterface(_ input: Input) -> String? {
        if let p = input.primaryInterface, isLAN(p) { return p }
        return primaryLAN(input)?.interface
    }

    /// Named VPN services the Mac has set up that have no address now: "Tailscale — Not connected".
    static func vpnDown(setupVPNs: [String], services: [Service]) -> [String] {
        let up = Set(vpnServices(services).filter { s in
            s.ipv4.contains { routableV4($0, onTunnel: true) } || s.ipv6.contains { usableV6($0) && !isLinkLocalV6($0.address) }
        }.map(\.name))
        return Array(Set(setupVPNs.filter { !$0.isEmpty && !up.contains($0) })).sorted()
    }

    /// The MagicDNS name to try for a tunnel service: this Mac's LocalHostName, lowercased, in the
    /// tailnet's domain (a match domain under ts.net). Kept only if it resolves to the tunnel's own
    /// address (Reachability checks): a machine renamed in Tailscale's admin console has another.
    static func magicDNSCandidate(localHostName: String?, service: Service) -> String? {
        guard let host = localHostName?.lowercased(), !host.isEmpty, isTunnel(service.interface) else { return nil }
        guard let domain = service.matchDomains.map({ $0.hasSuffix(".") ? String($0.dropLast()) : $0 })
            .first(where: { $0.lowercased().hasSuffix(".ts.net") }) else { return nil }
        return "\(host).\(domain.lowercased())"
    }

    // MARK: Address tests

    static func isTunnel(_ interface: String) -> Bool {
        OriginPolicy.interfaceKind(name: interface) == .tunnel
    }

    static func isLAN(_ interface: String) -> Bool {
        OriginPolicy.interfaceKind(name: interface) == .lan
    }

    /// Not loopback, not link-local; 100.64/10 only on a tunnel (on a LAN interface it is carrier
    /// NAT, unreachable from outside).
    static func routableV4(_ a: String, onTunnel: Bool) -> Bool {
        guard let b = IPBytes.parse(a), b.count == 4, !IPBytes.isLoopback(b), !IPBytes.isLinkLocal(b), b != [0, 0, 0, 0] else { return false }
        return onTunnel || !IPBytes.isCarrierShared(b)
    }

    /// Neither temporary nor deprecated, not loopback.
    static func usableV6(_ e: IPv6Entry) -> Bool {
        guard let b = IPBytes.parse(e.address), b.count == 16, !IPBytes.isLoopback(b) else { return false }
        return e.flags & IPv6Entry.temporary == 0 && e.flags & IPv6Entry.deprecated == 0
    }

    static func isLinkLocalV6(_ a: String) -> Bool {
        IPBytes.parse(a).map { $0.count == 16 && IPBytes.isLinkLocal($0) } ?? false
    }

    /// One stable global IPv6 (2000::/3) on a LAN service, for the internet switch.
    static func stableGlobalV6(_ input: Input) -> String? {
        let lans = input.services.filter { isLAN($0.interface) }.sorted { ($0.interface == input.primaryInterface ? 0 : 1, $0.interface) < ($1.interface == input.primaryInterface ? 0 : 1, $1.interface) }
        for s in lans {
            for e in s.ipv6 where usableV6(e) {
                if let b = IPBytes.parse(e.address), b.count == 16, b[0] & 0xE0 == 0x20 { return e.address }
            }
        }
        return nil
    }
}
