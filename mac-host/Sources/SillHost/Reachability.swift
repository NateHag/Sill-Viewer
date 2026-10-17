import Foundation
import SystemConfiguration
import Darwin

/// The facts behind the Mac's remote addresses (docs/remote-access-plan.md §4.8), read from
/// SystemConfiguration's dynamic store (network services with their names, addresses, IPv6 flags,
/// the primary interface, the Tailscale service's DNS match domains) and from getifaddrs (point-to-
/// point tunnels that are no network service). Read-only. AddressList decides what to show.
///
/// It runs only while the remote door does (Remote Access on, or a pairing window open), in
/// Sill.app and SillHost --remote; never on the CLI's default path. Changes arrive through
/// SCDynamicStoreSetNotificationKeys on a utility queue, are coalesced for 0.5 s, read again and
/// handed to the main actor. No polling.
final class Reachability: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var services: [AddressList.Service] = []
        var primaryInterface: String?
        var tunnels: [AddressList.Tunnel] = []
        /// Named VPN services the Mac has set up (connected or not).
        var setupVPNs: [String] = []
        var localHostName: String?
        /// Service ID → its MagicDNS name, when that name resolves to the tunnel's own address.
        var magicDNS: [String: String] = [:]

        /// Interface → service name, for a remote session's route label.
        var serviceNames: [String: String] {
            var out: [String: String] = [:]
            for s in services where !s.name.isEmpty { out[s.interface] = s.name }
            return out
        }
    }

    private let queue = DispatchQueue(label: "sill.reachability", qos: .utility)
    private let onChange: @MainActor (Snapshot) -> Void
    private var store: SCDynamicStore?
    private var readScheduled = false
    private var stopped = false

    /// The MagicDNS check's budget per name.
    static let resolveBudget: TimeInterval = 2
    static let coalesce: TimeInterval = 0.5

    init(onChange: @escaping @MainActor (Snapshot) -> Void) {
        self.onChange = onChange
    }

    /// Starts watching and delivers a first snapshot.
    func start() {
        queue.async { [self] in
            guard store == nil, !stopped else { return }
            var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                retain: nil, release: nil, copyDescription: nil)
            guard let s = SCDynamicStoreCreate(nil, "Sill remote access" as CFString, { _, _, info in
                guard let info else { return }
                Unmanaged<Reachability>.fromOpaque(info).takeUnretainedValue().changed()
            }, &context) else { return }
            let patterns = ["State:/Network/Service/[^/]+/(IPv4|IPv6|DNS)", "State:/Network/Interface/[^/]+/(IPv4|IPv6)",
                            "State:/Network/Global/IPv4", "Setup:/Network/Service/[^/]+(/Interface)?"]
            SCDynamicStoreSetNotificationKeys(s, nil, patterns as CFArray)
            SCDynamicStoreSetDispatchQueue(s, queue)
            store = s
            changed()
        }
    }

    /// Stops watching. Nothing is delivered afterwards.
    func stop() {
        queue.async { [self] in
            stopped = true
            if let s = store { SCDynamicStoreSetDispatchQueue(s, nil) }
            store = nil
        }
    }

    /// On `queue`: one read after the burst settles.
    private func changed() {
        guard !readScheduled, !stopped else { return }
        readScheduled = true
        queue.asyncAfter(deadline: .now() + Self.coalesce) { [self] in
            readScheduled = false
            guard !stopped else { return }
            InterfaceSnapshot.shared.invalidate()
            let snapshot = Self.read()
            let deliver = onChange
            Task { @MainActor in deliver(snapshot) }
        }
    }

    /// Everything, once. Blocking (the MagicDNS check waits up to 2 s per name): never on the main
    /// actor.
    static func read() -> Snapshot {
        var snap = Snapshot()
        guard let store = SCDynamicStoreCreate(nil, "Sill remote access (read)" as CFString, nil, nil) else { return snap }
        snap.primaryInterface = (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryInterface"] as? String
        snap.localHostName = SCDynamicStoreCopyLocalHostName(store) as String?
        func name(of id: String) -> String {
            let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(id)" as CFString) as? [String: Any]
            let iface = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(id)/Interface" as CFString) as? [String: Any]
            return (setup?["UserDefinedName"] as? String) ?? (iface?["UserDefinedName"] as? String) ?? ""
        }
        var byID: [String: AddressList.Service] = [:]
        let keys = (SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv[46]" as CFString) as? [String]) ?? []
        for key in keys.sorted() {
            let parts = key.split(separator: "/").map(String.init)
            guard parts.count == 5, let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let ifname = dict["InterfaceName"] as? String else { continue }
            let id = parts[3]
            var s = byID[id] ?? AddressList.Service(id: id, name: name(of: id), interface: ifname, ipv4: [], ipv6: [])
            let addresses = dict["Addresses"] as? [String] ?? []
            if parts[4] == "IPv4" {
                s.ipv4 += addresses
            } else {
                // Per-address flags live on the interface's key, in the order of its Addresses.
                var flags: [String: Int] = [:]
                if let iface = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(ifname)/IPv6" as CFString) as? [String: Any],
                   let ia = iface["Addresses"] as? [String], let fl = iface["Flags"] as? [Int] {
                    for (a, f) in zip(ia, fl) { flags[a] = f }
                }
                s.ipv6 += addresses.map { AddressList.IPv6Entry(address: $0, flags: flags[$0] ?? 0) }
            }
            if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(id)/DNS" as CFString) as? [String: Any] {
                s.matchDomains = (dns["SupplementalMatchDomains"] as? [String] ?? []).filter { !$0.isEmpty }
            }
            byID[id] = s
        }
        snap.services = byID.values.sorted { ($0.name, $0.interface) < ($1.name, $1.interface) }
        // Every VPN the Mac has set up, for "Tailscale — Not connected".
        let setupKeys = (SCDynamicStoreCopyKeyList(store, "Setup:/Network/Service/[^/]+/Interface" as CFString) as? [String]) ?? []
        for key in setupKeys {
            // A VPN is an NE tunnel ("VPN", as Tailscale and WireGuard set up), IPSec, or PPP over
            // L2TP or PPTP; PPP over a serial line or Ethernet (a USB modem, PPPoE) is not one.
            guard let iface = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let type = iface["Type"] as? String else { continue }
            let subType = iface["SubType"] as? String
            guard type == "VPN" || type == "IPSec" || (type == "PPP" && (subType == "L2TP" || subType == "PPTP")) else { continue }
            let id = key.split(separator: "/").map(String.init)[3]
            let n = name(of: id)
            if !n.isEmpty { snap.setupVPNs.append(n) }
        }
        snap.setupVPNs.sort()
        // Point-to-point interfaces that are up and carry an IPv4 (tunnels outside the services).
        var tunnels: [String: [String]] = [:]
        for e in InterfaceSnapshot.read() where e.pointToPoint && e.up && e.address.count == 4 {
            tunnels[e.name, default: []].append(IPBytes.text(e.address))
        }
        snap.tunnels = tunnels.map { AddressList.Tunnel(interface: $0.key, ipv4: $0.value) }.sorted { $0.interface < $1.interface }
        // MagicDNS: kept only when the guess resolves to the tunnel's own address.
        for s in AddressList.vpnServices(snap.services) {
            guard let candidate = AddressList.magicDNSCandidate(localHostName: snap.localHostName, service: s) else { continue }
            let own = Set((s.ipv4 + s.ipv6.map(\.address)).compactMap { IPBytes.parse($0) })
            if resolves(candidate, toAnyOf: own) { snap.magicDNS[s.id] = candidate }
        }
        return snap
    }

    /// Whether `name` resolves (getaddrinfo, the system's resolver: Tailscale answers its own
    /// names) to one of `addresses` within `resolveBudget`. A lookup that hangs is abandoned.
    static func resolves(_ name: String, toAnyOf addresses: Set<[UInt8]>) -> Bool {
        final class Box: @unchecked Sendable {
            var found: [[UInt8]] = []
            let done = DispatchSemaphore(value: 0)
        }
        let box = Box()
        Thread.detachNewThread {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(name, nil, &hints, &res) == 0, let first = res {
                for p in sequence(first: first, next: { $0.pointee.ai_next }) {
                    guard let sa = p.pointee.ai_addr else { continue }
                    if Int32(sa.pointee.sa_family) == AF_INET {
                        box.found.append(sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin_addr) { Array($0) } })
                    } else if Int32(sa.pointee.sa_family) == AF_INET6 {
                        box.found.append(sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) } })
                    }
                }
                freeaddrinfo(res)
            }
            box.done.signal()
        }
        guard box.done.wait(timeout: .now() + resolveBudget) == .success else { return false }
        return box.found.contains { addresses.contains($0) }
    }

    /// The input AddressList needs from a snapshot, before the Mac's own settings are added.
    static func input(_ s: Snapshot) -> AddressList.Input {
        AddressList.Input(services: s.services, primaryInterface: s.primaryInterface, tunnels: s.tunnels, magicDNS: s.magicDNS)
    }
}

/// `SillHost --print-reachability`: the Mac's remote addresses as its pane would list them
/// (label, address, kind), read once, read-only; no listener, no router query.
package enum ReachabilityReport {
    package static func lines() -> [String] {
        let snap = Reachability.read()
        let list = AddressList.build(Reachability.input(snap))
        var out: [String] = []
        let width = max(12, (list.map(\.via.count).max() ?? 0) + 2)
        let addressWidth = max(16, (list.map { $0.host.count + ($0.port.map { ":\($0)".count } ?? 0) }.max() ?? 0) + 2)
        for a in list {
            let address = a.port.map { "\(a.host):\($0)" } ?? a.host
            out.append(a.via.padding(toLength: width, withPad: " ", startingAt: 0)
                       + address.padding(toLength: addressWidth, withPad: " ", startingAt: 0) + a.kind)
        }
        for name in AddressList.vpnDown(setupVPNs: snap.setupVPNs, services: snap.services) {
            out.append("\(name) — Not connected")
        }
        if !list.contains(where: { $0.kind == "vpn" }) && snap.setupVPNs.isEmpty {
            out.append("No VPN is running on this Mac.")
        }
        return out
    }
}
