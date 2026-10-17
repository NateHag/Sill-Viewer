import Foundation
import Network
import Security

/// The remote door's TLS and TCP, one builder for the host, the device and the tests
/// (docs/remote-access-plan.md §3.3). TLS 1.3 only; both sides present a self-signed P-256
/// certificate and each pins the other's key: the verify block decides trust entirely and never
/// evaluates names, dates or chains. Tickets and resumption are off, because resumption would skip
/// the certificate and a removed device could come back on an old ticket.
///
/// Two application protocols tell a pairing connection from a session before any data:
/// `sill/1` (a session: paired devices only) and `sill-pair/1` (pairing, one message each way).
/// A host offers both for good (`serverALPNs`, the compatibility floor): a device from the first
/// public build speaks nothing else, and a server that offers neither of its protocols fails its
/// handshake (-9838 on the device) before a word of Sill is said. A later generation's `sill/2`
/// goes beside them, never in their place, with `SillProtocol.current` (Compatibility.swift).
/// Inside TLS: the same 14-byte header and the same kinds as the home door.
///
/// Measured on loopback (2026-09-24): mutual TLS 1.3 is ready in 12–20 ms with suite 0x1302. The
/// server's verify block sees the negotiated ALPN already, so the host refuses an unpaired key on
/// `sill/1` inside the handshake (the client is `.ready`, then its first read fails with -9825).
/// A client whose pin does not match goes `.waiting(-9808)` without ever sending its certificate.
/// An ALPN the server does not offer fails the handshake (server -9810, client -9838).
public enum RemoteTLS {
    /// A session: the catalog, frames and input, as on the home door.
    public static let sessionALPN = "sill/1"
    /// Pairing: exactly one kind 19 from the device and one kind 20 back, then close.
    public static let pairingALPN = "sill-pair/1"
    /// What a host offers, both doors, for good (the compatibility floor, CLAUDE.md): a device from
    /// the first public build offers `sill/1` for a session and `sill-pair/1` for pairing, and only
    /// inside a `sill/1` session can a host tell it anything, kind 22 "update" included. So a later
    /// host adds a later generation beside these and never drops one: a host that no longer serves
    /// such a device still completes its `sill/1` handshake, reads its hello through the device
    /// gate and says "update"; without `sill/1` the device sees only a failed handshake and redials.
    public static let serverALPNs = [sessionALPN, pairingALPN]
    /// The SNI every client sends, so a dynamic DNS or MagicDNS name never crosses the network in
    /// clear. The host ignores it.
    public static let serverName = "sill"
    /// A device's TCP connect timeout for one attempt, seconds.
    public static let dialTimeout = 10

    public enum Role: Sendable {
        /// The host: offers `serverALPNs` and requires a client certificate.
        case server
        /// A device or a test client: offers exactly one application protocol.
        case client(alpn: String)
    }

    /// TLS options for `role`. `verify` gets the peer's fingerprint (SHA-256 of its SPKI; nil when
    /// its key is not P-256) and the application protocol negotiated so far (the server sees it
    /// during the handshake), and returns whether to trust it. Called on `queue`; it must answer at
    /// once and never wait on anything (the host reads a lock-protected snapshot).
    public static func options(identity: sec_identity_t, role: Role, queue: DispatchQueue,
                               verify: @escaping (_ peerFingerprint: Data?, _ alpn: String?) -> Bool) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sp = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sp, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sp, .TLSv13)
        sec_protocol_options_set_local_identity(sp, identity)
        sec_protocol_options_set_tls_tickets_enabled(sp, false)
        sec_protocol_options_set_tls_resumption_enabled(sp, false)
        switch role {
        case .server:
            sec_protocol_options_set_peer_authentication_required(sp, true)
            for alpn in serverALPNs { sec_protocol_options_add_tls_application_protocol(sp, alpn) }
        case .client(let alpn):
            sec_protocol_options_add_tls_application_protocol(sp, alpn)
            sec_protocol_options_set_tls_server_name(sp, serverName)
        }
        sec_protocol_options_set_verify_block(sp, { metadata, _, complete in
            // The pin is the whole of trust, so the trust object is never touched: even copying its
            // chain evaluates it, and an evaluation may have trustd fetch an issuer that the peer's
            // certificate names (an AIA URL), holding this queue, which the host's stream shares,
            // for seconds per unreachable URL before any pin is checked (review, 2026-09-24: 3 s
            // each, and the home door's frames stopped meanwhile). The leaf is read as the peer
            // sent it: no evaluation, no network. Anything but a P-256 key gives nil, which no pin
            // matches.
            complete(verify(peerLeaf(metadata).flatMap { SPKI.fingerprint(of: $0) }, negotiatedALPN(metadata)))
        }, queue)
        return options
    }

    /// The same, for a side that pins by key alone (a device dialing a saved Mac, a test client).
    public static func options(identity: sec_identity_t, role: Role, verify: @escaping (Data?) -> Bool,
                               queue: DispatchQueue) -> NWProtocolTLS.Options {
        options(identity: identity, role: role, queue: queue) { fp, _ in verify(fp) }
    }

    /// TCP for the remote door: no Nagle; keepalive after 5 s idle, every 2 s, 3 probes, so a peer
    /// that vanished is noticed; and a connection whose data goes unacknowledged for 15 s is
    /// dropped (a slow but live link keeps acknowledging). A dialing device also gives up the
    /// connect after `dialTimeout`.
    public static func tcpOptions(dialing: Bool) -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 15
        if dialing { tcp.connectionTimeout = dialTimeout }
        return tcp
    }

    /// Parameters for either end of the remote door: the TLS options above over `tcpOptions`, the
    /// video service class the home door uses, and never peer-to-peer (Direct Wireless is the home
    /// door's alone).
    public static func parameters(tls: NWProtocolTLS.Options, dialing: Bool) -> NWParameters {
        parameters(tls: tls, tcp: tcpOptions(dialing: dialing), peerToPeer: false)
    }

    /// Parameters for either end of the home door once it speaks TLS (docs/home-pairing-plan.md
    /// §3.3): the TLS options above over the caller's own TCP options (the Mac's home door: no
    /// Nagle and keepalive, but no `connectionDropTime`, since home clients keep their 4 s drain
    /// rule; the device: no Nagle), the video service class, and peer-to-peer (AWDL) exactly when
    /// the caller says: Direct Wireless on the Mac, a Direct row on the device.
    public static func parameters(tls: NWProtocolTLS.Options, tcp: NWProtocolTCP.Options, peerToPeer: Bool) -> NWParameters {
        let p = NWParameters(tls: tls, tcp: tcp)
        p.serviceClass = .interactiveVideo
        p.includePeerToPeer = peerToPeer
        return p
    }

    /// The application protocol a ready connection negotiated; nil for none (or not TLS).
    public static func negotiatedALPN(_ connection: NWConnection) -> String? {
        guard let m = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        return negotiatedALPN(m.securityProtocolMetadata)
    }

    /// The fingerprint of a ready connection's peer certificate (its leaf); nil when there is none
    /// or its key is not P-256.
    public static func peerFingerprint(_ connection: NWConnection) -> Data? {
        guard let m = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        return peerLeaf(m.securityProtocolMetadata).flatMap { SPKI.fingerprint(of: $0) }
    }

    /// The first certificate the peer sent (its own), exactly as the handshake carried it. Never
    /// evaluated, so reading it can never wait on the network (see the verify block).
    static func peerLeaf(_ metadata: sec_protocol_metadata_t) -> SecCertificate? {
        var leaf: SecCertificate?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata) { cert in
            if leaf == nil { leaf = sec_certificate_copy_ref(cert).takeRetainedValue() }
        }
        return leaf
    }

    /// The `copy_` form where it exists: the `get_` one is deprecated from macOS 15.5 and iOS 18.5,
    /// and this package still runs on macOS 14 and iOS 17.
    static func negotiatedALPN(_ metadata: sec_protocol_metadata_t) -> String? {
        if #available(macOS 15.5, iOS 18.5, watchOS 11.5, tvOS 18.5, *) {
            guard let p = sec_protocol_metadata_copy_negotiated_protocol(metadata) else { return nil }
            defer { free(UnsafeMutableRawPointer(mutating: p)) }
            return String(cString: p)
        } else {
            return sec_protocol_metadata_get_negotiated_protocol(metadata).map { String(cString: $0) }
        }
    }

    /// The OSStatus inside a TLS error (-9808 bad certificate, -9825 the peer refused ours, -9829
    /// no certificate, -9836 not TLS or too old…), for the device's failure copy and the tests.
    public static func status(of error: NWError) -> OSStatus? {
        if case .tls(let s) = error { return s }
        return nil
    }
}
