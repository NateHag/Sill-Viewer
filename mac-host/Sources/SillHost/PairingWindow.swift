import Foundation
import CryptoKit
import StreamProtocol

/// One pairing window's rules (docs/remote-access-plan.md §4.6): open for 5 minutes, for one
/// device, with at most five wrong proofs, spaced out so nobody can hammer it. Pure (no clock, no
/// I/O: `now` is passed in), so it is checked on its own with swiftc. RemoteAccess owns one on
/// the main actor.
struct PairingWindow {
    enum CloseReason: String, Sendable {
        /// A device paired with it.
        case used
        /// Its 5 minutes ran out (noticed at the next attempt, or by the owner's timer).
        case expired
        /// Five wrong proofs.
        case stopped
        /// The Mac's user closed it, or Remote Access went off.
        case cancelled
        /// The device whose ask opened it no longer needs it: it gave up (its own Cancel, kind 19
        /// "cancel") or paired another way (over the USB cable). Nobody is kept waiting for it.
        case withdrawn
        /// No window was ever opened.
        case none
    }

    /// Who put a window up by asking (docs/home-pairing-plan.md §4.7): the asking key and its
    /// address, for AskLimits' quiet rule, and where it asked from, for the window's copy.
    struct DeviceAsk: Equatable {
        let fingerprint: Data
        let source: String
        /// "on this network", "nearby" (peer-to-peer Wi-Fi) or "on this Mac".
        var from: String = "on this network"
    }

    struct Open {
        /// The QR path's key (16 bytes).
        let secret: Data
        /// The typed path's 12 digits.
        let code: String
        /// K from the code (PBKDF2, ~0.1 s, derived off the main actor); nil until then.
        var codeKey: SymmetricKey?
        let expiresAt: Double
        var failures = 0
        var nextAllowedAt: Double = 0
        var lastAttemptBySource: [String: Double] = [:]
        let requestedBy: String?
        var lastWrongFrom: String?
        /// A device opened it by asking (an ask at the home door, or kind 21 from an unpaired
        /// session); nil when the Mac's user opened it.
        var byDevice: DeviceAsk?
        /// The remote door runs for it and takes its proofs: a window the Mac's user opened (or the
        /// CLI's with --remote), and every window on a plain home door, which takes no proof at
        /// all. Never one a device opened at a TLS home door, until the Mac's user opens a window
        /// over it (`makeRemote`); a device's ask never takes it away.
        var forRemote = true
    }

    enum State {
        case closed(CloseReason)
        case open(Open)
    }

    enum Verdict: Equatable {
        /// The proof holds: send proof_M. The window is now closed (used).
        case accept(proofM: Data)
        /// A wrong proof; this many are still taken.
        case reject(triesLeft: Int)
        /// Not now: too soon after a wrong one, the same source within 5 s, or a typed code
        /// before its key is ready. Nothing counted.
        case busy(retryAfter: Double)
        /// No window, or it just closed (expired, or stopped by this very proof, the fifth wrong one).
        case closed(CloseReason)
    }

    static let lifetime: Double = 300
    static let maxFailures = 5
    /// The same source may try once per this many seconds.
    static let sourceSpacing: Double = 5
    /// After the 1st, 2nd, 3rd and 4th wrong proof, the next is taken 1, 2, 4, then 8 s later.
    static let spacing: [Double] = [1, 2, 4, 8]

    private(set) var state: State = .closed(.none)

    var isOpen: Bool { if case .open = state { return true }; return false }
    var current: Open? { if case .open(let w) = state { return w }; return nil }
    var closeReason: CloseReason? { if case .closed(let r) = state { return r }; return nil }

    /// Opens a fresh window (a new secret and code), replacing any other.
    mutating func open(secret: Data, code: String, now: Double, lifetime: Double = Self.lifetime, requestedBy: String?,
                       byDevice: DeviceAsk? = nil, forRemote: Bool = true) {
        state = .open(Open(secret: secret, code: code, expiresAt: now + lifetime, requestedBy: requestedBy,
                           byDevice: byDevice, forRemote: forRemote))
    }

    /// The Mac's user opened a window while this one is up: the same code becomes the remote
    /// door's too. Whether it changed anything.
    mutating func makeRemote() -> Bool {
        guard case .open(var w) = state, !w.forRemote else { return false }
        w.forRemote = true
        state = .open(w)
        return true
    }

    /// K for `code`, once derived; ignored when the window has moved on to another code.
    mutating func setCodeKey(_ key: SymmetricKey, code: String) {
        guard case .open(var w) = state, w.code == code else { return }
        w.codeKey = key
        state = .open(w)
    }

    mutating func close(_ reason: CloseReason) {
        guard isOpen else { return }
        state = .closed(reason)
    }

    /// Closes it as expired when its time is up. Whether it did.
    mutating func expireIfDue(now: Double) -> Bool {
        guard case .open(let w) = state, now >= w.expiresAt else { return false }
        state = .closed(.expired)
        return true
    }

    /// Kind 20's reason for a proof the window turned away closed (`Verdict.closed`): "stopped" for
    /// the proof that stopped it (the fifth wrong one), "expired" for any proof after its time ran
    /// out, else "closed": no window, one used or withdrawn, one the Mac's user cancelled, and every
    /// proof after a stop. What the device says then (DiscoveryPolicy.homeRefusal) follows from it.
    static func closedReason(_ reason: CloseReason, stoppedByThisProof: Bool) -> String {
        if reason == .stopped && stoppedByThisProof { return PairResult.stopped }
        if reason == .expired { return PairResult.expired }
        return PairResult.closed
    }

    /// Judges one PairRequest's proof. `fpDevice` and `fpMac` are the two keys of the TLS session
    /// it arrived on, never anything the message says; `source` is the connection's address.
    mutating func tryProof(method: String, proof: Data, fpDevice: Data, fpMac: Data, source: String, now: Double) -> Verdict {
        guard case .open(var w) = state else { return .closed(closeReason ?? .none) }
        if now >= w.expiresAt {
            state = .closed(.expired)
            return .closed(.expired)
        }
        if now < w.nextAllowedAt { return .busy(retryAfter: w.nextAllowedAt - now) }
        if let last = w.lastAttemptBySource[source], now - last < Self.sourceSpacing {
            return .busy(retryAfter: Self.sourceSpacing - (now - last))
        }
        let key: SymmetricKey?
        switch method {
        case PairRequest.qr: key = PairingProof.qrKey(secret: w.secret)
        case PairRequest.code:
            guard let k = w.codeKey else { return .busy(retryAfter: 1) }
            key = k
        default: key = nil          // an unknown method never matches: a wrong proof
        }
        w.lastAttemptBySource[source] = now
        if let key, PairingProof.isValidDeviceProof(proof, key: key, deviceFingerprint: fpDevice, macFingerprint: fpMac) {
            state = .closed(.used)
            return .accept(proofM: PairingProof.macProof(key: key, macFingerprint: fpMac, deviceFingerprint: fpDevice))
        }
        w.failures += 1
        w.lastWrongFrom = source
        if w.failures >= Self.maxFailures {
            state = .closed(.stopped)
            return .closed(.stopped)
        }
        w.nextAllowedAt = now + Self.spacing[min(w.failures - 1, Self.spacing.count - 1)]
        state = .open(w)
        return .reject(triesLeft: Self.maxFailures - w.failures)
    }
}

/// How often devices may put a code on this Mac's screen by asking (docs/home-pairing-plan.md
/// §4.7, the ask rule's step 5): at most `maxWindows` device-opened windows in any `span`, and a
/// device whose window the Mac's user cancelled, or that stopped after five wrong codes, opens none
/// for `quietFor`, by its key and by its address, so a stranger asking again with a new key from
/// the same address, or from a new address with the same key, stays quiet. A window that simply
/// ran out, or that its device withdrew, quiets nobody (the security review, 2026-09-27): its
/// person, tapping again, gets a fresh code, as the device's words say, and `maxWindows` still
/// bounds how often a device can put one up. One window at a time is the ask rule's own step 3.
/// Pure (no clock: `now` is passed in; the caller uses a monotonic one, so a clock change moves
/// nothing), checked on its own with swiftc. RemoteAccess owns one on the main actor.
struct AskLimits {
    static let quietFor: Double = 600
    static let span: Double = 600
    static let maxWindows = 3

    /// This host's `quietFor` and `span`: both 600 s, or SILL_TEST_ASK_QUIET's (`testSeconds`).
    let quietSeconds: Double
    let spanSeconds: Double

    /// When each device-opened window within `spanSeconds` opened.
    private var openedAt: [Double] = []
    /// When a device-opened window last closed unused, by the asking key and by its address.
    private var quietKeys: [Data: Double] = [:]
    private var quietSources: [String: Double] = [:]

    init(seconds: Double? = nil) {
        quietSeconds = seconds ?? Self.quietFor
        spanSeconds = seconds ?? Self.span
    }

    /// Whether this key or this address may not open a window now.
    func quiet(fingerprint: Data, source: String, now: Double) -> Bool {
        quietSince(fingerprint: fingerprint, source: source, now: now) != nil
    }

    /// When the window that keeps this key or this address quiet closed (the later of the two),
    /// for the log's "its last window was closed 3 minutes ago"; nil when neither is quiet.
    func quietSince(fingerprint: Data, source: String, now: Double) -> Double? {
        [quietKeys[fingerprint], quietSources[source]].compactMap { $0 }.filter { now - $0 < quietSeconds }.max()
    }

    /// Device-opened windows in the last `spanSeconds`.
    func recentWindows(now: Double) -> Int {
        openedAt.filter { now - $0 < spanSeconds }.count
    }

    /// A device's ask opened a window.
    mutating func opened(now: Double) {
        openedAt = openedAt.filter { now - $0 < spanSeconds } + [now]
    }

    /// A device-opened window closed unused (`quiets`): its asker's key and address go quiet.
    mutating func closedUnused(fingerprint: Data, source: String, now: Double) {
        quietKeys = quietKeys.filter { now - $0.value < quietSeconds }
        quietSources = quietSources.filter { now - $0.value < quietSeconds }
        quietKeys[fingerprint] = now
        quietSources[source] = now
    }

    /// Whether a device-opened window that closed this way quiets its asker: cancelled on the Mac
    /// ("Didn't ask for this? Click Cancel."), or stopped after five wrong codes. Not one a device
    /// paired with, nor one that ran out or that its device withdrew: that device's next tap gets a
    /// fresh code, as its words after "expired" promise (DiscoveryPolicy.homeRefusal).
    static func quiets(_ reason: PairingWindow.CloseReason) -> Bool {
        switch reason {
        case .cancelled, .stopped: return true
        case .used, .expired, .withdrawn, .none: return false
        }
    }

    /// TEST ONLY: SILL_TEST_ASK_QUIET=<s> replaces both 600 s, on a test host only
    /// (DoorPolicy.isTestHost); a positive finite number of seconds, anything else nil.
    static func testSeconds(testHost: Bool, environment: [String: String]) -> Double? {
        guard testHost, let v = environment["SILL_TEST_ASK_QUIET"], let s = Double(v), s.isFinite, s > 0 else { return nil }
        return s
    }
}
