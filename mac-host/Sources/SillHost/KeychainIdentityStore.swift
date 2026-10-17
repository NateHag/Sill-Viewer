import Foundation
import Security

/// Sill.app's identity store (docs/remote-access-plan.md §4.5, docs/keychain-plan.md): the Mac's key
/// and trust list in a keychain, in one of two keychains chosen at launch.
///
/// - **Legacy (`accessGroup` nil):** the file-based login keychain, as remote access first shipped.
///   Every item keeps the default access control, which trusts the app that made it by its
///   designated requirement, and that requirement survives rebuilds signed with the same identity,
///   as the TCC grants do. But the login keychain **does not authenticate who made an item**: any
///   process of this user can create an item first, list Sill among the apps allowed to read it, and
///   Sill then adopts it (the security review, 2026-09-27). So this store is used only where the
///   strong keychain is out of reach — a development build, or a release with no embedded
///   provisioning profile — and never by an entitled Sill.app.
/// - **Data-protection (`accessGroup` set, e.g. `9B2KKVM937.me.saffer.sill.mac`):** the
///   data-protection keychain under that access group. Only a process signed by the same team and
///   entitled to that group can create or read the items, so no other process can pre-create or read
///   them: the pre-creation hole is closed, and the key becomes unreadable to other apps as a bonus.
///   Reaching this keychain needs the `keychain-access-groups` entitlement, hence a provisioning
///   profile embedded in the build (Scripts/make-app.sh --release, docs/release-checklist.md);
///   IdentityStorePlan picks it only when the running binary actually holds the entitlement.
///
/// The items, in either keychain:
/// - The key: a permanent P-256 private key, application tag `me.saffer.sill.remote.host-key`,
///   label "Sill Remote Access", looked up by its tag. Only the private key is stored; the public
///   one is derived from it.
/// - The recognition key: a generic password, service `me.saffer.sill.remote`, account
///   `recognition-key`, 32 bytes.
/// - The trust list: a generic password, same service, account `paired-devices`, JSON.
/// - Require pairing: a generic password, same service, account `require-pairing`: "1", or "0."
///   and a signature by the Mac's key (RequirePairingValue, docs/home-pairing-plan.md §4.8). A
///   missing item, or one without that signature, reads as on, so deleting it only turns pairing on.
///
/// **No migration from the login keychain — by design (the security review, 2026-09-27).** An
/// earlier draft copied a Mac's existing legacy items into the data-protection keychain on the first
/// entitled launch, to keep the Mac ID and pairings across the update. That reopened the very hole
/// this change closes: the login keychain cannot say who made an item, so the adoption code would
/// have adopted a *planted* legacy key just as readily as Sill's own, promoting an attacker's key
/// into the strong keychain as the Mac's permanent identity — and there is no sound gate on the
/// legacy side to tell the two apart (§3, §4 of docs/keychain-plan.md; ACL inspection is forgeable).
/// So in data-protection mode this store **never reads the login keychain**: every query is pinned to
/// the data-protection keychain by `scope()`, and a fresh install (or an entitled build's first
/// launch on a Mac that had legacy items) simply creates a fresh key straight in the strong keychain,
/// where the pre-creation guarantee is whole. This lands before the first public build, so the only
/// Macs with legacy items are Noah's own dev Macs, which do a one-time reset once (delete the legacy
/// items and re-pair; docs/keychain-plan.md §6, release-checklist.md Part 1 §5); public installs have
/// nothing to migrate.
///
/// Only an item that does not exist yet in this keychain is created. Any other failure to read one
/// throws: a new key would be a new Mac ID (every device's pin broken), and an empty list saved over
/// an unreadable one would forget every pairing. RemoteAccess then runs without an identity and the
/// pane says why.
///
/// **Availability (data-protection mode).** Every item is `AfterFirstUnlockThisDeviceOnly`: readable
/// once the Mac has been unlocked after boot, so remote access works while the screen is later locked
/// (its whole point is a Mac left at home while its owner is away), but never synced to iCloud and
/// never carried to another Mac in a keychain restore, so the identity key cannot leave this Mac
/// (the same posture as the iOS device key, WhenUnlockedThisDeviceOnly). The legacy store keeps the
/// login keychain's own default, as it always did.
package final class KeychainIdentityStore: IdentityStore {
    static let keyTag = Data("io.github.natehag.sill-desktop-host.remote.host-key".utf8)
    static let label = "Sill Remote Access"
    static let service = "io.github.natehag.sill-desktop-host.remote"
    static let recognitionAccount = "recognition-key"
    static let pairedAccount = "paired-devices"
    static let requirePairingAccount = "require-pairing"

    /// The data-protection access group, or nil for the legacy login keychain. Immutable.
    let accessGroup: String?
    private var dataProtection: Bool { accessGroup != nil }

    /// `accessGroup` nil is the legacy login keychain; a group name is the data-protection keychain.
    package init(accessGroup: String? = nil) { self.accessGroup = accessGroup }

    package var summary: String {
        guard let accessGroup else { return "in the login keychain" }
        return "in the data-protection keychain (\(accessGroup))"
    }
    package var testDirectory: URL? { nil }

    /// The keychain-selecting attributes added to every query: the data-protection flag and access
    /// group when this store is the strong one, nothing for the legacy store. Pinning every query to
    /// the data-protection keychain is what makes the "never reads the login keychain" guarantee hold.
    private func scope() -> [String: Any] {
        guard let accessGroup else { return [:] }
        return [kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: accessGroup]
    }

    /// The accessibility a new data-protection item is created with: readable after the first unlock
    /// (so remote access works while the Mac's screen is later locked), this device only (never
    /// synced, never restored to another Mac). Nothing for the legacy store — it keeps the login
    /// keychain's default, unchanged from before this change. See the type.
    private var accessible: CFString? { dataProtection ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : nil }

    package func loadOrCreateKey() throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ]
        query.merge(scope()) { _, new in new }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() {
            return item as! SecKey      // the type was just checked
        }
        guard status == errSecItemNotFound else { throw Self.error("the key couldn’t be read", status) }
        // No key here: make a fresh one. In data-protection mode this store never reads the login
        // keychain (no migration: it could not tell Sill's own legacy key from a planted one — see
        // the type), so a Mac with only a legacy key gets a fresh Mac ID and re-pairs; that is why
        // this lands before the first public build, when only Noah's own dev Macs have legacy items.
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.keyTag,
                kSecAttrLabel as String: Self.label,
            ] as [String: Any],
        ]
        if let accessGroup {
            // For SecKeyCreateRandomKey the data-protection flag, access group and accessibility go
            // inside the private-key attributes, beside kSecAttrIsPermanent, so the stored key lands
            // in the data-protection keychain under the group, readable after the first unlock and
            // never off this Mac.
            var priv = attributes[kSecPrivateKeyAttrs as String] as! [String: Any]
            priv[kSecAttrAccessGroup as String] = accessGroup
            priv[kSecUseDataProtectionKeychain as String] = true
            if let accessible { priv[kSecAttrAccessible as String] = accessible }
            attributes[kSecPrivateKeyAttrs as String] = priv
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let reason = error.map { "\($0.takeRetainedValue())" } ?? "no reason given"
            throw IdentityStoreError("no key could be made in the keychain (\(reason))")
        }
        return key
    }

    package func loadOrCreateRecognitionKey() throws -> Data {
        if let data = try read(Self.recognitionAccount) {
            guard data.count == 32 else { throw IdentityStoreError("the recognition key in the keychain is damaged") }
            return data
        }
        let data = try MemoryIdentityStore.randomBytes(32)
        try write(data, account: Self.recognitionAccount, label: "\(Self.label) (recognition key)")
        return data
    }

    package func loadPaired() throws -> [PairedDevice] {
        guard let data = try read(Self.pairedAccount) else {
            // None saved yet: made now, empty, so the item is Sill's own from here on (see the type).
            // A write that fails changes nothing: the list is empty either way.
            try? savePaired([])
            return []
        }
        guard let list = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            throw IdentityStoreError("the paired devices in the keychain are damaged")
        }
        return list
    }

    package func savePaired(_ devices: [PairedDevice]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(devices), account: Self.pairedAccount, label: "\(Self.label) (paired devices)")
    }

    package func loadRequirePairing() throws -> Data? {
        try read(Self.requirePairingAccount)
    }

    package func saveRequirePairing(_ record: Data) throws {
        try write(record, account: Self.requirePairingAccount, label: "\(Self.label) (require pairing)")
    }

    // MARK: Generic passwords

    /// The item's bytes, or nil when it does not exist yet; anything else throws (see the type). In
    /// data-protection mode the query is pinned to the data-protection keychain (`scope()`), so a
    /// miss is a genuine miss — the login keychain is never consulted (no migration; see the type).
    private func read(_ account: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        query.merge(scope()) { _, new in new }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Self.error("\(account) couldn’t be read", status) }
        return data
    }

    /// Replaces the item's bytes, or adds it (in this store's keychain). A new item in
    /// data-protection mode is created `AfterFirstUnlockThisDeviceOnly` (see the type).
    private func write(_ data: Data, account: String, label: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        query.merge(scope()) { _, new in new }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Self.error("\(account) couldn’t be saved", updated) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        if let accessible { add[kSecAttrAccessible as String] = accessible }
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.error("\(account) couldn’t be saved", added) }
    }

    private static func error(_ what: String, _ status: OSStatus) -> IdentityStoreError {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "error \(status)"
        return IdentityStoreError("\(what): \(message)")
    }
}
