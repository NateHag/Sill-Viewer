import Foundation
import CryptoKit
import StreamProtocol

/// Whether a connection came over the USB cable to an iPhone or iPad (docs/home-pairing-plan.md,
/// "The cable" and §4.3): the one route on which the Mac pairs a device by itself. Pure: IOKit is
/// read by InterfaceSnapshot, this judges what it read, so it is checked on its own with swiftc.
///
/// A connection is on the cable when all three hold, and otherwise it is not:
/// 1. its source is an IPv6 link-local address (fe80::/10) scoped to an interface that has above
///    it, in the IOService plane, a CDC NCM interface of an Apple iPhone or iPad
///    (`isPhoneOrPadCable`). The scope is the interface the kernel received the connection on,
///    and link-local sources are never routed, so it is the device at the other end of the cable,
///    never something behind it (the other clients of an iPhone's Personal Hotspot over USB). An
///    IPv4 source never counts, 169.254/16 included: its arrival would only be inferred from the
///    local address, and the iPad never used IPv4 over the cable (41 of 41 sessions in Sill.log);
/// 2. that source is none of this Mac's own addresses: a process on this Mac that dials the
///    Mac's own address on the cable's interface arrives scoped to it, with that address as its
///    source (the Simulator did, 2026-09-24), and would otherwise pair itself while a device is
///    plugged in, then use Sill's grants over loopback;
/// 3. anything unread or unexpected (no registry entry, a missing property, this Mac's own
///    device-mode ports, Thunderbolt, an Ethernet adapter, Apple's own USB one included, another
///    Mac) means not the cable.
///
/// Measured on this Mac with Noah's iPad mini plugged in (2026-09-25): en14 is
/// `IOEthernetInterface ← AppleUSBNCM11Data ← AppleUSBNCM11Control ← IOUSBHostInterface "NCM
/// Control@2" (class 2, subclass 13) ← IOUSBHostDevice "iPad"` (idVendor 0x05AC, `USB Product Name`
/// "iPad", `USB Serial Number` the same at every plug-in, a `sessionID` per plug-in), anri0 the
/// same through AppleUSBHostNCMRestrictedEthernetInterface; this Mac's anpi0–2 and en4–en6 hang
/// off its USB device controller, en1–en3 off Thunderbolt, en0 off PCIe Wi-Fi: no USB host device
/// above any of them.
enum CableLink {
    /// One network interface's IOService ancestry, as far as the first IOUSBHostDevice above it.
    struct Ancestry: Equatable, Sendable {
        /// Passes a CDC NCM IOUSBHostInterface (bInterfaceClass 2, bInterfaceSubClass 13).
        var ncm: Bool
        /// That device's idVendor; nil when no IOUSBHostDevice is above the interface.
        var vendor: Int?
        /// "USB Product Name", else "kUSBProductString".
        var productName: String?
        /// "USB Serial Number": the device itself, the same at every plug-in (an iPhone's or
        /// iPad's UDID). Never logged or saved as it is: `deviceID`.
        var serial: String?
        /// Its sessionID: one plug-in (for the log and --print-cable only).
        var session: UInt64?
    }

    static let appleVendor = 0x05AC
    /// The product names an iPhone and an iPad give over USB.
    static let products: Set<String> = ["iPhone", "iPad"]

    /// Whether an interface's ancestry is the USB cable to an iPhone or iPad: an NCM interface of
    /// an Apple device named "iPhone" or "iPad". No ancestry (nothing above the interface was a
    /// USB host device), another vendor, another product (Apple's USB Ethernet Adapter, another
    /// Mac) or no NCM interface is no cable.
    static func isPhoneOrPadCable(_ a: Ancestry?) -> Bool {
        guard let a, a.ncm, a.vendor == appleVendor, let name = a.productName else { return false }
        return products.contains(name)
    }

    /// The iPhone or iPad a connection came over, or nil: its source (4 or 16 bytes, from the
    /// endpoint) is IPv6 link-local, scoped to an interface whose ancestry `isPhoneOrPadCable`
    /// with a serial number, and is none of this Mac's own addresses (`ownAddresses`, compared
    /// without the kernel's embedded scope). `cables` is each interface's ancestry, read afresh for
    /// the arrival interface of an ask.
    ///
    /// TEST ONLY: `standIn` (`testInterface`) counts a client scoped to that interface as one on
    /// the cable to an "iPad" (`testAncestry`), even when its source is this Mac's own address:
    /// rule 2 is the one rule it skips, so a client on the Mac's own `fe80::…%en0` stands in for a
    /// device on the cable. It still has to be IPv6 link-local and scoped.
    static func device(source: [UInt8], scope: String?, ownAddresses: Set<[UInt8]>,
                       cables: [String: Ancestry], standIn: String? = nil) -> Ancestry? {
        guard source.count == 16, IPBytes.isLinkLocal(source), let scope, !scope.isEmpty else { return nil }
        if let standIn, scope == standIn { return testAncestry }
        guard let a = cables[scope], isPhoneOrPadCable(a), let serial = a.serial, !serial.isEmpty else { return nil }
        let s = IPBytes.unscoped(source)
        guard !ownAddresses.contains(where: { IPBytes.unscoped($0) == s }) else { return nil }
        return a
    }

    /// What PairedDevice.cableDevice keeps for a device: base64url of the first 16 bytes of
    /// SHA-256("sill-cable-v1" ‖ serial), 22 characters. Never the serial itself, in the trust list
    /// or in a log line.
    static func deviceID(serial: String) -> String {
        var input = Data("sill-cable-v1".utf8)
        input.append(Data(serial.utf8))
        return Base64URL.encode(Data(SHA256.hash(data: input).prefix(16)))
    }

    // MARK: Test hooks

    /// The stand-in's device: an "iPad" with serial "TEST", plug-in 1.
    static let testAncestry = Ancestry(ncm: true, vendor: appleVendor, productName: "iPad", serial: "TEST", session: 1)

    /// TEST ONLY: SILL_TEST_CABLE_INTERFACE=<if>, on a test host only (DoorPolicy.isTestHost): an
    /// interface name (a letter, then letters or digits, at most 15), anything else nil.
    static func testInterface(testHost: Bool, environment: [String: String]) -> String? {
        guard testHost, let name = environment["SILL_TEST_CABLE_INTERFACE"], let first = name.first, first.isLetter,
              name.count <= 15, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return name
    }
}
