import Foundation

/// Which way a connected device reaches this Mac, told from what its connection reports: over
/// peer-to-peer Wi-Fi (AWDL) or any other way, and the kind of link (`route`). Turning Direct
/// Wireless Connection off disconnects the devices that come over AWDL (StreamServer), and only
/// those; the menu card names each device's route (StatusText).
///
/// Foundation only, so it is checked on its own with swiftc, given a package name for its `package`
/// access (`swiftc -package-name sill ClientLink.swift main.swift`, the checks in main.swift): no
/// test can reach awdl0 headless (docs/direct-wireless-plan.md, "Fixes after Noah's first sessions").
///
/// What a connection shows (2026-09-24, Sill.log and a local probe): an accepted connection's
/// endpoint is the device's address, and a link-local address carries the interface it lives on,
/// in the log's own text: "fe80::8425:bdff:fe62:8930%awdl0.63101" over AWDL,
/// "fe80::47b:5945:e0aa:d0ac%en0.55690" over Wi-Fi, "fe80::18fe:abff:febb:459f%anri0.61390" over
/// the USB cable, and no scope at all over IPv4 ("127.0.0.1:64431"). AWDL carries IPv6 link-local
/// addresses only, so a device on it always shows its scope. The path is the weaker witness: a
/// local connection to this Mac's own address lists both en0 and lo0 (the probe, again on
/// 2026-09-24: to its Wi-Fi IPv4 address, fe80::…%en0 and a global IPv6 address alike, while one
/// to 127.0.0.1 lists lo0 alone).
package enum ClientLink {
    /// The kind of link a device's connection runs over, from this Mac's side: the word the menu
    /// card gives it (StatusText). Each end names its own link, so a device on Wi-Fi streaming
    /// from a Mac on Ethernet says "Wi-Fi" in its panel while the card here says "Wired"; over the
    /// USB cable or AWDL both ends agree.
    package enum Route: Equatable, Sendable {
        /// The USB cable to the device (anri0 here), or a wired Ethernet interface.
        case wired
        /// Wi-Fi that is not peer-to-peer.
        case wifi
        /// Peer-to-peer Wi-Fi (awdl0, llw0): Direct Wireless Connection.
        case direct
    }

    /// An interface as NWInterface gives it: its name and its type, spelled here so that this file
    /// needs Foundation only (StreamServer maps NWInterface.InterfaceType case for case, a type
    /// newer than this code as `other`).
    struct Interface: Equatable {
        enum Kind: Equatable { case wifi, wiredEthernet, cellular, loopback, other }
        var name: String
        var type: Kind
    }

    /// awdl0 (AWDL) and llw0 (its low-latency companion) are the peer-to-peer Wi-Fi interfaces.
    /// Both report the interface type .wifi like en0, so only the name tells them apart; the
    /// device's DiscoveryPolicy.isPeerToPeer uses the same rule.
    static func isPeerToPeer(interface name: String) -> Bool {
        name.hasPrefix("awdl") || name.hasPrefix("llw")
    }

    /// The interface an endpoint's address is scoped to, read from the endpoint's description:
    /// "awdl0" from "fe80::1%awdl0.52397" (Network prints the port after a dot) or from
    /// "[fe80::1%awdl0]:52397". Nil without a scope (IPv4, a global IPv6 address) and for a numeric
    /// one ("%16"), which names no interface this rule could judge.
    static func scope(ofEndpoint description: String) -> String? {
        guard let percent = description.firstIndex(of: "%") else { return nil }
        let name = description[description.index(after: percent)...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard let first = name.first, first.isLetter else { return nil }
        return String(name)
    }

    /// Whether a device's connection runs over peer-to-peer Wi-Fi. The address's scope decides when
    /// it names an interface; without one, the path's interfaces do, and only when every one of them
    /// is peer-to-peer, so a device on any other interface is never taken for a direct one.
    /// `peerToPeer` is the interface rule; a test host adds its stand-in interface to it.
    static func runsPeerToPeer(endpoint: String, pathInterfaces: [String],
                               peerToPeer: (String) -> Bool = isPeerToPeer(interface:)) -> Bool {
        if let scope = scope(ofEndpoint: endpoint) { return peerToPeer(scope) }
        return !pathInterfaces.isEmpty && pathInterfaces.allSatisfy(peerToPeer)
    }

    /// A device's route, by the same witnesses in the same order as `runsPeerToPeer`, so a device
    /// that turning Direct Wireless off would disconnect is always `.direct`. The address's scope
    /// decides when it names an interface, typed by the entry of that name in `interfaces` (the
    /// address's own interface first, then the path's; none: judged by its name alone). Without a
    /// scope the path's interfaces decide, and only when they all say the same: a local connection
    /// lists en0 and lo0, and a word for it would be a guess. Nil, no word, whenever the interfaces
    /// do not say (loopback, a VPN, cellular, a kind this code does not know, nothing reported).
    static func route(endpoint: String, interfaces: [Interface],
                      peerToPeer: (String) -> Bool = isPeerToPeer(interface:)) -> Route? {
        if let scope = scope(ofEndpoint: endpoint) {
            return route(name: scope, type: interfaces.first { $0.name == scope }?.type, peerToPeer: peerToPeer)
        }
        let each = interfaces.map { route(name: $0.name, type: $0.type, peerToPeer: peerToPeer) }
        guard let first = each.first, each.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// One interface's route. Peer-to-peer by name first (awdl0 and llw0 report .wifi). Wired: the
    /// USB cable, which this Mac names anri0 (2026-09-24, above) whatever type it reports, and any
    /// wired Ethernet interface (the cable can also come up as an enN USB Ethernet interface, an
    /// adapter, a desktop Mac's own port). Wi-Fi for the rest of .wifi. Nil for everything else and
    /// for an interface of unknown type.
    static func route(name: String, type: Interface.Kind?,
                      peerToPeer: (String) -> Bool = isPeerToPeer(interface:)) -> Route? {
        if peerToPeer(name) { return .direct }
        if name.hasPrefix("anri") || type == .wiredEthernet { return .wired }
        if type == .wifi { return .wifi }
        return nil
    }
}
