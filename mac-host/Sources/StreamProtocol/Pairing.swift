import Foundation
import Network
import Security
import CryptoKit
import CommonCrypto

// Pairing (docs/remote-access-plan.md §3.5–3.6): the typed code, the proofs both sides exchange,
// the Bonjour recognition tag and the sill://pair link. Shared by the Mac, the device and the
// checks; the vectors in the plan were computed in Python and these functions must match them.

/// The 12-digit typed code: 11 uniformly random digits, then one Damm check digit, so a typo is
/// caught on the device and never uses up one of the Mac's five tries. Digits, so the Duo's number
/// pad works. Shown as "4829 1355 7208".
public enum PairingCode {
    /// Damm's quasigroup of order 10 (interim starts at 0, then `interim = table[interim][digit]`;
    /// the check digit is the final interim, and a valid code ends at 0). It catches every
    /// single-digit substitution and every adjacent transposition.
    static let table: [[Int]] = [
        [0, 3, 1, 7, 5, 9, 8, 6, 4, 2], [7, 0, 9, 2, 1, 5, 4, 8, 6, 3], [4, 2, 0, 6, 8, 7, 1, 3, 5, 9],
        [1, 7, 5, 0, 9, 8, 3, 4, 2, 6], [6, 1, 2, 3, 0, 4, 5, 9, 7, 8], [3, 6, 7, 4, 2, 0, 9, 5, 8, 1],
        [5, 8, 6, 9, 7, 2, 0, 1, 3, 4], [8, 9, 4, 5, 3, 6, 2, 0, 1, 7], [9, 4, 3, 8, 6, 1, 7, 2, 0, 5],
        [2, 5, 8, 1, 4, 3, 6, 7, 9, 0],
    ]

    public static let length = 12

    /// The check digit for `digits` (each 0–9).
    public static func checkDigit(_ digits: [Int]) -> Int {
        digits.reduce(0) { table[$0][$1] }
    }

    /// A fresh code: 12 ASCII digits, the last the check digit. The 11 random ones come from
    /// SecRandomCopyBytes by rejection sampling (a byte of 250 or more is drawn again), so every
    /// digit is equally likely. Nil only if the system's random source fails.
    public static func generate() -> String? {
        var digits: [Int] = []
        while digits.count < length - 1 {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
            for b in bytes where b < 250 && digits.count < length - 1 { digits.append(Int(b % 10)) }
        }
        return (digits + [checkDigit(digits)]).map(String.init).joined()
    }

    /// Why typed input is not a code yet: the device says so locally and sends nothing.
    public enum Problem: Error, Equatable, Sendable {
        /// "A code has 12 digits."
        case length
        /// "That code has a typo. Check it against your Mac."
        case typo
    }

    /// `input` as a code: spaces and hyphens removed, exactly 12 ASCII digits, the check digit valid.
    public static func check(_ input: String) -> Result<String, Problem> {
        let kept = input.filter { $0 != " " && $0 != "-" && $0 != "\u{00A0}" }
        guard kept.count == length, kept.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .failure(.length) }
        guard checkDigit(kept.compactMap { $0.wholeNumberValue }) == 0 else { return .failure(.typo) }
        return .success(kept)
    }

    /// "4829 1355 7208".
    public static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { i -> String in
            let start = code.index(code.startIndex, offsetBy: i)
            return String(code[start..<code.index(start, offsetBy: min(4, code.count - i))])
        }.joined(separator: " ")
    }
}

/// The keys and proofs of one pairing exchange. Each side takes the other's fingerprint from the
/// TLS session, never from a message, so a relay in the middle (which must present its own key to
/// the device) makes the device's proof bind the wrong fingerprint and the Mac rejects it.
///
/// - QR path: the key is the link's 16-byte secret.
/// - Typed path: K = PBKDF2-HMAC-SHA256(the 12 ASCII digits, "sill-pair-v1" ‖ fp_mac, 600,000
///   rounds, 32 bytes): about 90–160 ms here. An intercepted proof then costs about 6·10¹⁶ SHA-256
///   compressions to grind within the 5-minute window.
/// - proof_D = HMAC-SHA256(key, "sill-pair-v1 device" ‖ 0x00 ‖ fp_device ‖ fp_mac)
/// - proof_M = HMAC-SHA256(key, "sill-pair-v1 mac" ‖ 0x00 ‖ fp_mac ‖ fp_device)
public enum PairingProof {
    public static let rounds: UInt32 = 600_000
    static let label = "sill-pair-v1"

    /// The typed path's key. Nil for a code that is not 12 digits or if CommonCrypto fails.
    public static func codeKey(code: String, macFingerprint: Data) -> SymmetricKey? {
        guard code.count == PairingCode.length, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        var salt = Data(label.utf8)
        salt.append(macFingerprint)
        let password = Array(code.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { pw in
            salt.withUnsafeBytes { s in
                pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pw.count) { p in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p, pw.count,
                                         s.bindMemory(to: UInt8.self).baseAddress, s.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
                }
            }
        }
        return status == kCCSuccess ? SymmetricKey(data: out) : nil
    }

    /// The QR path's key: the link's secret.
    public static func qrKey(secret: Data) -> SymmetricKey { SymmetricKey(data: secret) }

    static func deviceMessage(deviceFingerprint: Data, macFingerprint: Data) -> Data {
        var m = Data("\(label) device".utf8); m.append(0); m.append(deviceFingerprint); m.append(macFingerprint)
        return m
    }

    static func macMessage(macFingerprint: Data, deviceFingerprint: Data) -> Data {
        var m = Data("\(label) mac".utf8); m.append(0); m.append(macFingerprint); m.append(deviceFingerprint)
        return m
    }

    /// proof_D, which the device sends in kind 19. `macFingerprint` is the Mac's key as this device
    /// saw it in the TLS session.
    public static func deviceProof(key: SymmetricKey, deviceFingerprint: Data, macFingerprint: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: deviceMessage(deviceFingerprint: deviceFingerprint, macFingerprint: macFingerprint), using: key))
    }

    /// proof_M, which the Mac sends in kind 20.
    public static func macProof(key: SymmetricKey, macFingerprint: Data, deviceFingerprint: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: macMessage(macFingerprint: macFingerprint, deviceFingerprint: deviceFingerprint), using: key))
    }

    /// The Mac's check of proof_D, in constant time.
    public static func isValidDeviceProof(_ proof: Data, key: SymmetricKey, deviceFingerprint: Data, macFingerprint: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: deviceMessage(deviceFingerprint: deviceFingerprint, macFingerprint: macFingerprint), using: key)
    }

    /// The device's check of proof_M, in constant time.
    public static func isValidMacProof(_ proof: Data, key: SymmetricKey, macFingerprint: Data, deviceFingerprint: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: macMessage(macFingerprint: macFingerprint, deviceFingerprint: deviceFingerprint), using: key)
    }
}

/// The Bonjour TXT record's `r`: recognises a saved Mac on a network whatever its Bonjour name
/// ("Mac (2)" after a clash, a renamed Mac, a stranger's Mac of the same name at a café) without
/// broadcasting a stable identifier. base64url (16 characters) of 12 bytes: `p ‖
/// HMAC-SHA256(recognitionKey, "sill-tag-v1" ‖ p)[0..<6]`, where `p` is 6 fresh random bytes at
/// every registration. Replayable, so a recognition hint and never authentication.
public enum RecognitionTag {
    /// The TXT key.
    public static let txtKey = "r"
    static let label = "sill-tag-v1"

    /// A tag for `recognitionKey` (32 bytes). `nonce` (6 bytes) is for the checks' vector; left
    /// out, a fresh random one is drawn. Nil only if the random source fails.
    public static func make(recognitionKey: Data, nonce: Data? = nil) -> String? {
        var p = [UInt8](repeating: 0, count: 6)
        if let nonce, nonce.count == 6 {
            p = [UInt8](nonce)
        } else if SecRandomCopyBytes(kSecRandomDefault, p.count, &p) != errSecSuccess {
            return nil
        }
        var tag = Data(p)
        tag.append(mac(recognitionKey: recognitionKey, nonce: Data(p)))
        return Base64URL.encode(tag)
    }

    /// Whether `tag` was made with `recognitionKey`. Constant time in the 6 compared bytes.
    public static func matches(_ tag: String, recognitionKey: Data) -> Bool {
        guard let bytes = Base64URL.decode(tag), bytes.count == 12 else { return false }
        let expected = mac(recognitionKey: recognitionKey, nonce: bytes.prefix(6))
        var diff: UInt8 = 0
        for (a, b) in zip(expected, bytes.suffix(6)) { diff |= a ^ b }
        return diff == 0
    }

    static func mac(recognitionKey: Data, nonce: Data) -> Data {
        var message = Data(label.utf8)
        message.append(nonce)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: recognitionKey)).prefix(6))
    }
}

/// The Bonjour TXT record's `p` (docs/home-pairing-plan.md §3.2), beside the recognition tag `r`:
/// how the home door speaks. "1": TLS, paired devices only (Require pairing on); "0": TLS, any
/// device (Require pairing off). No `p`: a plain door (Sill.app from before pairing at home, or
/// SillHost without --pairing). Any other value reads as "1", the safe side. A device reads it
/// before it dials, so it never dials TLS at a plain door, nor plain at a TLS one, by accident.
/// Not an identifier, and not authentication: anyone can advertise any `p`, which is why a saved
/// Mac's rows are always dialed pinned, whatever its record says.
public enum HomeDoorTXT {
    /// The TXT key.
    public static let key = "p"

    public enum Door: Equatable, Sendable {
        /// No `p`: plain TCP and no pairing.
        case plain
        /// `p=1`, or any value but "0": TLS, paired devices only.
        case pairingRequired
        /// `p=0`: TLS, any device.
        case open
    }

    /// The value a TLS home door advertises.
    public static func value(requirePairing: Bool) -> String { requirePairing ? "1" : "0" }

    /// The door a TXT record's keys and values describe. Keys are case-insensitive (RFC 6763
    /// §6.4): "p", else "P".
    public static func door(_ txt: [String: String]) -> Door {
        guard let value = txt[key] ?? txt[key.uppercased()] else { return .plain }
        return value == "0" ? .open : .pairingRequired
    }

    /// The door a received record describes, entry by entry: what a device reads. A `p` without a
    /// value (a boolean attribute, which NWTXTRecord's `dictionary` leaves out: measured
    /// 2026-09-25) reads as "1", like any value but "0", rather than as a plain door.
    public static func door(_ record: NWTXTRecord) -> Door {
        switch record.getEntry(for: key) {
        case nil: return .plain
        case .string(let value)?: return value == "0" ? .open : .pairingRequired
        default: return .pairingRequired          // no value, an empty one, or bytes
        }
    }
}

/// The QR code's content, also a link another app can hand over (always behind a confirmation on
/// the device): `sill://pair?v=1&m=<macID>&k=<fp>&s=<secret>&n=<Mac name>&p=<port>&a=<address>…`.
/// About 230 bytes: a version 11 QR code at level M.
public struct PairLink: Hashable, Sendable {
    public static let maxAddresses = 5
    public static let nameLimit = 64

    /// 16 Crockford characters; always `MacID.make(fingerprint)`.
    public var macID: String
    /// The Mac's pin: SHA-256 of its SPKI (32 bytes; 43 characters in the link).
    public var fingerprint: Data
    /// The QR path's one-time key (16 bytes; 22 characters in the link).
    public var secret: Data
    /// The Mac's name after SafeText, at most 64 characters; "Mac" when the link had none.
    public var name: String
    /// The remote port (1–65535).
    public var port: Int
    /// At most 5, in the Mac's dial order; each with its own port when it has one.
    public var addresses: [ParsedAddress]

    public init(fingerprint: Data, secret: Data, name: String, port: Int, addresses: [ParsedAddress]) {
        macID = MacID.make(fingerprint: fingerprint)
        self.fingerprint = fingerprint
        self.secret = secret
        let clean = SafeText.label(name, limit: Self.nameLimit)
        self.name = clean.isEmpty ? "Mac" : clean
        self.port = port
        self.addresses = Array(addresses.prefix(Self.maxAddresses))
    }

    /// Why a link was refused.
    public enum Failure: Error, Equatable, Sendable {
        /// Not a sill://pair URL at all.
        case notALink
        /// `v` missing or not 1.
        case version
        /// `m`, `k`, `s` or `p` missing, repeated or malformed.
        case field(String)
        /// `m` is not the Mac ID of `k`.
        case macIDMismatch
        /// An `a` the address parser refuses.
        case address(String)
    }

    /// The link as the QR code carries it. Values are percent-encoded down to RFC 3986's unreserved
    /// characters and ":" (URLComponents would leave "&" and "=" inside a value as they are, and a
    /// Mac named "Tom & Jerry" would split the query).
    public var url: String {
        var items: [(String, String)] = [("v", "1"), ("m", macID), ("k", Base64URL.encode(fingerprint)),
                                         ("s", Base64URL.encode(secret)), ("n", name), ("p", String(port))]
        items += addresses.prefix(Self.maxAddresses).map { ("a", $0.text) }
        return "sill://pair?" + items.map { "\($0.0)=\(Self.escape($0.1))" }.joined(separator: "&")
    }

    static func escape(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Parses a link. Refuses `v ≠ 1`; a missing, repeated or malformed `m`, `k`, `s` or `p`;
    /// `m ≠ MacID(k)`; any `a` the address parser refuses. Ignores unknown parameters, keeps the
    /// first 5 addresses, and cleans `n` with SafeText.
    public static func parse(_ text: String) -> Result<PairLink, Failure> {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "sill", c.host?.lowercased() == "pair", c.path.isEmpty || c.path == "/",
              let items = c.queryItems else { return .failure(.notALink) }
        func single(_ key: String) -> Result<String, Failure> {
            let values = items.filter { $0.name == key }
            guard values.count == 1, let v = values[0].value, !v.isEmpty else { return .failure(.field(key)) }
            return .success(v)
        }
        guard case .success(let v) = single("v") else { return .failure(.version) }
        guard v == "1" else { return .failure(.version) }
        guard case .success(let m) = single("m"), MacID.isWellFormed(m) else { return .failure(.field("m")) }
        guard case .success(let k) = single("k"), let fp = Base64URL.decode(k), fp.count == 32 else { return .failure(.field("k")) }
        guard case .success(let s) = single("s"), let secret = Base64URL.decode(s), secret.count == 16 else { return .failure(.field("s")) }
        guard case .success(let p) = single("p"), p.count <= 5, p.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(p), (1...65535).contains(port) else { return .failure(.field("p")) }
        guard m == MacID.make(fingerprint: fp) else { return .failure(.macIDMismatch) }
        var addresses: [ParsedAddress] = []
        for item in items where item.name == "a" {
            guard let raw = item.value, case .success(let a) = AddressParser.parse(raw) else { return .failure(.address(item.value ?? "")) }
            addresses.append(a)
        }
        let names = items.filter { $0.name == "n" }
        return .success(PairLink(fingerprint: fp, secret: secret, name: names.first?.value ?? "", port: port, addresses: addresses))
    }
}
