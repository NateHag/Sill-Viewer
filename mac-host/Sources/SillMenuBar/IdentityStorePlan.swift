import Foundation

/// Which identity store the menu-bar host uses, and why (docs/keychain-plan.md). Pure: it turns
/// four launch facts into one choice, so the rule is checked on its own (Tests/checks/keychain)
/// without a keychain, a bundle or a signature. AppModel reads the facts (its bundle, its arguments,
/// its own entitlements) and builds the store the choice names.
enum IdentityStoreChoice: Equatable {
    /// Sill.app entitled to a keychain access group (a Developer ID build with an embedded
    /// provisioning profile): the data-protection keychain under that group, which only a process of
    /// the same team and entitlement can read or create. Never the legacy store beside it, so a
    /// legacy item another process planted before the first launch cannot be adopted.
    case dataProtection(accessGroup: String)
    /// Sill.app without that entitlement (a development build signed Apple Development, or a release
    /// with no embedded profile): the legacy login keychain, as remote access shipped it. Safe by
    /// necessity — the entitlement, hence the strong keychain, needs a profile — and every real user
    /// runs the entitled Developer ID build.
    case legacy
    /// A test host that never touches a keychain: `--synthetic`, or the bare SillMenuBar binary
    /// (whose ad hoc signature changes every build). Nothing outlives the process.
    case memory
    /// TEST ONLY (SILL_TEST_REMOTE_DIR): the bare `--synthetic` binary keeps the identity in a 0700
    /// directory, so a test can pair, restart and find the same Mac ID.
    case testDirectory(String)
}

enum IdentityStorePlan {
    /// The store for this launch (docs/keychain-plan.md §4).
    ///
    /// - `bundled`: running from a `.app` (real Sill.app), not the bare SillMenuBar test binary.
    /// - `synthetic`: `--synthetic` (a test host, off Bonjour).
    /// - `entitledAccessGroup`: the `keychain-access-groups` value the running binary actually holds,
    ///   read from its own signature at launch (nil for any build without an embedded profile: every
    ///   development and ad hoc build, as measured — an unentitled binary reads its own entitlement
    ///   as nil). Non-nil means the data-protection keychain is reachable under that group.
    /// - `testRemoteDir`: SILL_TEST_REMOTE_DIR, already trimmed to non-empty by the caller.
    ///
    /// The one rule that matters for the hardening: an entitled real Sill.app uses the
    /// data-protection keychain and never the legacy one, so no planted legacy item is ever adopted;
    /// an unentitled real Sill.app uses the legacy keychain (the safe, profile-free fallback).
    static func choose(bundled: Bool, synthetic: Bool, entitledAccessGroup: String?, testRemoteDir: String?) -> IdentityStoreChoice {
        // A test host — the bare binary, or Sill.app run with --synthetic — keeps nothing in a
        // keychain: its signature is not stable, and a test must never write the login keychain.
        if synthetic || !bundled {
            if synthetic, !bundled, let dir = testRemoteDir, !dir.isEmpty { return .testDirectory(dir) }
            return .memory
        }
        // Real Sill.app: the data-protection keychain only when entitled to a group, and then only
        // that — never the legacy store as well. Otherwise the legacy login keychain.
        if let group = entitledAccessGroup, !group.isEmpty { return .dataProtection(accessGroup: group) }
        return .legacy
    }
}
