import Foundation
import Darwin
import IOKit

/// The Mac's interfaces and addresses as `getifaddrs` reports them: names, flags (up,
/// point-to-point, loopback), each address with its prefix length. Both doors' origin checks read
/// it (`interfaces()`), and the remote door's address list reads the point-to-point tunnels that
/// are not network services from it. Cached for 2 s, so a burst of connections costs one read and
/// neither door needs a SystemConfiguration watcher. `routeSource(to:)` asks the kernel which of
/// these addresses its route to a peer uses. `readCable(_:)` reads what IOKit says is above one
/// interface (the USB cable to an iPhone or iPad, docs/home-pairing-plan.md §4.3); it is never
/// cached, because a device swapped for another keeps the interface's name.
///
/// Thread-safe: the doors call it on the network queue, the address list on its own queue.
final class InterfaceSnapshot: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let name: String
        /// 4 or 16 bytes, without a zone.
        let address: [UInt8]
        let prefixBits: Int
        let up: Bool
        let pointToPoint: Bool
        let loopback: Bool
    }

    static let shared = InterfaceSnapshot()
    static let maxAge: CFAbsoluteTime = 2

    private let lock = NSLock()
    private var cached: (at: CFAbsoluteTime, entries: [Entry], interfaces: OriginPolicy.Interfaces)?

    /// For `OriginPolicy.classify`.
    func interfaces() -> OriginPolicy.Interfaces { current().interfaces }

    /// Every address of every interface.
    func entries() -> [Entry] { current().entries }

    /// Forget the cache (a network change the caller has heard of).
    func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    private func current() -> (entries: [Entry], interfaces: OriginPolicy.Interfaces) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if let c = cached, now - c.at < Self.maxAge { lock.unlock(); return (c.entries, c.interfaces) }
        lock.unlock()
        let entries = Self.read()
        let interfaces = Self.policyInterfaces(entries)
        lock.lock(); cached = (now, entries, interfaces); lock.unlock()
        return (entries, interfaces)
    }

    /// One `getifaddrs` pass: IPv4 and IPv6 addresses only.
    static func read() -> [Entry] {
        var out: [Entry] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            let flags = ifa.ifa_flags
            let name = String(cString: ifa.ifa_name)
            var address: [UInt8] = []
            var bits = 0
            if family == AF_INET {
                address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin_addr) { Array($0) } }
                if let m = ifa.ifa_netmask {
                    bits = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin_addr) { Self.ones(Array($0)) } }
                }
            } else if family == AF_INET6 {
                address = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) } }
                if let m = ifa.ifa_netmask {
                    bits = m.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Self.ones(Array($0)) } }
                }
                // The kernel embeds the scope in bytes 2–3 of a link-local address; the address
                // itself has zeros there.
                if address[0] == 0xFE && address[1] & 0xC0 == 0x80 { address[2] = 0; address[3] = 0 }
            } else {
                continue
            }
            out.append(Entry(name: name, address: address, prefixBits: bits,
                             up: flags & UInt32(IFF_UP) != 0,
                             pointToPoint: flags & UInt32(IFF_POINTOPOINT) != 0,
                             loopback: flags & UInt32(IFF_LOOPBACK) != 0))
        }
        return out
    }

    /// The policy's view: each interface's kind, each local address's owner, and the on-link
    /// prefixes of every interface that is neither a tunnel nor loopback.
    static func policyInterfaces(_ entries: [Entry]) -> OriginPolicy.Interfaces {
        var result = OriginPolicy.Interfaces()
        for e in entries {
            let kind = OriginPolicy.interfaceKind(name: e.name, pointToPoint: e.pointToPoint, loopback: e.loopback)
            result.kind[e.name] = kind
            result.owner[e.address] = e.name
            if kind != .tunnel && kind != .loopback && e.prefixBits > 0 {
                result.prefixes.append((e.name, e.address, e.prefixBits))
            }
        }
        return result
    }

    private static func ones(_ mask: [UInt8]) -> Int {
        mask.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// This Mac's own addresses (4 or 16 bytes, link-local ones without their embedded scope), read
    /// afresh: what CableLink's rule 2 and the ask rule's "from this Mac" compare a source with. A
    /// cached table could miss an address the Mac gained a moment ago.
    static func ownAddresses() -> Set<[UInt8]> {
        Set(read().map(\.address))
    }

    // MARK: The USB cable (IOKit, read-only)

    /// What IOKit says is above one network interface, read afresh (about 0.2 ms). Nothing is
    /// written and no permission is needed. Plain values, so this file still compiles on its own
    /// with OriginPolicy (the origin check); Door turns it into a CableLink.Ancestry.
    struct CableReading: Equatable, Sendable {
        /// The interface has an entry in the IOService plane (awdl0, the tunnels and bridges have none).
        var registered = false
        /// An IOUSBHostDevice is above it (none above Wi-Fi, Thunderbolt or this Mac's own USB
        /// device ports); the fields below are that device's.
        var usbDevice = false
        /// The chain passes a CDC NCM IOUSBHostInterface (bInterfaceClass 2, bInterfaceSubClass 13).
        var ncm = false
        var vendor: Int?
        var product: Int?
        /// "USB Product Name", else "kUSBProductString".
        var productName: String?
        /// "USB Serial Number": never logged or saved as it is (CableLink.deviceID).
        var serial: String?
        /// Its sessionID: one plug-in.
        var session: UInt64?
        /// The chain passes an IOUSBDeviceInterface: this Mac's own USB device port (anpi0, en4–en6).
        var deviceMode = false
    }

    /// Walks the IOService plane up from the interface named `bsdName`: notes a CDC NCM
    /// IOUSBHostInterface (class 2, subclass 13) on the way and stops at the first IOUSBHostDevice,
    /// reading its idVendor, idProduct, product name ("USB Product Name", else
    /// "kUSBProductString"), "USB Serial Number" and sessionID. Anything missing stays nil, which
    /// CableLink reads as no cable (its rule 3).
    static func readCable(_ bsdName: String) -> CableReading {
        var reading = CableReading()
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return reading }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)   // consumes `matching`
        guard service != 0 else { return reading }
        reading.registered = true
        var entry = service
        var ncm = false
        defer { IOObjectRelease(entry) }
        for _ in 0..<64 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(entry)
            entry = parent
            if IOObjectConformsTo(entry, "IOUSBDeviceInterface") != 0 { reading.deviceMode = true }
            if IOObjectConformsTo(entry, "IOUSBHostInterface") != 0,
               number(entry, "bInterfaceClass") == 2, number(entry, "bInterfaceSubClass") == 13 {
                ncm = true
            }
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                reading.usbDevice = true
                reading.ncm = ncm
                reading.vendor = number(entry, "idVendor")
                reading.product = number(entry, "idProduct")
                reading.productName = string(entry, "USB Product Name") ?? string(entry, "kUSBProductString")
                reading.serial = string(entry, "USB Serial Number")
                reading.session = (property(entry, "sessionID") as? NSNumber)?.uint64Value
                break
            }
        }
        return reading
    }

    /// The interfaces the cable rule looks at: up, and neither loopback, a tunnel nor peer-to-peer
    /// Wi-Fi, in getifaddrs' order (--print-cable).
    static func cableCandidates() -> [String] {
        var names: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return names }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = p.pointee.ifa_flags
            let name = String(cString: p.pointee.ifa_name)
            guard flags & UInt32(IFF_UP) != 0, !names.contains(name) else { continue }
            let kind = OriginPolicy.interfaceKind(name: name, pointToPoint: flags & UInt32(IFF_POINTOPOINT) != 0,
                                                  loopback: flags & UInt32(IFF_LOOPBACK) != 0)
            guard kind == .lan || kind == .other else { continue }
            names.append(name)
        }
        return names
    }

    private static func property(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    private static func number(_ e: io_registry_entry_t, _ key: String) -> Int? {
        (property(e, key) as? NSNumber)?.intValue
    }
    private static func string(_ e: io_registry_entry_t, _ key: String) -> String? {
        property(e, key) as? String
    }

    /// The address of this Mac that the kernel's route to `destination` (4 or 16 bytes) sends
    /// from, found by connecting a UDP socket, which sends nothing: where a connection from there
    /// arrived, for a check that runs before the connection has a path. Nil without a route.
    static func routeSource(to destination: [UInt8]) -> [UInt8]? {
        let v4 = destination.count == 4
        guard v4 || destination.count == 16 else { return nil }
        let fd = socket(v4 ? AF_INET : AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_storage()
        let length: socklen_t
        if v4 {
            var sin = sockaddr_in()
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            sin.sin_len = UInt8(length)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = in_port_t(9).bigEndian          // any port: nothing is sent
            withUnsafeMutableBytes(of: &sin.sin_addr) { $0.copyBytes(from: destination) }
            withUnsafeMutableBytes(of: &remote) { $0.storeBytes(of: sin, as: sockaddr_in.self) }
        } else {
            var sin6 = sockaddr_in6()
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_len = UInt8(length)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_port = in_port_t(9).bigEndian
            withUnsafeMutableBytes(of: &sin6.sin6_addr) { $0.copyBytes(from: destination) }
            withUnsafeMutableBytes(of: &remote) { $0.storeBytes(of: sin6, as: sockaddr_in6.self) }
        }
        let connected = withUnsafePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) } }
        guard connected == 0 else { return nil }
        var local = sockaddr_storage()
        var localLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &localLength) } }
        guard named == 0 else { return nil }
        return withUnsafeBytes(of: &local) { raw in
            v4 ? withUnsafeBytes(of: raw.load(as: sockaddr_in.self).sin_addr) { Array($0) }
               : withUnsafeBytes(of: raw.load(as: sockaddr_in6.self).sin6_addr) { Array($0) }
        }
    }
}
