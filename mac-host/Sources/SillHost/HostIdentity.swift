import Foundation
import Security
import Network
import StreamProtocol

/// A paired device as the trust list stores it (docs/remote-access-plan.md §4.5). Display-only
/// data (when it last connected, and how) is kept elsewhere; this record is what trust rests on.
package struct PairedDevice: Codable, Hashable, Sendable {
    /// base64url of the SHA-256 of its SubjectPublicKeyInfo: the pin.
    package var fingerprint: String
    /// Its own name, cleaned (SafeText): "iPad".
    package var name: String
    /// "iPad14,1".
    package var model: String?
    /// Seconds since 1970.
    package var pairedAt: Double
    /// "qr", "code" or "cable" (paired by itself over the USB cable, docs/home-pairing-plan.md
    /// §4.8; M5 adds "icloud"): how it was trusted.
    package var method: String
    /// The iPhone or iPad this key paired over, or ran a session over, by the USB cable:
    /// CableLink.deviceID of its USB serial number, never the serial. A different key from the
    /// same device then pairs only with the code; Remove frees the device. Nil for a key never seen
    /// on the cable. Optional, so a list from before it decodes, and left out of the JSON when nil.
    package var cableDevice: String?

    package init(fingerprint: String, name: String, model: String?, pairedAt: Double, method: String, cableDevice: String? = nil) {
        self.fingerprint = fingerprint; self.name = name; self.model = model; self.pairedAt = pairedAt; self.method = method
        self.cableDevice = cableDevice
    }

    /// How it was paired, as the Devices pane words it: "with the QR code", "with a code", "over
    /// the USB cable"; nil for a method this build does not know.
    package var displayMethod: String? { Self.displayMethod(method) }

    /// The words for a stored method (`displayMethod`; the pane's summaries use it too).
    package static func displayMethod(_ method: String) -> String? {
        switch method {
        case PairRequest.qr: return "with the QR code"
        case PairRequest.code: return "with a code"
        case PairResult.cable: return "over the USB cable"
        default: return nil
        }
    }

    /// "iPad (iPad14,1)", or the name alone.
    package var displayName: String {
        guard let model, !model.isEmpty else { return name.isEmpty ? "a device" : name }
        return "\(name.isEmpty ? "Device" : name) (\(model))"
    }

    /// The fingerprint's raw bytes; nil for a damaged record, which then trusts nothing.
    package var fingerprintData: Data? { Base64URL.decode(fingerprint).flatMap { $0.count == 32 ? $0 : nil } }
}

/// The Mac's remote identity: its P-256 key, the certificate rebuilt from it at every launch, its
/// fingerprint and Mac ID, the TLS identity both doors present, and the recognition key that makes
/// the Bonjour TXT tag. Immutable once loaded, so any queue may read it.
package final class HostIdentity: @unchecked Sendable {
    package let remote: RemoteIdentity
    package let macID: String
    /// 32 random bytes kept with the key; sent only in kind 20 ok (`PairResult.recognitionKey`).
    package let recognitionKey: Data

    package var fingerprint: Data { remote.fingerprint }

    package init?(privateKey: SecKey, recognitionKey: Data) {
        guard recognitionKey.count == 32, let remote = RemoteIdentity(privateKey: privateKey) else { return nil }
        self.remote = remote
        self.recognitionKey = recognitionKey
        macID = MacID.make(fingerprint: remote.fingerprint)
    }

    /// Kind 18's signature over `info` (SecKeyCreateSignature, ECDSA P-256 / SHA-256).
    package func sign(_ info: MacInfo) -> SignedMacInfo? {
        SignedMacInfo.signing(info, with: remote.privateKey)
    }

    /// An ECDSA P-256 / SHA-256 signature (DER) by the Mac's key over `data`: a record only this Mac
    /// could have written (RequirePairingValue). Nil when the key cannot sign.
    package func signRecord(_ data: Data) -> Data? {
        SecKeyCreateSignature(remote.privateKey, .ecdsaSignatureMessageX962SHA256, data as CFData, nil) as Data?
    }

    /// Whether `signature` is the Mac's key's over `data` (`signRecord`).
    package func verifyRecord(_ data: Data, signature: Data) -> Bool {
        guard let publicKey = SecKeyCopyPublicKey(remote.privateKey) else { return false }
        return SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, data as CFData, signature as CFData, nil)
    }

    /// A fresh TXT record for one Bonjour registration: `r` = a new tag, and `p` (HomeDoorTXT) when
    /// the home door speaks TLS: "1" pairing required, "0" open. A plain door carries no `p`.
    package func txtRecord(homeDoor p: String? = nil) -> NWTXTRecord? {
        guard let tag = RecognitionTag.make(recognitionKey: recognitionKey) else { return nil }
        var entries = [RecognitionTag.txtKey: tag]
        if let p { entries[HomeDoorTXT.key] = p }
        return NWTXTRecord(entries)
    }
}

/// Where the Mac's identity and its trust list live. Three backends: the login keychain
/// (Sill.app), memory (SillHost --remote: nothing outlives the process) and, TEST ONLY, a 0700
/// directory (SILL_TEST_REMOTE_DIR on a host that does not advertise). The trust list never lives
/// in UserDefaults or a plist: any process of the same user can edit those, add its own key, and
/// then use Sill's Screen Recording and Accessibility grants.
package protocol IdentityStore: AnyObject {
    /// For the log: "in memory", "in the test directory …".
    var summary: String { get }
    /// The Mac's P-256 private key, created on first use. Only a key that does not exist yet is
    /// created: any other failure to read one throws, since a new key is a new Mac ID and breaks
    /// every pin.
    func loadOrCreateKey() throws -> SecKey
    /// 32 random bytes, created on first use (the same rule).
    func loadOrCreateRecognitionKey() throws -> Data
    /// The trust list: empty only when none was ever saved. One that cannot be read throws, or the
    /// next save would replace it.
    func loadPaired() throws -> [PairedDevice]
    func savePaired(_ devices: [PairedDevice]) throws
    /// Require pairing (docs/home-pairing-plan.md §4.8), kept beside the trust list and never in
    /// UserDefaults, as the record RemoteAccess writes and judges (RequirePairingValue: off only
    /// with the Mac's own signature): nil when none was ever saved, which reads as on, so a missing
    /// item only ever turns pairing on. A read that fails throws (the caller then counts it as on).
    /// Its own item, not a field of the trust list: an older Sill reading a changed list would call
    /// it damaged and lose its identity.
    func loadRequirePairing() throws -> Data?
    func saveRequirePairing(_ record: Data) throws
    /// TEST ONLY: a directory where a test hook may leave the current pairing link and code (the
    /// file store's own, 0700); nil for every other store.
    var testDirectory: URL? { get }
}

package struct IdentityStoreError: Error, CustomStringConvertible {
    package let description: String
    package init(_ description: String) { self.description = description }
}

/// SillHost --remote: a new identity and an empty trust list every run.
package final class MemoryIdentityStore: IdentityStore {
    private var key: SecKey?
    private var recognition: Data?
    private var paired: [PairedDevice] = []

    package init() {}

    package var summary: String { "in memory" }
    package var testDirectory: URL? { nil }

    package func loadOrCreateKey() throws -> SecKey {
        if let key { return key }
        guard let k = RemoteKey.generate() else { throw IdentityStoreError("no P-256 key could be made") }
        key = k
        return k
    }

    package func loadOrCreateRecognitionKey() throws -> Data {
        if let recognition { return recognition }
        let r = try Self.randomBytes(32)
        recognition = r
        return r
    }

    package func loadPaired() throws -> [PairedDevice] { paired }
    package func savePaired(_ devices: [PairedDevice]) throws { paired = devices }

    private var requirePairing: Data?
    package func loadRequirePairing() throws -> Data? { requirePairing }
    package func saveRequirePairing(_ record: Data) throws { requirePairing = record }

    static func randomBytes(_ n: Int) throws -> Data {
        var b = [UInt8](repeating: 0, count: n)
        guard SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess else { throw IdentityStoreError("the random source failed") }
        return Data(b)
    }
}

/// TEST ONLY (SILL_TEST_REMOTE_DIR=<dir>, honoured only by a host that does not advertise): the
/// identity and trust list in a directory of mode 0700, each file 0600, so a test can pair, restart
/// the host and find the same Mac ID and pairings, without the login keychain.
/// Files: `host-key` (the private key, X9.63), `recognition-key` (32 bytes), `paired.json`,
/// `require-pairing` (RequirePairingValue's record; no file reads as on), and `.lock`, which one
/// host holds for as long as it uses the directory: two hosts sharing it would each save their own
/// list over the other's.
package final class FileIdentityStore: IdentityStore {
    package let directory: URL
    /// The open `.lock`, flock'ed exclusively; closing it (or the process ending) lets it go.
    private let lock: Int32

    package init(directory: URL) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent(".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IdentityStoreError("\(path) could not be opened (errno \(errno))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw IdentityStoreError("\(directory.path) is in use by another Sill host")
        }
        lock = fd
    }

    deinit { close(lock) }

    package var summary: String { "in the test directory \(directory.path)" }
    package var testDirectory: URL? { directory }

    package func loadOrCreateKey() throws -> SecKey {
        let url = directory.appendingPathComponent("host-key")
        if let data = try Self.read(url) {
            guard let key = RemoteKey.importPrivate(data) else { throw IdentityStoreError("\(url.path) is not a P-256 key") }
            return key
        }
        guard let key = RemoteKey.generate(), let data = RemoteKey.export(key) else { throw IdentityStoreError("no P-256 key could be made") }
        try Self.writePrivate(data, to: url)
        return key
    }

    package func loadOrCreateRecognitionKey() throws -> Data {
        let url = directory.appendingPathComponent("recognition-key")
        if let data = try Self.read(url) {
            guard data.count == 32 else { throw IdentityStoreError("\(url.path) is not 32 bytes") }
            return data
        }
        let data = try MemoryIdentityStore.randomBytes(32)
        try Self.writePrivate(data, to: url)
        return data
    }

    package func loadPaired() throws -> [PairedDevice] {
        let url = directory.appendingPathComponent("paired.json")
        guard let data = try Self.read(url) else { return [] }
        guard let list = try? JSONDecoder().decode([PairedDevice].self, from: data) else { throw IdentityStoreError("\(url.path) is damaged") }
        return list
    }

    /// The file's bytes, or nil when it does not exist yet. Anything else (no permission, an I/O
    /// error) throws: taken for "missing", it would make a new key (a new Mac ID, every pin broken)
    /// or an empty trust list that the next pairing saves over the real one.
    private static func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw IdentityStoreError("\(url.path) could not be read (\(error.localizedDescription))")
        }
    }

    package func savePaired(_ devices: [PairedDevice]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.writePrivate(try encoder.encode(devices), to: directory.appendingPathComponent("paired.json"))
    }

    package func loadRequirePairing() throws -> Data? {
        try Self.read(directory.appendingPathComponent("require-pairing"))
    }

    package func saveRequirePairing(_ record: Data) throws {
        try Self.writePrivate(record, to: directory.appendingPathComponent("require-pairing"))
    }

    /// Writes `data` with mode 0600 from its creation, replacing the file atomically. Also the
    /// app's -SillPairAfter hook, for the pairing link and code a test reads (never printed).
    package static func writePrivate(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw IdentityStoreError("could not write \(tmp.path)")
        }
        guard rename(tmp.path, url.path) == 0 else { throw IdentityStoreError("could not replace \(url.path)") }
    }
}

/// Require pairing's stored record, in every store: "1" on; off only as "0." and a signature by
/// this Mac's own key over `offMessage` (HostIdentity.signRecord), which names the Mac. Anything
/// else reads as on, the safe side: a missing record (Sill saves one only when the switch changes),
/// a plain "0", a signature by another key or for another Mac, bytes that are not a record. Any
/// process of this user can create the keychain item before Sill has ever saved it, with Sill among
/// the apps its access control lets read it without asking, and a plain "0" there turned pairing off
/// behind Sill's back: every app on this Mac could then reach the home door over loopback and use
/// Sill's Screen Recording and Accessibility (the security review, 2026-09-27). It cannot sign with
/// the Mac's key, which the keychain keeps for Sill alone.
enum RequirePairingValue {
    static let on = Data("1".utf8)

    /// What the Mac's key signs to turn pairing off: the purpose and the Mac ID, so a record never
    /// stands for another thing or another Mac.
    static func offMessage(macID: String) -> Data { Data("sill-require-pairing-off-v1\n\(macID)".utf8) }

    /// The record for `on`: "1", or "0." and base64url of `sign(offMessage)`; nil when `sign` gives
    /// nothing (the key could not sign), and then nothing is saved.
    static func encode(_ on: Bool, macID: String, sign: (Data) -> Data?) -> Data? {
        if on { return Self.on }
        guard let signature = sign(offMessage(macID: macID)), !signature.isEmpty else { return nil }
        return Data(("0." + Base64URL.encode(signature)).utf8)
    }

    /// Whether a stored record means on: true for anything but "0." and a signature `verify` takes
    /// for this Mac's off message.
    static func decode(_ data: Data, macID: String, verify: (_ message: Data, _ signature: Data) -> Bool) -> Bool {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("0."),
              let signature = Base64URL.decode(String(text.dropFirst(2))), !signature.isEmpty else { return true }
        return !verify(offMessage(macID: macID), signature)
    }
}

/// What both doors' verify blocks and admission read on the network queue: immutable, replaced
/// whole under a lock on every change. Nothing that reads it ever waits on the main actor.
struct TrustSnapshot: Sendable {
    /// Paired fingerprints → display names ("iPad (iPad14,1)").
    var paired: [Data: String] = [:]
    /// A pairing window is open: the home door takes its proofs.
    var pairingOpen = false
    /// One the remote door takes proofs for (opened by the Mac's user, or the CLI's --remote),
    /// never one a device opened by asking (docs/home-pairing-plan.md §4.6).
    var remotePairingOpen = false
    var remoteAccess = false
    var internetAccess = false
    /// The home door admits only paired keys (on a TLS home door; the plain one has no pairing).
    var requirePairing = true
    /// Interface → network service name ("utun4" → "Tailscale"), for a session's route label.
    var serviceNames: [String: String] = [:]
}

/// The lock around the current TrustSnapshot.
final class TrustBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = TrustSnapshot()

    var snapshot: TrustSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func update(_ change: (inout TrustSnapshot) -> Void) {
        lock.lock(); change(&value); lock.unlock()
    }
}
