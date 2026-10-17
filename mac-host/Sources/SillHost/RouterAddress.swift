import Foundation
import dnssd

/// The router's own internet address, for the port-forward instruction (docs/remote-access-plan.md
/// §4.8), asked only while the internet switch is on. mDNSResponder asks the router (PCP, NAT-PMP
/// or UPnP) through `DNSServiceNATPortMappingCreate` with protocol, ports and TTL all zero, which
/// dns_sd.h documents as "just discover the NAT gateway's external IP address": no mapping is ever
/// created, and no server outside the home is asked. It is asked on the primary non-tunnel
/// interface, because a VPN exit node can make a tunnel primary. The answer repeats when the
/// address changes.
///
/// TEST ONLY: SILL_TEST_NO_ROUTER=1 skips the query on a host that does not advertise.
final class RouterAddress: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sill.router", qos: .utility)
    private var ref: DNSServiceRef?
    private let onChange: @MainActor (RemoteStatus.Router) -> Void

    /// Asks on `interface` ("en0"; nil: whichever the system picks) and reports every answer on
    /// the main actor.
    init?(interface: String?, onChange: @escaping @MainActor (RemoteStatus.Router) -> Void) {
        self.onChange = onChange
        let index = interface.map { if_nametoindex($0) } ?? 0
        var r: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let err = DNSServiceNATPortMappingCreate(&r, 0, index, 0, 0, 0, 0, { _, _, _, error, external, _, _, _, _, info in
            guard let info else { return }
            Unmanaged<RouterAddress>.fromOpaque(info).takeUnretainedValue().answered(error: error, external: external)
        }, context)
        guard err == kDNSServiceErr_NoError, let r else { return nil }
        ref = r
        DNSServiceSetDispatchQueue(r, queue)
    }

    /// Stops asking. Called before the object goes away.
    func stop() {
        queue.sync {
            if let r = ref { DNSServiceRefDeallocate(r) }
            ref = nil
        }
    }

    deinit { if let r = ref { DNSServiceRefDeallocate(r) } }

    /// On `queue`.
    private func answered(error: DNSServiceErrorType, external: UInt32) {
        guard ref != nil else { return }
        let result = Self.classify(error: Int(error), externalNetworkOrder: external)
        let deliver = onChange
        Task { @MainActor in deliver(result) }
    }

    /// An answer as the pane shows it: carrier NAT for 100.64/10, double NAT for a private
    /// address or kDNSServiceErr_DoubleNAT, no answer for an unsupported or disabled protocol (or
    /// nothing at all), else the address.
    static func classify(error: Int, externalNetworkOrder: UInt32) -> RemoteStatus.Router {
        switch error {
        case kDNSServiceErr_NoError: break
        case kDNSServiceErr_DoubleNAT: return .doubleNAT
        default: return .noAnswer
        }
        let a = UInt32(bigEndian: externalNetworkOrder)
        let bytes = [UInt8(a >> 24), UInt8(a >> 16 & 255), UInt8(a >> 8 & 255), UInt8(a & 255)]
        guard a != 0 else { return .noAnswer }
        let text = IPBytes.text(bytes)
        if IPBytes.isCarrierShared(bytes) { return .carrierNAT(text) }
        if IPBytes.isPrivate(bytes) { return .doubleNAT }
        return .address(text)
    }
}
