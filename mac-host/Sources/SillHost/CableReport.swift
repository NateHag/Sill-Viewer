import Foundation

/// `SillHost --print-cable` (docs/home-pairing-plan.md §5): what the cable rule reads on this Mac,
/// one line per interface it looks at, then the console. Read-only IOKit and CGSession: no
/// listener, no permission. A device is named by the start of its CableLink.deviceID, never its
/// serial number.
package enum CableReport {
    package static func lines() -> [String] {
        var out: [String] = []
        for name in InterfaceSnapshot.cableCandidates() {
            out.append("\(name): " + describe(InterfaceSnapshot.readCable(name)))
        }
        // No test hook here: the report reads the real console.
        out.append("This Mac: " + SessionLock.consoleDescription(testHost: false))
        return out
    }

    /// One interface's reading in words.
    static func describe(_ r: InterfaceSnapshot.CableReading) -> String {
        guard r.registered else { return "not a cable (no registry entry)" }
        guard let a = r.ancestry else {
            return r.deviceMode ? "not a cable (this Mac's own USB device port)" : "not a cable (no USB device)"
        }
        let vendor = a.vendor.map { String(format: "0x%04X", $0) } ?? "unknown"
        let product = r.product.map { String(format: "0x%04X", $0) } ?? "unknown"
        let name = a.productName ?? "unnamed"
        guard CableLink.isPhoneOrPadCable(a) else {
            return "not a cable (a USB device, not an iPhone's or iPad's NCM link: vendor \(vendor), product \(product), \"\(name)\"\(a.ncm ? ", NCM" : ""))"
        }
        guard let serial = a.serial, !serial.isEmpty else {
            return "not a cable (an \(name) without a serial number)"
        }
        let device = String(CableLink.deviceID(serial: serial).prefix(4))
        let session = a.session.map { ", plug-in \($0)" } ?? ""
        return "the USB cable to an \(name) (Apple, product \(product), NCM, device \(device)…\(session))"
    }
}
