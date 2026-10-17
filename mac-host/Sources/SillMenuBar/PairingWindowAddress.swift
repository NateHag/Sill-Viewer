import Foundation
import StreamProtocol

/// The address the pairing window gives to type on the device, under "Can’t scan? Tap Enter Code
/// Instead, and type:" (docs/remote-access-plan.md §6.2). Tailscale's name and IPv4 take this
/// network's place (Noah, 2026-09-25: from an iPhone's hotspot this network's address answered
/// nothing, while the Tailscale address and its MagicDNS name both paired). Another VPN's address
/// never does: it may answer from nowhere (NordVPN's NordLynx gives every Mac 10.5.0.2, Cloudflare
/// WARP 172.16.0.2), while this network's answers at home and through a VPN into the home network.
/// In order:
/// 1. the first VPN with a name (Tailscale's MagicDNS name), with that VPN's first IPv4 under it
///    when it has one;
/// 2. else the first VPN IPv4 in Tailscale's 100.64.0.0/10, else the first VPN IPv6 in its
///    fd7a:115c:a1e0::/48, alone, whichever VPN the list names first (open-source tailscaled's
///    unnamed "VPN (utun4)" included);
/// 3. else this network's address, as before, with another VPN's first IPv4 (else IPv6) under it
///    when there is one ("VPN (utun6)" included);
/// 4. else another VPN's first IPv4, else its first IPv6 (no LAN address), as before;
/// 5. else the first address listed, as before (with no VPN and no LAN address only an internet
///    address or a test host's 127.0.0.1 can be there);
/// 6. else "this Mac’s address".
/// Names and IPs are told apart by the address parser, VPNs by their kind and Tailscale's by the
/// parsed address's range, never by the text of a name or a service (a VPN host the parser refuses
/// counts as none). Each value is written the way the parser writes it back (an IPv6 address in
/// brackets), with the address's own port when it has one (an address name's), else the remote
/// door's when it is not the one a device assumes. Pure: Foundation and StreamProtocol, checked on
/// its own with swiftc.
enum PairingWindowAddress {
    struct Choice: Equatable {
        /// What to type: "mac-mini.tail1234.ts.net", "100.101.102.103", "192.168.1.20".
        var primary: String
        /// The line under it, after "or": the named VPN's own IPv4 under its name ("or
        /// 100.101.102.103"), or another VPN's address under this network's ("or 10.8.0.6"); nil
        /// when there is none to show.
        var secondary: String?
    }

    static let placeholder = "this Mac’s address"

    /// `addresses` and `lan` are the remote status's (dial order: VPN names, VPN IPv4, VPN IPv6,
    /// this network's IPv4, then the internet's); `port` is the remote door's and `defaultPort` the
    /// one a device dials when none is typed.
    static func choose(from addresses: [MacAddress], lan: String?, port: Int, defaultPort: Int) -> Choice {
        let vpn = addresses.compactMap { a -> (address: MacAddress, parsed: ParsedAddress)? in
            guard a.kind == MacAddress.vpn, case .success(let parsed) = AddressParser.parse(a.host) else { return nil }
            return (a, parsed)
        }
        func typed(_ parsed: ParsedAddress, ownPort: Int?) -> String {
            var p = parsed
            if let ownPort { p.port = ownPort } else if port != defaultPort { p.port = port }
            return p.text
        }
        func typed(_ host: String, ownPort: Int?) -> String {
            guard case .success(let parsed) = AddressParser.parse(host) else { return host }
            return typed(parsed, ownPort: ownPort)
        }
        if let name = vpn.first(where: { $0.parsed.kind == .name }) {
            let v4 = vpn.first { $0.address.via == name.address.via && $0.parsed.kind == .ipv4 }
            return Choice(primary: typed(name.parsed, ownPort: name.address.port),
                          secondary: v4.map { typed($0.parsed, ownPort: $0.address.port) })
        }
        if let tailscale = vpn.first(where: { $0.parsed.kind == .ipv4 && isTailscale($0.parsed) })
            ?? vpn.first(where: { $0.parsed.kind == .ipv6 && isTailscale($0.parsed) }) {
            return Choice(primary: typed(tailscale.parsed, ownPort: tailscale.address.port), secondary: nil)
        }
        // Every VPN address left is another VPN's.
        let other = (vpn.first(where: { $0.parsed.kind == .ipv4 }) ?? vpn.first(where: { $0.parsed.kind == .ipv6 }))
            .map { typed($0.parsed, ownPort: $0.address.port) }
        if let lan {
            let shown = typed(lan, ownPort: nil)
            return Choice(primary: shown, secondary: other == shown ? nil : other)
        }
        if let other { return Choice(primary: other, secondary: nil) }
        if let first = addresses.first { return Choice(primary: typed(first.host, ownPort: first.port), secondary: nil) }
        return Choice(primary: placeholder, secondary: nil)
    }

    /// Tailscale's ranges, 100.64.0.0/10 and fd7a:115c:a1e0::/48, as the device's
    /// `RemoteDialPolicy.isVPNAddress` has them, read from the parsed address: an IPv4 there is
    /// exactly four decimal octets, an IPv6 is read back into its bytes. Asked only of a VPN's
    /// addresses: on a LAN interface 100.64/10 is carrier NAT, which AddressList never lists.
    static func isTailscale(_ address: ParsedAddress) -> Bool {
        switch address.kind {
        case .ipv4:
            let octets = address.host.split(separator: ".").compactMap { UInt8($0) }
            return octets.count == 4 && octets[0] == 100 && octets[1] & 0xC0 == 64
        case .ipv6:
            var bytes = in6_addr()
            guard inet_pton(AF_INET6, address.host, &bytes) == 1 else { return false }
            return withUnsafeBytes(of: bytes) { Array($0.prefix(6)) } == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        case .name:
            return false
        }
    }
}
