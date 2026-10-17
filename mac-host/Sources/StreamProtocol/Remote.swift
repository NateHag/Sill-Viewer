import Foundation
import Security
import CryptoKit

// Remote access payloads (kinds 18–22, docs/remote-access-plan.md §3.2), which pairing at home
// uses too (docs/home-pairing-plan.md §3.1: no new kinds, only new string values and optional
// fields, `PairRequest.cable`, `PairResult.method` and `PairResult.message`). The rules of
// HostSettings.swift apply to every one of them: JSON only; fields added later are optional; no
// enums on the wire (strings, so an unknown value is skipped instead of failing the whole decode);
// never rename or retype a field. The generation is in the ALPN (`sill/1`, `sill-pair/1`, which
// every host offers for good: RemoteTLS.serverALPNs), `PairRequest.v` (a host answers any other
// than 1 `closed` without counting a try, so a later pairing method or proof comes with a later
// `v`, never as a new method at 1, which a first-build host would count as a wrong code) and the
// pairing link's `v`. `MacInfo.v` is 1 and no device reads it: kind 18 changes only additively.

/// One way to reach the Mac from afar. Plain values, never enums: an unknown case would fail an
/// older reader.
public struct MacAddress: Codable, Hashable, Sendable {
    /// "mac-mini.tail1234.ts.net", "100.101.102.103" or "fd7a:115c:a1e0::1234" (no brackets).
    public var host: String
    /// Nil: `MacInfo.remotePort`. Set only for an address name whose router forwards another
    /// outside port.
    public var port: Int?
    /// "vpn", "lan" or "internet".
    public var kind: String
    /// Where it comes from, as the Mac's pane names it: "Tailscale", "Wi‑Fi", "Router",
    /// "Address name", "IPv6", "VPN (utun6)", "This Mac" (test hosts).
    public var via: String

    public init(host: String, port: Int? = nil, kind: String, via: String) {
        self.host = host; self.port = port; self.kind = kind; self.via = via
    }

    public static let vpn = "vpn", lan = "lan", internet = "internet"
}

/// Inside kind 18: who this Mac is and how to reach it from afar. Nothing here is secret: whoever
/// can connect at all already shares a network with the Mac.
public struct MacInfo: Codable, Hashable, Sendable {
    /// 1.
    public var v: Int
    /// 16 Crockford characters, `MacID.make(fingerprint)`.
    public var macID: String
    /// The Mac's name (SafeText).
    public var name: String
    /// Seconds since 1970; a device takes only a newer one than it has.
    public var issuedAt: Double
    /// The Mac's Remote Access switch.
    public var remoteAccess: Bool
    /// The configured remote port, also while Remote Access is off (pairing uses it).
    public var remotePort: Int
    /// "Allow connections from the internet".
    public var internet: Bool
    /// In dial order; empty while Remote Access is off and no pairing window is open.
    public var addresses: [MacAddress]

    public init(v: Int = 1, macID: String, name: String, issuedAt: Double, remoteAccess: Bool, remotePort: Int,
                internet: Bool, addresses: [MacAddress]) {
        self.v = v; self.macID = macID; self.name = name; self.issuedAt = issuedAt
        self.remoteAccess = remoteAccess; self.remotePort = remotePort; self.internet = internet
        self.addresses = addresses
    }
}

/// Kind 18. `info` is the exact JSON bytes of a MacInfo and `sig` covers those bytes, so the
/// signature never depends on how either side would re-encode the JSON. Plain base64 (bulk).
public struct SignedMacInfo: Codable, Sendable {
    /// base64 of MacInfo's JSON bytes.
    public var info: String
    /// base64 of the Mac's public key, X9.63 (65 bytes).
    public var key: String
    /// base64 of a DER ECDSA P-256 / SHA-256 signature over the `info` bytes.
    public var sig: String

    public init(info: String, key: String, sig: String) {
        self.info = info; self.key = key; self.sig = sig
    }

    /// Signs `info` with the Mac's identity key (host side). Nil if the key cannot sign.
    public static func signing(_ info: MacInfo, with privateKey: SecKey) -> SignedMacInfo? {
        let bytes = Wire.encode(info)
        guard !bytes.isEmpty, let point = RemoteKey.publicPoint(privateKey),
              let sig = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, bytes as CFData, nil) as Data?
        else { return nil }
        return SignedMacInfo(info: bytes.base64EncodedString(), key: point.base64EncodedString(), sig: sig.base64EncodedString())
    }

    /// The MacInfo and the fingerprint of the key that signed it, when the signature verifies over
    /// the exact `info` bytes, the key is a P-256 point, the JSON decodes and its `macID` is that
    /// key's Mac ID. A device that saved this Mac then also requires `fingerprint` to equal its pin
    /// and `issuedAt` to be newer than the one it has (SavedMacs, on the device).
    public func verified() -> (info: MacInfo, fingerprint: Data)? {
        guard let bytes = Data(base64Encoded: info), let point = Data(base64Encoded: key), point.count == 65,
              let sigData = Data(base64Encoded: sig),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: point),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData),
              publicKey.isValidSignature(signature, for: bytes),
              let decoded = Wire.decode(MacInfo.self, from: bytes) else { return nil }
        let fp = SPKI.fingerprint(point: point)
        guard decoded.macID == MacID.make(fingerprint: fp) else { return nil }
        return (decoded, fp)
    }

    /// The MacInfo without checking anything: for display on a device that has not paired with
    /// this Mac (its Away from home group). Never saved.
    public func unverifiedInfo() -> MacInfo? {
        Data(base64Encoded: info).flatMap { Wire.decode(MacInfo.self, from: $0) }
    }
}

/// Kind 19: the device's one message on a pairing connection.
public struct PairRequest: Codable, Sendable {
    /// 1 (`PairRequest.version`). A host answers a request with any other `closed`, with no try
    /// counted (DoorPolicy.pairing): the generation marker for a later method or proof format.
    public var v: Int
    /// "qr" or "code": a proof for the pairing window. "ask", at the home door only: "pair me, now
    /// if you can, else show me your code" (docs/home-pairing-plan.md §3.1); the remote door
    /// answers it `closed` without counting a try. "cancel", at the home door only: the device no
    /// longer needs the code its ask put up (`cancel`). A device sends "ask" and "cancel" only to a
    /// Mac whose TXT record carries `p` (HomeDoorTXT), so an older host never receives one.
    public var method: String
    /// base64url(proof_D) (PairingProof); "" with "ask".
    public var proof: String
    /// "iPad"; the Mac applies SafeText.
    public var name: String
    /// "iPad14,1".
    public var model: String?
    /// "ask" only: true when the device judged this connection to be the USB cable to the Mac
    /// (DiscoveryPolicy.onCable); absent otherwise. The Mac pairs by itself only when its own rule
    /// (CableLink) agrees as well, so the claim can only narrow what the Mac does.
    public var cable: Bool?

    public init(v: Int = PairRequest.version, method: String, proof: String, name: String, model: String?, cable: Bool? = nil) {
        self.v = v; self.method = method; self.proof = proof; self.name = name; self.model = model; self.cable = cable
    }

    public static let qr = "qr", code = "code", ask = "ask"
    /// At the home door only, after an ask the Mac answered "shown": the device's Cancel, "I no
    /// longer need the code you showed for me". The window that ask opened closes, if it is still
    /// the home door's alone, and its asker is not kept quiet for it (docs/home-pairing-plan.md
    /// §3.1); the answer is "closed" whatever happened. Its `proof` is "". The remote door answers
    /// it "closed" too, with no try counted.
    public static let cancel = "cancel"
    /// The one generation of kind 19 there is: the first public build's, frozen with it.
    public static let version = 1
}

/// Kind 20: the Mac's answer to kind 19. The Mac closes the connection after sending it.
public struct PairResult: Codable, Sendable {
    public var ok: Bool
    /// ok: base64url(proof_M), checked by the device before it saves anything.
    public var proof: String?
    /// ok: the Mac ID.
    public var macID: String?
    /// ok: the Mac's name.
    public var name: String?
    /// ok: base64url of 32 bytes that resolve the Mac's Bonjour TXT tag (RecognitionTag). Sent
    /// nowhere else.
    public var recognitionKey: String?
    /// Not ok: "code", "closed", "expired", "stopped" or "busy". After an ask at the home door also
    /// "shown" (the window shows a code now: scan it or type it), "openOnMac" (the Mac showed none
    /// by itself: choose Pair iPhone or iPad… on the Mac) or "locked" (the Mac is locked).
    public var reason: String?
    /// With "code": the wrong proofs the window still takes.
    public var triesLeft: Int?
    /// With "busy": seconds until the Mac takes another proof.
    public var retryAfter: Double?
    /// ok without a proof: how the Mac paired this device by itself, "cable" (`PairResult.cable`,
    /// the USB cable); nil otherwise, and then left out of the JSON, so every other kind 20 is as
    /// before. A device accepts such an ok only as the answer to its own ask that said
    /// `cable: true` (docs/home-pairing-plan.md §7.5).
    public var method: String?
    /// Not ok: the Mac's own words, for a device that does not know `reason`, which shows them as
    /// they are (`unknownReasonMessage`: SafeText, one line, at most 300 characters) where it would
    /// otherwise have only a guess. Nil, and left out of the JSON, for every reason of the first
    /// public build (`knownReasons`, which its devices word themselves): a later host sends one
    /// with any reason it adds, as a new goodbye carries its `message`.
    public var message: String?

    public init(ok: Bool, proof: String? = nil, macID: String? = nil, name: String? = nil, recognitionKey: String? = nil,
                reason: String? = nil, triesLeft: Int? = nil, retryAfter: Double? = nil, method: String? = nil,
                message: String? = nil) {
        self.ok = ok; self.proof = proof; self.macID = macID; self.name = name; self.recognitionKey = recognitionKey
        self.reason = reason; self.triesLeft = triesLeft; self.retryAfter = retryAfter; self.method = method
        self.message = message
    }

    public static let code = "code", closed = "closed", expired = "expired", stopped = "stopped", busy = "busy"
    public static let shown = "shown", openOnMac = "openOnMac", locked = "locked"
    /// `method`'s one value: paired by itself over the USB cable.
    public static let cable = "cable"

    /// The refusals a device from the first public build words itself, after an ask or a proof: the
    /// reasons above. Frozen with that build (the compatibility floor): a later host adds a reason
    /// only with a `message` for these devices.
    public static let knownReasons: Set<String> = [code, closed, expired, stopped, busy, shown, openOnMac, locked]

    /// The Mac's own words for a refusal whose reason this build does not know: `message`, cleaned
    /// as a goodbye's is (SafeText, one line, at most 300 characters, shown as plain text); nil for
    /// an ok, a reason in `knownReasons`, or a message with nothing printable.
    public var unknownReasonMessage: String? {
        guard !ok, !(reason.map { Self.knownReasons.contains($0) } ?? false) else { return nil }
        let text = SafeText.label(message ?? "", limit: 300)
        return text.isEmpty ? nil : text
    }
}

/// Kind 22: why the host is about to close this session, and what the device should do then
/// (docs/update-notice-plan.md §3.3). Nil fields are left out of the JSON, so the five goodbyes
/// sent before 2026-09-25 are still, byte for byte, `{"reason":"quit"}` and the like.
public struct Goodbye: Codable, Sendable, Equatable {
    /// "removed", "remoteOff", "internetOff", "quit", "busy", "pairingRequired" (Require pairing was
    /// turned on while this unpaired device was connected at home) or "update". Always sent: a
    /// device from before 2026-09-25 decodes nothing without it. A device from then on treats a
    /// reason it does not know by `message` and `reconnect`, so a later host can tell it anything
    /// (GoodbyePolicy).
    public var reason: String
    /// Shown word for word as the connect screen's status line (after SafeText.label, at most 300
    /// characters). "update" always carries one, and a new reason should. Nil: the device's own words.
    public var message: String?
    /// With "update": the oldest device version this host serves, as SillVersion shows it ("1.2").
    public var minimumVersion: String?
    /// Whether the device reconnects by itself. Nil is false for "update" and for a reason the device
    /// does not know; the older reasons keep their own rules. A refusal always sends false.
    public var reconnect: Bool?

    public init(reason: String, message: String? = nil, minimumVersion: String? = nil, reconnect: Bool? = nil) {
        self.reason = reason; self.message = message; self.minimumVersion = minimumVersion; self.reconnect = reconnect
    }

    public static let removed = "removed", remoteOff = "remoteOff", internetOff = "internetOff", quit = "quit", busy = "busy"
    /// Require pairing was turned on while this unpaired device was connected at home.
    public static let pairingRequired = "pairingRequired"
    /// The host no longer serves this device's version: update it (DeviceGate).
    public static let update = "update"
}
