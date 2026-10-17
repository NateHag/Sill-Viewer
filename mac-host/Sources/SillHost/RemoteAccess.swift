import Foundation
import Network
import Security
import StreamProtocol

/// Pairing and remote access on one host (docs/remote-access-plan.md §4.10; pairing at home,
/// docs/home-pairing-plan.md §4.6): the Mac's identity and trust list, Require pairing, the pairing
/// window, the asks at the home door (the cable, the limits), the addresses (Reachability,
/// RouterAddress, AddressList), the remote door (RemoteServer) and kind 18. The coordinator owns
/// one: Sill.app always, SillHost only with --remote or --pairing. Main actor; both doors run on
/// the network queue and read only `trust`, a lock-protected snapshot replaced whole on every
/// change, so nothing there waits on this actor. (The name stays: it owns pairing for both doors.)
///
/// Only the Mac widens exposure: Remote Access, the port, internet access and Require pairing
/// come from HostConfig (the app's settings, the identity store, the CLI's flags), never from a
/// device. A pairing never turns Remote Access on by itself, and a window a device opened by
/// asking never runs the remote door.
///
/// Secrets: the pairing code and the QR secret leave this type only through `onPairingOffer` (the
/// app shows its window, the CLI prints). They are never in the status, a log line, kind 16 or 18,
/// or a TXT record.
///
/// TEST ONLY, on a test host (DoorPolicy.isTestHost): SILL_TEST_PAIRING_TTL=<s> shortens the
/// window, SILL_TEST_NO_ROUTER=1 skips the router query, SILL_TEST_ASK_FROM_THIS_MAC=1 judges an
/// ask from this Mac as one from another device, SILL_TEST_ASK_QUIET=<s> replaces the ask limits'
/// 600 s, and the address list starts with 127.0.0.1.
@MainActor
package final class RemoteAccess {
    /// What the Mac shows to pair a device: the QR link, the typed code, until when, and why.
    package struct PairingOffer: Sendable {
        /// sill://pair?v=1&… (PairLink).
        package let url: String
        /// 12 digits; `groupedCode` shows them as "4829 1355 7208".
        package let code: String
        package var groupedCode: String { PairingCode.grouped(code) }
        package let expiresAt: Date
        /// A device's name when a device asked (kind 21, or an ask at the home door); nil when
        /// opened on the Mac.
        package let requestedBy: String?
        /// The remote door's port, as devices dial it.
        package let port: Int
        /// This window's offer shown again (a second request while it is open).
        package let again: Bool
        /// A device opened this window by asking at a TLS home door, and it is still the home
        /// door's alone: the app shows it in front without taking the keyboard, and its link
        /// carries no address. False again once the Mac's user opens a window over it.
        package let byDevice: Bool
        /// Where that device asked from, as the window says it: "on this network", "nearby" (over
        /// peer-to-peer Wi-Fi) or "on this Mac" (test hosts only); nil when opened on the Mac.
        package let askedFrom: String?
        /// This offer answers an ask from this device while the window was already open (the CLI
        /// prints "Pairing: ‹device› asked; code …"); nil otherwise.
        package let askedBy: String?

        /// Also for the app's previews, which draw the pairing window without a host.
        package init(url: String, code: String, expiresAt: Date, requestedBy: String?, port: Int, again: Bool,
                     byDevice: Bool = false, askedFrom: String? = nil, askedBy: String? = nil) {
            self.url = url; self.code = code; self.expiresAt = expiresAt; self.requestedBy = requestedBy
            self.port = port; self.again = again
            self.byDevice = byDevice; self.askedFrom = askedFrom; self.askedBy = askedBy
        }
    }

    package let identity: HostIdentity?
    /// Why there is no identity (the keychain failed); remote access, and a TLS home door, are
    /// then unavailable.
    package let identityProblem: String?
    /// Where the key lives, as the home door's unavailable line names it: "in the keychain" (the
    /// app), "in memory", "in the test directory …".
    package let keyPlace: String
    private let store: IdentityStore?
    private(set) var paired: [PairedDevice] = []

    private var window = PairingWindow()
    let trust = TrustBox()
    private var remoteAccess = false
    private var remotePort = HostConfig.defaultRemotePort
    private var internetAccess = false
    private var requirePairing = true
    private var addressName: ParsedAddress?
    private var addressNameText = ""

    private weak var server: StreamServer?
    private weak var status: HostStatus?
    private var door: RemoteServer?
    private var macName = "Mac"
    private var testHost = false
    /// The home door speaks TLS (Sill.app, SillHost --pairing): its asks and proofs come here, its
    /// TXT record carries `p`, and a window a device opens there is its alone.
    private var homeTLS = false
    /// The home door has no listener at all (fail closed), and why.
    private var homeUnavailable: String?
    private var announcedHomeDoor = false
    private var reachability: Reachability?
    private var reach: Reachability.Snapshot?
    private var router: RouterAddress?
    private var routerInterface: String?
    private var routerState = RemoteStatus.Router.off
    private var listenerState = RemoteStatus.Listener.off
    private var pairingState = RemoteStatus.Pairing.closed
    private var lastBroadcast: MacInfo?
    /// When each paired device last connected, and how ("through Tailscale", "over the USB
    /// cable"), by its key prefix (`RemoteIdentity.shortName`): display only, for the pane's "last
    /// connected". The app keeps it in its defaults (`restoreSeen`, `onSeen`); trust never rests on it.
    private var lastSeen: [String: (at: Date, route: String)] = [:]
    /// An offer waiting for the door's port and the first address list (at most `offerWait`).
    private var offerPending: (requestedBy: String?, again: Bool, askedBy: String?)?
    private var offerDeadline: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    static let offerWait: TimeInterval = 3

    /// The asks' limits (AskLimits): a monotonic clock, so a clock change moves nothing.
    private var askLimits = AskLimits()
    /// The device whose ask opened the window that is up; nil when the Mac's user opened it.
    private var windowAsk: PairingWindow.DeviceAsk?
    /// When each source address last logged an ask line (one a minute at most).
    private var askLineAt: [String: Double] = [:]
    static let askLineSpacing: Double = 60
    private var pairingRequest: RemoteStatus.PairingRequest?
    /// The key that asked for `pairingRequest`: its pairing, by any path, ends the request.
    private var requestKey: Data?
    private var requestExpiry: Task<Void, Never>?
    private var olderDeviceAt: Date?

    /// The app shows its pairing window; the CLI prints the link and the code.
    package var onPairingOffer: ((PairingOffer) -> Void)?
    /// The CLI: a fresh window after each use or expiry, for the whole run (not after five wrong
    /// codes, and not after Cancel). An expiry is then noticed at the next attempt, which is
    /// answered "expired" before the fresh window opens.
    package var reopensPairing = false
    /// The core's "Pairing window open …" line (the CLI prints its own from `onPairingOffer`).
    package var logsPairingWindows = true
    /// Whether a window the Mac's user opens runs the remote door and lets it take proofs, on a
    /// TLS home door: Sill.app (true), the CLI only with --remote. On a plain home door every
    /// window does, as the plain door takes no proof.
    package var userWindowsOpenRemoteDoor = true
    /// A paired device's session started (its key prefix, when, its route label): the app saves it
    /// for the next launch's "last connected".
    package var onSeen: ((_ keyPrefix: String, _ at: Date, _ route: String) -> Void)?
    /// A device paired by itself over the USB cable (its paired name and fingerprint): the app's
    /// notice. The core prints the line.
    package var onCablePaired: ((_ name: String, _ fingerprint: String) -> Void)?

    /// TEST ONLY: the file store's directory, where a test hook may leave the current pairing link
    /// and code; nil for every other store.
    package var testDirectory: URL? { store?.testDirectory }

    /// The paired devices' key prefixes (what the app's "last connected" records are keyed by).
    package var pairedPrefixes: [String] { paired.compactMap { $0.fingerprintData.map(RemoteIdentity.shortName) } }

    /// Loads (or creates) the identity and the trust list from `store`. A failure leaves the host
    /// without an identity: no TXT tag, no kind 18, no remote door, no TLS home door;
    /// `identityProblem` says why. That includes a trust list that cannot be read: kept with an
    /// empty list, the store would save the next pairing over it and every earlier pairing would be
    /// gone.
    package init(store: IdentityStore) {
        var identity: HostIdentity?
        var problem: String?
        var paired: [PairedDevice] = []
        do {
            let key = try store.loadOrCreateKey()
            let recognition = try store.loadOrCreateRecognitionKey()
            guard let id = HostIdentity(privateKey: key, recognitionKey: recognition) else {
                throw IdentityStoreError("the key could not make a TLS identity")
            }
            paired = try store.loadPaired()
            identity = id
        } catch {
            problem = "\(error)"
        }
        self.identity = identity
        identityProblem = problem
        keyPlace = store is KeychainIdentityStore ? "in the keychain" : store.summary
        self.store = identity == nil ? nil : store
        self.paired = paired
    }

    /// Called by the coordinator's init, before the server starts: the TXT record (the tag, and
    /// `p` on a TLS home door, from `requirePairing`) goes into the first registration.
    func attach(server: StreamServer, status: HostStatus, macName: String, requirePairing: Bool) {
        self.server = server
        self.status = status
        self.macName = SafeText.label(macName).isEmpty ? "Mac" : SafeText.label(macName)
        testHost = server.isTestHost
        homeTLS = server.homeTLS
        if case .closed(let why) = server.homeMode { homeUnavailable = why }
        self.requirePairing = requirePairing
        askLimits = AskLimits(seconds: AskLimits.testSeconds(testHost: testHost, environment: ProcessInfo.processInfo.environment))
        guard let identity else { publish(); return }
        let tls = homeTLS, box = trust
        server.txtRecord = {
            identity.txtRecord(homeDoor: tls ? HomeDoorTXT.value(requirePairing: box.snapshot.requirePairing) : nil)
        }
        let door = RemoteServer(server: server, identity: identity, trust: trust)
        door.onListener = { [weak self] state in Task { @MainActor in self?.listenerChanged(state) } }
        let judgeHere: (Door.PairAttempt, @escaping @Sendable (PairResult) -> Void) -> Void = { [weak self] attempt, reply in
            Task { @MainActor in
                guard let self else { reply(PairResult(ok: false, reason: PairResult.closed)); return }
                reply(self.judge(attempt))
            }
        }
        door.onPairAttempt = judgeHere
        self.door = door
        if let home = server.homeDoor {
            home.onPairAttempt = judgeHere
            home.onOlderSill = { [weak self] in Task { @MainActor in self?.olderDeviceSeen() } }
        }
        publishTrust()
        publish()
    }

    // MARK: Settings (the Mac's own)

    /// The knobs from HostConfig: Remote Access, its port, internet access and Require pairing.
    /// Starts or stops the door, the watcher and the router query, and publishes. Turning Remote
    /// Access off closes an open window the remote door runs for and says goodbye to every remote
    /// session; turning the internet switch off, to those from the internet; turning Require
    /// pairing on, to every home session without a paired key. The first call (at start) prints
    /// the TLS home door's line.
    ///
    /// The internet switch counts only while Remote Access is on: the pane hides it and the menu
    /// says "Off" then, yet a pairing window (the Mac's own, or one a device at home asks for)
    /// runs the door, which admitted internet sources, asked the router and put internet
    /// addresses into the link. The saved setting stays as it is, for when Remote Access is back.
    package func apply(_ config: HostConfig) {
        guard identity != nil else { announceHomeDoor(); publish(); return }
        let wasOn = remoteAccess, wasInternet = internetAccess, wasRequired = requirePairing
        remoteAccess = config.remoteAccess
        remotePort = config.remotePort
        internetAccess = config.remoteAccess && config.internetAccess
        requirePairing = config.requirePairing
        if wasOn, !remoteAccess {
            if let w = window.current, w.forRemote { window.close(.cancelled); windowClosed(.cancelled, reopen: false) }
            print("Remote access off.")
        }
        publishTrust()
        if wasOn, !remoteAccess {
            // Every remote session, those from the internet included: one goodbye each.
            door?.closeSessions(Goodbye.remoteOff, matching: { _ in true },
                                line: { name, endpoint in "Remote access off: disconnecting \(name) at \(endpoint)." })
        } else if wasInternet, !internetAccess {
            door?.closeSessions(Goodbye.internetOff, matching: { $0.origin == .internet },
                                line: { name, endpoint in "Internet access off: disconnecting \(name) at \(endpoint)." })
        }
        if homeTLS, requirePairing != wasRequired {
            server?.updateService()      // `p` in the TXT record, in place
            if requirePairing {
                // The snapshot already refuses unpaired keys at the next handshake; these are the
                // ones admitted while it was off.
                let pairedKeys = Set(paired.compactMap(\.fingerprintData))
                server?.closeSessions(Goodbye.pairingRequired,
                                      matching: { !$0.isRemote && $0.encrypted && !($0.fingerprint.map { pairedKeys.contains($0) } ?? false) },
                                      line: { name, endpoint in "Require pairing: disconnecting \(name) at \(endpoint), which isn’t paired." })
            }
        }
        announceHomeDoor()
        updateDoor()
        updateWatchers()
        publish()
        broadcastIfChanged()
    }

    /// The TLS home door's startup line, once.
    private func announceHomeDoor() {
        guard !announcedHomeDoor else { return }
        announcedHomeDoor = true
        guard homeTLS, homeUnavailable == nil else { return }
        if requirePairing {
            print("Home door: TLS, pairing required (\(paired.count) paired).")
        } else {
            print("Home door: TLS, pairing not required.")
        }
    }

    /// Require pairing as the identity store keeps it (docs/home-pairing-plan.md §6.5): off only
    /// when the record carries this Mac's own signature (RequirePairingValue); on when it was never
    /// saved, on, with a line, when it cannot be read, and on, with a line, when it is not this
    /// Mac's own (another app may have made the item: the security review, 2026-09-27).
    package func storedRequirePairing() -> Bool {
        guard let store, let identity else { return true }
        let record: Data?
        do { record = try store.loadRequirePairing() } catch {
            print("Require pairing: couldn’t read it \(keyPlace) (\(error)); pairing stays required.")
            return true
        }
        guard let record else { return true }
        let on = RequirePairingValue.decode(record, macID: identity.macID, verify: { identity.verifyRecord($0, signature: $1) })
        if on, record != RequirePairingValue.on {
            print("Require pairing: the setting \(keyPlace) isn’t signed by this Mac’s key; pairing stays required.")
        }
        return on
    }

    /// Saves Require pairing with the trust list, off signed by this Mac's key. Nil when saved;
    /// otherwise why not, and the caller keeps it as it was.
    package func saveRequirePairing(_ on: Bool) -> String? {
        guard let store, let identity else { return identityProblem ?? "no identity" }
        guard let record = RequirePairingValue.encode(on, macID: identity.macID, sign: { identity.signRecord($0) }) else {
            print("Require pairing: couldn’t sign it with this Mac’s key \(keyPlace).")
            return "this Mac’s key couldn’t sign it"
        }
        do { try store.saveRequirePairing(record); return nil } catch {
            print("Require pairing: couldn’t save it \(keyPlace) (\(error)).")
            return "\(error)"
        }
    }

    /// The address name setting ("home.example.net" or "home.example.net:17455"), checked by the
    /// address parser; anything it refuses counts as none.
    package func setAddressName(_ text: String) {
        addressNameText = text
        if case .success(let a) = AddressParser.parse(text) { addressName = a } else { addressName = nil }
        publish()
        broadcastIfChanged()
    }

    // MARK: Pairing

    /// Opens a pairing window (5 minutes, one device) and offers it: Pair iPhone or iPad… on the
    /// Mac, the CLI's own window, or kind 21 on a plain home door (`requestedBy`). Opening again
    /// while one is open keeps the same code and offers it again (the app brings its window
    /// forward, the CLI prints the code again); when a device opened that one by asking, it
    /// becomes the remote door's too. The remote door runs while a window it takes proofs for is
    /// open, even with Remote Access off.
    package func openPairing(requestedBy: String?) {
        openPairing(requestedBy: requestedBy, byDevice: nil)
        followRequest(named: requestedBy)
    }

    /// The Mac's user opened a window from the menu's "‹device› Wants to Pair" (AppModel's
    /// `showPairingRequest`, `requestedBy` that device): the request now follows that window
    /// ("showing": the item brings it forward, and it ends when the window closes), instead of
    /// lasting its 5 minutes beside a code that may be long gone.
    private func followRequest(named name: String?) {
        guard let name, window.isOpen, let r = pairingRequest, r.name == name, r.reason != "showing" else { return }
        requestExpiry?.cancel()
        pairingRequest = RemoteStatus.PairingRequest(name: r.name, at: r.at, reason: "showing")
        publish()
    }

    /// A device paired (a proof, or the cable): the menu's request that key made is answered.
    private func requestAnswered(by key: Data) {
        guard pairingRequest != nil, requestKey == key else { return }
        requestExpiry?.cancel()
        pairingRequest = nil
        requestKey = nil
        publish()
    }

    /// `byDevice`: a device's ask at a TLS home door (or its kind 21) opens this window; it is the
    /// home door's alone (no remote door, no addresses in its link), and when it closes unused its
    /// asker goes quiet (AskLimits).
    private func openPairing(requestedBy: String?, byDevice: PairingWindow.DeviceAsk?) {
        guard let identity else { return }
        if let w = window.current {
            // The Mac's user opened a window while one a device opened is up: the same code
            // becomes the remote door's too, and its offer goes out again once the addresses are
            // known, so a device away can pair with it.
            if byDevice == nil, homeTLS, userWindowsOpenRemoteDoor, window.makeRemote() {
                // Now the Mac's user's window as much as the device's (its offer says so too).
                if case .open(let r, let e, let t, let l, _) = pairingState {
                    pairingState = .open(requestedBy: r, expiresAt: e, triesLeft: t, lastWrongFrom: l, byDevice: false)
                }
                publishTrust()
                updateDoor()
                updateWatchers()
                publish()
                broadcastIfChanged()
            }
            makeOffer(requestedBy: w.requestedBy, again: true)
            return
        }
        var secret = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess, let code = PairingCode.generate() else {
            print("Pairing could not start: the random source failed.")
            return
        }
        var lifetime = PairingWindow.lifetime
        if testHost, let v = ProcessInfo.processInfo.environment["SILL_TEST_PAIRING_TTL"], let s = Double(v), s > 0 { lifetime = s }
        let now = Date().timeIntervalSince1970
        // On a plain home door every window is the remote door's (the plain door takes no proof);
        // on a TLS one only the Mac user's, when this host lets them be.
        let forRemote = !homeTLS || (byDevice == nil && userWindowsOpenRemoteDoor)
        window.open(secret: Data(secret), code: code, now: now, lifetime: lifetime, requestedBy: requestedBy,
                    byDevice: byDevice, forRemote: forRemote)
        windowAsk = byDevice
        if byDevice != nil { askLimits.opened(now: monotonic()) }
        pairingState = .open(requestedBy: requestedBy, expiresAt: Date(timeIntervalSince1970: now + lifetime),
                             triesLeft: PairingWindow.maxFailures, lastWrongFrom: nil, byDevice: byDevice != nil)
        if logsPairingWindows {
            let span = lifetime >= 60 ? "\(Int(lifetime / 60)) minute\(Int(lifetime / 60) == 1 ? "" : "s")" : "\(Int(lifetime)) s"
            let who = requestedBy.map { "asked by \($0)" + (byDevice.map { " \($0.from)" } ?? "") } ?? "opened on this Mac"
            print("Pairing window open for \(span) (\(who)).")
        }
        // K for the typed path, off the main actor (~0.1 s); a code proof before it is answered busy.
        let fp = identity.fingerprint
        Task { @MainActor [weak self] in
            let key = await Task.detached(priority: .userInitiated) { PairingProof.codeKey(code: code, macFingerprint: fp) }.value
            if let key { self?.window.setCodeKey(key, code: code) }
        }
        if !reopensPairing {
            let until = now + lifetime
            expiryTask?.cancel()
            expiryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until - Date().timeIntervalSince1970)))
                guard let self, !Task.isCancelled else { return }
                if self.window.expireIfDue(now: Date().timeIntervalSince1970) { self.windowClosed(.expired, reopen: false) }
            }
        }
        publishTrust()
        updateDoor()
        updateWatchers()
        publish()
        broadcastIfChanged()
        makeOffer(requestedBy: requestedBy, again: false)
    }

    /// Kind 21 from a device near the Mac (the coordinator checked the route). On a plain home
    /// door, as always: a window for it, or, on the CLI, the open window's code printed again; the
    /// app ignores it while one is open. On a TLS home door it comes only from an unpaired session
    /// (Require pairing off) and goes through the ask rule's steps 1 and 3–6 and the ask limits,
    /// never step 2: a session is no pairing connection.
    func pairingWanted(by device: String, session: (fingerprint: Data, source: String, display: String, from: String, fromThisMac: Bool)?) {
        guard identity != nil else { return }
        guard homeTLS, let s = session else {
            if window.isOpen {
                if reopensPairing { makeOffer(requestedBy: window.current?.requestedBy, again: true) }
                return
            }
            openPairing(requestedBy: device)
            return
        }
        let asker = PairingWindow.DeviceAsk(fingerprint: s.fingerprint, source: s.source, from: s.from)
        _ = decideAsk(name: device, display: s.display, asker: asker, fromThisMac: s.fromThisMac, cable: nil, cableClaimed: false)
    }

    /// The Mac's user closed the pairing window: the code dies with it.
    package func cancelPairing() {
        guard window.isOpen else { return }
        window.close(.cancelled)
        windowClosed(.cancelled, reopen: false)
    }

    /// Removes a paired device: from the store, then the snapshot (its next handshake fails in the
    /// verify block, at either door), then every session of it, home and remote, gets goodbye
    /// `removed`. Nil when done; otherwise why not, and nothing changed: a removal the store did
    /// not keep (a locked login keychain, its prompt cancelled) would trust the device again at the
    /// next launch while the pane said it could no longer connect, so the device stays listed and
    /// connected until a save succeeds. Removing it also frees its iPhone or iPad for a pairing by
    /// itself over the cable.
    @discardableResult
    package func remove(fingerprint: String) -> String? {
        guard let i = paired.firstIndex(where: { $0.fingerprint == fingerprint }) else { return nil }
        var rest = paired
        let device = rest.remove(at: i)
        do { try store?.savePaired(rest) } catch {
            print("Remote access: \(device.displayName) is still paired: the paired devices could not be saved (\(error)).")
            return "\(error)"
        }
        paired = rest
        if let fp = device.fingerprintData { lastSeen[RemoteIdentity.shortName(fp)] = nil }
        publishTrust()
        publish()
        let fp = device.fingerprintData
        server?.closeSessions(Goodbye.removed, matching: { fp != nil && $0.fingerprint == fp }, done: { n in
            print("Removed \(device.displayName); closed \(n) connection\(n == 1 ? "" : "s").")
        })
        return nil
    }

    /// Renames a paired device (the Mac's own label for it).
    package func rename(fingerprint: String, to name: String) {
        guard let i = paired.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        let clean = SafeText.label(name)
        guard !clean.isEmpty else { return }
        paired[i].name = clean
        paired[i].model = nil
        save()
        publishTrust()
        publish()
    }

    /// A session of this paired device started, at either door: for the pane's "last connected"
    /// (`route`: "through Tailscale", "over the USB cable", "over Wi‑Fi"…). Over the cable
    /// (`cableDevice`, CableLink.deviceID) a key that has no device yet learns it, once: its
    /// iPhone or iPad then pairs no other key by itself over the cable.
    func sessionStarted(fingerprint: Data, route: String, cableDevice: String? = nil) {
        let prefix = RemoteIdentity.shortName(fingerprint), now = Date()
        lastSeen[prefix] = (now, route)
        if let cableDevice, let i = paired.firstIndex(where: { $0.fingerprintData == fingerprint }), paired[i].cableDevice == nil {
            var next = paired
            next[i].cableDevice = cableDevice
            do {
                try store?.savePaired(next)
                paired = next
            } catch {
                print("Pairing: couldn’t note which iPhone or iPad \(next[i].displayName) runs on (\(error)).")
            }
        }
        publish()
        onSeen?(prefix, now, route)
    }

    /// The app's saved "last connected" records, at launch. A newer one of this run wins.
    package func restoreSeen(_ seen: [String: (at: Date, route: String)]) {
        lastSeen.merge(seen) { mine, _ in mine }
        publish()
    }

    /// Whether this key is on the trust list now.
    func isPaired(_ fingerprint: Data) -> Bool {
        paired.contains { $0.fingerprintData == fingerprint }
    }

    /// The home door refused plain Sill messages from one source, again and again (an older Sill;
    /// DoorPolicy.olderSillTry): the menu's item, for 10 minutes.
    private func olderDeviceSeen() {
        olderDeviceAt = Date()
        publish()
    }

    /// Judges one kind 19 (a door hands it over; the reply goes back to it). An ask never reaches
    /// the window, whose unknown methods count as wrong codes: at home the ask rule decides, and
    /// the remote door never gets this far with one (it answers `closed` itself). A proof at the
    /// remote door counts only for a window that door runs for.
    private func judge(_ attempt: Door.PairAttempt) -> PairResult {
        guard let identity else { return PairResult(ok: false, reason: PairResult.closed) }
        if attempt.request.method == PairRequest.ask {
            guard attempt.door == .home else { return PairResult(ok: false, reason: PairResult.closed) }
            return ask(attempt, identity)
        }
        if attempt.request.method == PairRequest.cancel {
            if attempt.door == .home { withdraw(asker: attempt.deviceFingerprint, name: Self.displayName(attempt.request), display: attempt.display) }
            return PairResult(ok: false, reason: PairResult.closed)
        }
        if attempt.door == .remote, let w = window.current, !w.forRemote {
            return PairResult(ok: false, reason: PairResult.closed)
        }
        let wasOpen = window.isOpen
        let proof = Base64URL.decode(attempt.request.proof) ?? Data()
        let now = Date().timeIntervalSince1970
        let verdict = window.tryProof(method: attempt.request.method, proof: proof, fpDevice: attempt.deviceFingerprint,
                                      fpMac: identity.fingerprint, source: attempt.source, now: now)
        switch verdict {
        case .accept(let proofM):
            let name = SafeText.label(attempt.request.name)
            let model = attempt.request.model.map { SafeText.label($0) }.flatMap { $0.isEmpty ? nil : $0 }
            var device = PairedDevice(fingerprint: Base64URL.encode(attempt.deviceFingerprint), name: name, model: model,
                                      pairedAt: now, method: attempt.request.method)
            // Re-pairing the same key replaces its record, keeping the iPhone or iPad it runs on.
            device.cableDevice = paired.first { $0.fingerprint == device.fingerprint }?.cableDevice
            // The snapshot is updated before kind 20 ok goes out, so the session dial that follows
            // is admitted.
            paired.removeAll { $0.fingerprint == device.fingerprint }
            paired.append(device)
            save()
            publishTrust()
            print("Paired \(device.displayName) (key \(RemoteIdentity.shortName(attempt.deviceFingerprint))…) from \(attempt.display), "
                  + "with \(attempt.request.method == PairRequest.qr ? "the QR code" : "the code").")
            pairingState = .paired(device.displayName)
            requestAnswered(by: attempt.deviceFingerprint)
            windowClosed(.used, reopen: true)
            return PairResult(ok: true, proof: Base64URL.encode(proofM), macID: identity.macID, name: macName,
                              recognitionKey: Base64URL.encode(identity.recognitionKey))
        case .reject(let left):
            print("Pairing: a wrong code from \(attempt.display) (\(left) tr\(left == 1 ? "y" : "ies") left).")
            if case .open(let requestedBy, let expiresAt, _, _, let byDevice) = pairingState {
                pairingState = .open(requestedBy: requestedBy, expiresAt: expiresAt, triesLeft: left, lastWrongFrom: attempt.display,
                                     byDevice: byDevice)
            }
            publish()
            return PairResult(ok: false, reason: PairResult.code, triesLeft: left)
        case .busy(let after):
            return PairResult(ok: false, reason: PairResult.busy, retryAfter: (after * 10).rounded(.up) / 10)
        case .closed(let reason):
            if wasOpen && reason == .stopped {
                print("Pairing stopped after \(PairingWindow.maxFailures) wrong codes.")
                windowClosed(.stopped, reopen: true)
            } else if wasOpen && reason == .expired {
                windowClosed(.expired, reopen: true)
            }
            return PairResult(ok: false, reason: PairingWindow.closedReason(reason, stoppedByThisProof: wasOpen))
        }
    }

    /// Kind 19 "cancel" at the home door: the device no longer needs the code its ask put up. The
    /// window closes, withdrawn (its asker is not kept quiet), only when this very key's ask opened
    /// it and it is still the home door's alone: a window the Mac's user opened, or opened over it,
    /// stays theirs. Whatever happened, the answer is `closed` (the caller's).
    private func withdraw(asker: Data, name: String, display: String) {
        guard let w = window.current, !w.forRemote, windowAsk?.fingerprint == asker else { return }
        window.close(.withdrawn)
        print("Pairing: \(name) at \(display) no longer needs its code; the window closed.")
        windowClosed(.withdrawn, reopen: true)
    }

    // MARK: The ask (docs/home-pairing-plan.md §4.2, §4.6)

    /// An ask at the home door: "pair me, now if you can, else show me your code".
    private func ask(_ a: Door.PairAttempt, _ identity: HostIdentity) -> PairResult {
        let name = Self.displayName(a.request)
        let from = a.origin == .direct ? "nearby" : (a.fromThisMac || a.origin == .loopback ? "on this Mac" : "on this network")
        let asker = PairingWindow.DeviceAsk(fingerprint: a.deviceFingerprint, source: a.source, from: from)
        let verdict = decideAsk(name: name, display: a.display, asker: asker, fromThisMac: a.fromThisMac,
                                cable: a.cable, cableClaimed: a.request.cable == true)
        guard verdict == .pairNow, let cable = a.cable else {
            return PairResult(ok: false, reason: DoorPolicy.reason(verdict))
        }
        return pairOverCable(a, cable, identity)
    }

    /// The ask rule for one ask (or a kind 21 from an unpaired session: no cable), its line, and
    /// what it does: a window opened for it, the open one's code printed again on the CLI, the
    /// menu's request. Returns the rule's verdict; `pairNow` is the caller's to carry out.
    private func decideAsk(name: String, display: String, asker: PairingWindow.DeviceAsk, fromThisMac: Bool,
                           cable: CableLink.Ancestry?, cableClaimed: Bool) -> DoorPolicy.Ask {
        let now = monotonic()
        let deviceID = cable?.serial.map(CableLink.deviceID)
        let fingerprint = Base64URL.encode(asker.fingerprint)
        let otherKey = deviceID.map { id in
            DoorPolicy.otherKeyOfDevice(id, fingerprint: fingerprint, paired: paired.map { ($0.fingerprint, $0.cableDevice) })
        } ?? false
        // An ask from this Mac itself never opens a window or lights the menu (step 4), except on a
        // test host that says to judge it as another device's.
        let asDevice = DoorPolicy.testAsksAsDevice(testHost: testHost, environment: ProcessInfo.processInfo.environment)
        let thisMac = fromThisMac && !asDevice
        let quietSince = askLimits.quietSince(fingerprint: asker.fingerprint, source: asker.source, now: now)
        let verdict = DoorPolicy.ask(unlocked: SessionLock.shared.unlocked(testHost: testHost), cableSeen: cable != nil,
                                     cableClaimed: cableClaimed, otherKeyOfDevice: otherKey, windowOpen: window.isOpen,
                                     fromThisMac: thisMac, quiet: quietSince != nil,
                                     recentDeviceWindows: askLimits.recentWindows(now: now))
        logAsk(verdict, name: name, display: display, source: asker.source, now: now, cable: cable,
               otherKey: otherKey, cableClaimed: cableClaimed, quietSince: quietSince)
        switch verdict {
        case .pairNow:
            break
        case .shown(opened: true):
            openPairing(requestedBy: name, byDevice: asker)
        case .shown(opened: false):
            if reopensPairing { makeOffer(requestedBy: window.current?.requestedBy, again: true, askedBy: name) }
        case .openOnMac, .locked:
            break
        }
        if let reason = DoorPolicy.menuRequest(verdict, fromThisMac: thisMac) { request(name: name, reason: reason, key: asker.fingerprint) }
        return verdict
    }

    /// Paired by itself over the USB cable: saved first (a save that fails answers `openOnMac` and
    /// says why), then the snapshot, the line, the app's notice, and kind 20 ok with `method`
    /// "cable". A key already on the list gets the same ok with no line and no notice, and nothing
    /// saved but its device if it had none: a device that lost its saved Macs asks once more, and
    /// an app asking in a loop shows nothing.
    private func pairOverCable(_ a: Door.PairAttempt, _ cable: CableLink.Ancestry, _ identity: HostIdentity) -> PairResult {
        let ok = PairResult(ok: true, macID: identity.macID, name: macName, recognitionKey: Base64URL.encode(identity.recognitionKey),
                            method: PairResult.cable)
        let fingerprint = Base64URL.encode(a.deviceFingerprint)
        let deviceID = cable.serial.map(CableLink.deviceID)
        // Paired (again): a window this very key's ask opened earlier (over Wi-Fi, say) has no one
        // to show its code to now, so it goes, withdrawn, neither staying up for its 5 minutes nor
        // quieting anyone; and the menu's request that key made (the Mac was locked, say) is
        // answered. Not after a save that failed: nothing was paired then.
        let pairedNow = { [self] in
            closeWindowOpened(by: a.deviceFingerprint)
            requestAnswered(by: a.deviceFingerprint)
        }
        if let i = paired.firstIndex(where: { $0.fingerprint == fingerprint }) {
            if paired[i].cableDevice == nil, let deviceID {
                var next = paired
                next[i].cableDevice = deviceID
                if (try? store?.savePaired(next)) != nil { paired = next }
            }
            pairedNow()
            return ok
        }
        let model = a.request.model.map { SafeText.label($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let device = PairedDevice(fingerprint: fingerprint, name: SafeText.label(a.request.name), model: model,
                                  pairedAt: Date().timeIntervalSince1970, method: PairResult.cable, cableDevice: deviceID)
        var next = paired
        next.append(device)
        do { try store?.savePaired(next) } catch {
            print("Cable pairing: \(device.displayName) at \(a.display) not paired: the paired devices could not be saved (\(error)).")
            return PairResult(ok: false, reason: PairResult.openOnMac)
        }
        paired = next
        publishTrust()
        publish()
        print("Paired \(device.displayName) (key \(RemoteIdentity.shortName(a.deviceFingerprint))…) over the USB cable (\(a.display)).")
        pairedNow()
        onCablePaired?(device.displayName, fingerprint)
        return ok
    }

    /// A device paired over the cable: the window its own ask opened, if it is still up and the home
    /// door's alone, closes withdrawn (no line: the pairing's own says it all).
    private func closeWindowOpened(by key: Data) {
        guard let w = window.current, !w.forRemote, windowAsk?.fingerprint == key else { return }
        window.close(.withdrawn)
        windowClosed(.withdrawn, reopen: true)
    }

    /// One line per ask (§4.11), at most one a minute per source address: a stranger asking in a
    /// loop would otherwise fill the log. Nothing for a pairing (its own line says so).
    private func logAsk(_ verdict: DoorPolicy.Ask, name: String, display: String, source: String, now: Double,
                        cable: CableLink.Ancestry?, otherKey: Bool, cableClaimed: Bool, quietSince: Double?) {
        if verdict == .pairNow { return }
        if let last = askLineAt[source], now - last < Self.askLineSpacing { return }
        askLineAt = askLineAt.filter { now - $0.value < Self.askLineSpacing }
        askLineAt[source] = now
        let outcome: String
        switch verdict {
        case .pairNow: return
        case .shown(opened: true): outcome = "showing the code"
        case .shown(opened: false): outcome = "the code is already showing"
        case .locked: outcome = "not shown (this Mac is locked)"
        case .openOnMac(let why):
            switch why {
            case "this Mac": outcome = "not shown (it asked from this Mac)"
            case "quiet": outcome = "not shown (its last window was closed \(Self.ago(now - (quietSince ?? now))))"
            default: outcome = "not shown (\(askLimits.recentWindows(now: now)) windows in \(Self.span(askLimits.spanSeconds)))"
            }
        }
        if verdict != .locked, let cable {
            let product = cable.productName ?? "device"
            let why = otherKey ? "another key of this \(product) is paired" : (cableClaimed ? "it couldn’t be paired by itself" : "it didn’t find the cable on its side")
            print("Cable pairing: \(name) at \(display) not paired by itself (\(why)); \(outcome).")
        } else {
            print("Pairing: \(name) at \(display) asked to pair; \(outcome).")
        }
    }

    /// "less than a minute ago", "1 minute ago", "3 minutes ago".
    private static func ago(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m < 1 ? "less than a minute ago" : "\(m) minute\(m == 1 ? "" : "s") ago"
    }

    /// "10 minutes", or "5 s" for a test host's short span.
    private static func span(_ seconds: Double) -> String {
        seconds >= 60 ? "\(Int(seconds / 60)) minute\(Int(seconds / 60) == 1 ? "" : "s")" : "\(Int(seconds)) s"
    }

    /// "iPad (iPad14,1)": the asking device's own name and model, cleaned, as a paired one is shown.
    private static func displayName(_ r: PairRequest) -> String {
        let model = r.model.map { SafeText.label($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return PairedDevice(fingerprint: "", name: SafeText.label(r.name), model: model, pairedAt: 0, method: "").displayName
    }

    /// The menu's "‹device› Wants to Pair" for 5 minutes (a "showing" one also ends with its window,
    /// and any ends once `key`, the device that asked, pairs).
    private func request(name: String, reason: String, key: Data) {
        let r = RemoteStatus.PairingRequest(name: name, at: Date(), reason: reason)
        pairingRequest = r
        requestKey = key
        publish()
        requestExpiry?.cancel()
        requestExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(RemoteStatus.PairingRequest.shownFor))
            guard let self, !Task.isCancelled, self.pairingRequest == r else { return }
            self.pairingRequest = nil
            self.requestKey = nil
            self.publish()
        }
    }

    /// Seconds on a clock that never jumps and runs through sleep: the ask limits' and the ask
    /// lines' clock.
    private func monotonic() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// After a window closed: the ask limits (a device-opened window cancelled on the Mac or stopped
    /// quiets its asker; one that ran out or was withdrawn does not), the snapshot, the door (it
    /// stops if Remote Access is off), the status. The CLI then opens a fresh one after a use, an
    /// expiry or a withdrawal.
    private func windowClosed(_ reason: PairingWindow.CloseReason, reopen: Bool) {
        expiryTask?.cancel()
        expiryTask = nil
        offerPending = nil
        if let asker = windowAsk, AskLimits.quiets(reason) {
            askLimits.closedUnused(fingerprint: asker.fingerprint, source: asker.source, now: monotonic())
        }
        windowAsk = nil
        if pairingRequest?.reason == "showing" {
            pairingRequest = nil
            requestKey = nil
            requestExpiry?.cancel()
        }
        switch reason {
        case .used: break                       // pairingState already names the device
        case .stopped: pairingState = .stopped
        case .expired: pairingState = .expired
        case .cancelled, .withdrawn, .none: pairingState = .closed
        }
        publishTrust()
        updateDoor()
        updateWatchers()
        publish()
        broadcastIfChanged()
        if reopen, reopensPairing, reason == .used || reason == .expired || reason == .withdrawn {
            openPairing(requestedBy: nil)
        }
    }

    /// The offer of a window the remote door runs for needs the door's port and an address list:
    /// made at once when both are known, else as soon as they are (at most `offerWait` later). A
    /// window the home door alone takes proofs for is offered at once, with no address.
    private func makeOffer(requestedBy: String?, again: Bool, askedBy: String? = nil) {
        offerPending = (requestedBy, again, askedBy)
        deliverOfferIfReady(force: false)
        if offerPending != nil {
            offerDeadline?.cancel()
            offerDeadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.offerWait))
                guard !Task.isCancelled else { return }
                self?.deliverOfferIfReady(force: true)
            }
        }
    }

    private func deliverOfferIfReady(force: Bool) {
        guard let pendingOffer = offerPending, let identity, let w = window.current else { offerPending = nil; return }
        let port: Int
        var links: [ParsedAddress] = []
        if w.forRemote {
            guard let p = doorPort, force || reach != nil else { return }
            port = p
            links = addresses().prefix(PairLink.maxAddresses).compactMap { a -> ParsedAddress? in
                guard case .success(var p) = AddressParser.parse(a.host) else { return nil }
                p.port = a.port
                return p
            }
        } else {
            // A home-only window: the device pairs at the door it asked on, so the link names no
            // address; its port is the remote door's as configured (the link needs one).
            port = doorPort ?? HostConfig.defaultRemotePort
        }
        offerPending = nil
        offerDeadline?.cancel()
        let link = PairLink(fingerprint: identity.fingerprint, secret: w.secret, name: macName, port: port, addresses: links)
        // A device-opened window the Mac's user has since opened over (`makeRemote`) is offered as
        // theirs: its link has addresses now, and the app shows it as it shows its own.
        onPairingOffer?(PairingOffer(url: link.url, code: w.code, expiresAt: Date(timeIntervalSince1970: w.expiresAt),
                                     requestedBy: pendingOffer.requestedBy, port: port, again: pendingOffer.again,
                                     byDevice: w.byDevice != nil && !w.forRemote, askedFrom: w.byDevice?.from,
                                     askedBy: pendingOffer.askedBy))
    }

    // MARK: The door, the watchers, the status

    /// The port devices dial: the configured one, or the bound one when any port was asked for.
    private var doorPort: Int? {
        if case .listening(let p) = listenerState { return p }
        return remotePort == 0 ? nil : remotePort
    }

    /// A window is open that the remote door runs for and takes proofs for.
    private var remoteWindowOpen: Bool { window.current?.forRemote ?? false }

    private func updateDoor() {
        door?.set(wanted: remoteAccess || remoteWindowOpen, port: remotePort)
    }

    /// Reachability runs with the door; the router is asked only with the internet switch on.
    private func updateWatchers() {
        let wanted = identity != nil && (remoteAccess || remoteWindowOpen)
        if wanted, reachability == nil {
            let r = Reachability { [weak self] snapshot in self?.reachabilityChanged(snapshot) }
            reachability = r
            r.start()
        } else if !wanted, let r = reachability {
            r.stop()
            reachability = nil
        }
        let skipRouter = testHost && ProcessInfo.processInfo.environment["SILL_TEST_NO_ROUTER"] == "1"
        let routerWanted = wanted && internetAccess && !skipRouter
        let interface = reach.map { AddressList.routerInterface(Reachability.input($0)) } ?? nil
        if routerWanted, router == nil || interface != routerInterface {
            router?.stop()
            routerInterface = interface
            router = RouterAddress(interface: interface) { [weak self] r in
                self?.routerState = r
                self?.publish()
                self?.broadcastIfChanged()
            }
            routerState = router == nil ? .noAnswer : .asking
        } else if !routerWanted, let r = router {
            r.stop()
            router = nil
            routerState = .off
        } else if !routerWanted {
            routerState = .off
        }
    }

    private func reachabilityChanged(_ snapshot: Reachability.Snapshot) {
        guard reachability != nil else { return }
        let first = reach == nil
        reach = snapshot
        publishTrust()
        door?.retryNow()
        updateWatchers()
        publish()
        broadcastIfChanged()
        if first { deliverOfferIfReady(force: false) }
    }

    private func listenerChanged(_ state: RemoteStatus.Listener) {
        listenerState = state
        publish()
        broadcastIfChanged()
        if case .listening = state { deliverOfferIfReady(force: false) }
    }

    /// In dial order; empty while Remote Access is off and no window the remote door runs for is
    /// open.
    private func addresses() -> [MacAddress] {
        guard remoteAccess || remoteWindowOpen else { return [] }
        var input = reach.map(Reachability.input) ?? AddressList.Input()
        input.internet = internetAccess
        input.addressName = addressName
        if case .address(let a) = routerState { input.routerIPv4 = a }
        input.testLoopback = testHost
        return AddressList.build(input)
    }

    private func publishTrust() {
        var map: [Data: String] = [:]
        for d in paired { if let fp = d.fingerprintData { map[fp] = d.displayName } }
        let open = window.isOpen, remoteOpen = remoteWindowOpen, on = remoteAccess, internet = internetAccess
        let required = requirePairing
        let names = reach?.serviceNames ?? [:]
        trust.update {
            $0.paired = map
            $0.pairingOpen = open
            $0.remotePairingOpen = remoteOpen
            $0.remoteAccess = on
            $0.internetAccess = internet
            $0.requirePairing = required
            $0.serviceNames = names
        }
    }

    private func publish() {
        guard let status else { return }
        let summaries = paired.sorted { $0.pairedAt < $1.pairedAt }.map { d -> PairedDeviceSummary in
            let prefix = d.fingerprintData.map(RemoteIdentity.shortName) ?? "?"
            let seen = lastSeen[prefix]
            return PairedDeviceSummary(id: d.fingerprint, keyPrefix: prefix,
                                       name: d.displayName, model: d.model, pairedAt: Date(timeIntervalSince1970: d.pairedAt),
                                       method: d.method, lastSeen: seen?.at, lastRoute: seen?.route)
        }
        let input = reach.map(Reachability.input)
        let homeDoor: RemoteStatus.HomeDoor
        if let why = homeUnavailable { homeDoor = .unavailable(why) } else if homeTLS { homeDoor = requirePairing ? .pairingRequired : .open } else { homeDoor = .plain }
        let remote = RemoteStatus(remoteAccess: remoteAccess, internetAccess: internetAccess, listener: listenerState,
                                  addresses: addresses(),
                                  vpnDown: reach.map { AddressList.vpnDown(setupVPNs: $0.setupVPNs, services: $0.services) } ?? [],
                                  lanAddress: input.flatMap(AddressList.lanAddress), router: routerState,
                                  addressName: addressNameText, pairing: pairingState, paired: summaries,
                                  identityProblem: identityProblem, homeDoor: homeDoor, pairingRequest: pairingRequest,
                                  olderDeviceAt: olderDeviceAt)
        status.update { $0.remote = remote }
    }

    private func save() {
        do { try store?.savePaired(paired) } catch { print("Remote access: the paired devices could not be saved (\(error)).") }
    }

    // MARK: Kind 18

    /// Who this Mac is and how to reach it, as of now (issuedAt 0: the comparison ignores it). No
    /// addresses before the first look at this Mac's networks (0.5–2.5 s after Remote Access or a
    /// pairing window starts the watcher): a list from nothing but the address name would replace
    /// a device's full one. A device keeps what it has when the list is empty; the first look
    /// broadcasts the real one.
    private func currentInfo() -> MacInfo? {
        guard let identity else { return nil }
        return MacInfo(macID: identity.macID, name: macName, issuedAt: 0, remoteAccess: remoteAccess,
                       remotePort: doorPort ?? remotePort, internet: internetAccess, addresses: reach == nil ? [] : addresses())
    }

    /// Kind 18, signed, issued now: in every catalog right after kind 16.
    func macInfoMessage() -> StreamMessage? {
        guard var info = currentInfo(), let identity else { return nil }
        info.issuedAt = Date().timeIntervalSince1970
        guard let signed = identity.sign(info) else { return nil }
        return StreamMessage(kind: .macInfo, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: Wire.encode(signed))
    }

    /// To every device, when anything but the time changed since the last broadcast.
    private func broadcastIfChanged() {
        guard let info = currentInfo(), info != lastBroadcast else { return }
        lastBroadcast = info
        if let m = macInfoMessage() { server?.broadcast(m) }
    }
}
