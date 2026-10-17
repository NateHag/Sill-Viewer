import Foundation
import Security
import CryptoKit

// Identities for the remote door (docs/remote-access-plan.md §3.4): one P-256 key per Mac install
// and one per device install. Nothing here names or dates anything that matters: trust is the key
// itself, pinned as the SHA-256 of its SubjectPublicKeyInfo. Shared by the host, the device and the
// test checks; Foundation, Security and CryptoKit only.

/// base64url without padding (RFC 4648 §5): every byte string in the pairing link, kind 19 and
/// kind 20.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Nil for anything that is not canonical unpadded base64url (padding, the standard alphabet's
    /// + and /, whitespace, a length no encoding produces).
    public static func decode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              text.count % 4 != 1 else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let d = Data(base64Encoded: s), encode(d) == text else { return nil }
        return d
    }
}

/// The SubjectPublicKeyInfo of a P-256 key and its SHA-256, the fingerprint every pin compares.
public enum SPKI {
    /// `SEQUENCE { SEQUENCE { OID 1.2.840.10045.2.1, OID 1.2.840.10045.3.1.7 }, BIT STRING (0x00 ‖ point) }`
    /// for a 65-byte uncompressed X9.63 point (04 ‖ X ‖ Y).
    public static func der(point: Data) -> Data {
        Data(DER.sequence([DER.sequence([DER.oid(DER.ecPublicKey), DER.oid(DER.prime256v1)]), DER.bitString([UInt8](point))]))
    }

    /// SHA-256 of `der(point:)`: 32 bytes; 43 characters as base64url.
    public static func fingerprint(point: Data) -> Data {
        Data(SHA256.hash(data: der(point: point)))
    }

    /// The fingerprint of a P-256 public (or private) key; nil for any other kind of key.
    public static func fingerprint(of key: SecKey) -> Data? {
        let pub = SecKeyCopyPublicKey(key) ?? key
        guard let attrs = SecKeyCopyAttributes(pub) as? [String: Any],
              (attrs[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String),
              (attrs[kSecAttrKeySizeInBits as String] as? Int) == 256,
              let point = SecKeyCopyExternalRepresentation(pub, nil) as Data?, point.count == 65, point.first == 0x04
        else { return nil }
        return fingerprint(point: point)
    }

    /// The fingerprint of a certificate's key when it is P-256, else nil. Nothing else about the
    /// certificate is looked at: names, dates and chains mean nothing to a pin.
    public static func fingerprint(of certificate: SecCertificate) -> Data? {
        SecCertificateCopyKey(certificate).flatMap { fingerprint(of: $0) }
    }
}

/// The Mac ID: Crockford base32 of the fingerprint's first 10 bytes (80 bits, most significant bits
/// first), 16 characters. It keys saved Macs; a device always checks `macID == MacID.make(fp)`.
public enum MacID {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func make(fingerprint: Data) -> String {
        let bytes = [UInt8](fingerprint.prefix(10))
        guard bytes.count == 10 else { return "" }
        var out = ""
        var buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b); bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        return out
    }

    /// Whether `text` is 16 characters of the Crockford alphabet (upper case, as generated).
    public static func isWellFormed(_ text: String) -> Bool {
        text.count == 16 && text.allSatisfy { alphabet.contains($0) }
    }
}

/// A minimal X.509 v3 certificate, built by hand because no Apple API creates one
/// (`SecCertificateCreateWithData` only parses) and a package would be a dependency. Checked by
/// `SecCertificateCreateWithData`, by Network.framework on both ends and by `openssl x509`.
public enum SelfSignedCertificate {
    /// Self-signed with `key` (a P-256 private key) by ECDSA with SHA-256: version 3, no extensions,
    /// a 16-byte random serial, issuer = subject = a CN of 16 random hex characters (it names
    /// nothing, so a certificate says nothing about the Mac or the device), valid from 2026-01-01
    /// to 9999-12-31. About 310 bytes. Rebuilt at every launch from the stored key: the pin is the
    /// key, so the certificate is never stored. Nil if the key cannot sign.
    public static func make(key: SecKey) -> Data? {
        guard let pub = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(pub, nil) as Data?, point.count == 65 else { return nil }
        var cn = [UInt8](repeating: 0, count: 8)
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, cn.count, &cn) == errSecSuccess,
              SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else { return nil }
        serial[0] = (serial[0] & 0x7F) | 0x01          // positive, and no leading zero byte to trim
        let hex = cn.map { String(format: "%02x", $0) }.joined()
        let name = DER.sequence([DER.set([DER.sequence([DER.oid(DER.commonName), DER.tlv(0x0C, Array(hex.utf8))])])])
        let algorithm = DER.sequence([DER.oid(DER.ecdsaWithSHA256)])
        let tbs = DER.sequence([
            DER.tlv(0xA0, DER.integer([2])),                      // [0] EXPLICIT version: v3
            DER.integer(serial),
            algorithm,
            name,                                                 // issuer
            DER.sequence([DER.tlv(0x17, Array("260101000000Z".utf8)),     // UTCTime
                          DER.tlv(0x18, Array("99991231235959Z".utf8))]), // GeneralizedTime
            name,                                                 // subject
            [UInt8](SPKI.der(point: point)),
        ])
        guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, nil) as Data? else { return nil }
        return Data(DER.sequence([tbs, algorithm, DER.bitString([UInt8](sig))]))
    }
}

/// A key and the certificate made from it, ready for TLS: what `RemoteTLS.options` presents.
/// The host builds one from its stored key at launch, the device from its own.
public struct RemoteIdentity: @unchecked Sendable {
    public let privateKey: SecKey
    public let certificate: SecCertificate
    public let certificateDER: Data
    /// SHA-256 of the SPKI: this identity's pin.
    public let fingerprint: Data
    public let tls: sec_identity_t

    /// Builds the certificate and the TLS identity for `privateKey` (P-256). Nil when the key is
    /// not P-256, cannot sign, or the system refuses the result.
    public init?(privateKey: SecKey) {
        guard let fp = SPKI.fingerprint(of: privateKey),
              let der = SelfSignedCertificate.make(key: privateKey),
              let cert = SecCertificateCreateWithData(nil, der as CFData),
              SPKI.fingerprint(of: cert) == fp,
              let identity = SecIdentityCreate(nil, cert, privateKey),
              let tls = sec_identity_create(identity) else { return nil }
        self.privateKey = privateKey
        certificate = cert
        certificateDER = der
        fingerprint = fp
        self.tls = tls
    }

    /// "5KD2Q7": the first characters of the Mac ID form of a fingerprint, for log lines and lists.
    public static func shortName(_ fingerprint: Data) -> String { String(MacID.make(fingerprint: fingerprint).prefix(6)) }
}

/// P-256 keys that live only in memory (the CLI's --remote, test identities) or in a file (TEST
/// ONLY stores). The app's and the device's keychain keys are made by their own stores.
public enum RemoteKey {
    /// A fresh P-256 private key, never stored anywhere.
    public static func generate() -> SecKey? {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecAttrKeySizeInBits as String: 256]
        return SecKeyCreateRandomKey(attrs as CFDictionary, nil)
    }

    /// The private key as X9.63 (04 ‖ X ‖ Y ‖ D, 97 bytes), for a TEST ONLY file store.
    public static func export(_ key: SecKey) -> Data? {
        guard let d = SecKeyCopyExternalRepresentation(key, nil) as Data?, d.count == 97 else { return nil }
        return d
    }

    /// A private key back from `export`.
    public static func importPrivate(_ data: Data) -> SecKey? {
        guard data.count == 97 else { return nil }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                    kSecAttrKeySizeInBits as String: 256]
        return SecKeyCreateWithData(data as CFData, attrs as CFDictionary, nil)
    }

    /// The public key's 65-byte X9.63 point (04 ‖ X ‖ Y).
    public static func publicPoint(_ key: SecKey) -> Data? {
        let pub = SecKeyCopyPublicKey(key) ?? key
        guard let d = SecKeyCopyExternalRepresentation(pub, nil) as Data?, d.count == 65 else { return nil }
        return d
    }
}

/// Just enough DER for one certificate and one SPKI.
enum DER {
    static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]          // 1.2.840.10045.2.1
    static let prime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]     // 1.2.840.10045.3.1.7
    static let ecdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02] // 1.2.840.10045.4.3.2
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]                                    // 2.5.4.3

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [[UInt8]]) -> [UInt8] { tlv(0x31, parts.flatMap { $0 }) }
    static func oid(_ bytes: [UInt8]) -> [UInt8] { tlv(0x06, bytes) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + bytes) }
    /// A non-negative INTEGER from big-endian bytes: minimal, with a 0x00 in front when the top bit is set.
    static func integer(_ raw: [UInt8]) -> [UInt8] {
        var b = raw.isEmpty ? [0] : raw
        while b.count > 1 && b[0] == 0 && b[1] & 0x80 == 0 { b.removeFirst() }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }
}
