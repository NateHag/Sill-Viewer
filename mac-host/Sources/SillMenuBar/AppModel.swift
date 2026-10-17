import AppKit
import Observation
import Security
import SillHostCore
import StreamProtocol

/// Owns the host for the app: the settings, the coordinator, remote access and the small models
/// the menu and the windows bind to. Works out what the status item says (`presentation`)
/// whenever any of it changes, and holds the App Nap and sleep guard. Main actor.
@MainActor @Observable
final class AppModel {
    let settings: HostSettings
    let permissions: PermissionsModel
    let loginItem = LoginItemModel()
    /// The update check (GitHub's releases feed): the menu's "Sill 0.4 Is Available…" and Settings ›
    /// General's section. Started once the host has started, or could not.
    let updates: UpdateChecker
    /// `--synthetic`: the Desktop streams a test pattern and the host stays off Bonjour, exactly
    /// as with the CLI's flag. No onboarding in this mode.
    let synthetic = CommandLine.arguments.contains("--synthetic")
    private(set) var coordinator: StreamCoordinator?
    /// The coordinator could not be created (the listener refused its parameters). Shown in the
    /// menu; the app keeps running so the user can read it and quit.
    private(set) var startupError: String?
    /// What the status item, its card and the menu show.
    private(set) var presentation: StatusPresentation
    /// The Settings tab on screen, nil while Settings is closed: the panes that poll run only
    /// while theirs is visible.
    var visibleSettingsTab: SettingsTab?
    /// The last Require pairing change the identity store did not keep, for the Devices pane.
    private(set) var requirePairingProblem: RequirePairingProblem?

    /// A Require pairing change that was not saved: what was asked, and why not.
    struct RequirePairingProblem: Equatable {
        var wanted: Bool
        var reason: String
    }

    /// Sill.app itself, not the bare SillMenuBar binary: an app bundle's executable, which runs with
    /// Sill's Screen Recording and Accessibility grants. It honours no TEST ONLY variable or `-Sill…After`
    /// hook that bears on who gets in or what pairing needs (docs/home-pairing-plan.md §4.3, §6.6):
    /// any process of this user can start it with an environment and arguments.
    nonisolated static let bundled = Bundle.main.bundleURL.pathExtension == "app"

    /// Wired by the app delegate: the status item's glyph and tooltip, and the windows.
    @ObservationIgnored var onPresentation: ((StatusPresentation) -> Void)?
    @ObservationIgnored var showSettings: ((SettingsTab?) -> Void)?
    @ObservationIgnored var showLog: (() -> Void)?
    /// Shows the pairing window with this offer (or brings it forward with the same code).
    @ObservationIgnored var showPairing: ((RemoteAccess.PairingOffer) -> Void)?
    /// The pairing window, if it shows a code, brought forward and key; false when it shows none.
    @ObservationIgnored var bringPairingForward: (() -> Bool)?
    /// Closes the pairing window as its Cancel does; false when it was not on screen.
    @ObservationIgnored var closePairingWindow: (() -> Bool)?
    /// The notice for a device that paired by itself over the USB cable (its paired name and key).
    @ObservationIgnored var showCableNotice: ((CableNotice) -> Void)?
    /// TEST ONLY (-SillSettingsAfter): the Settings window's controller, once it has been made.
    @ObservationIgnored var settingsWindowForTests: (() -> SettingsWindowController?)?

    @ObservationIgnored private var loggedStatus: String?
    @ObservationIgnored private var napActivity: NSObjectProtocol?
    @ObservationIgnored private var napHold = NapHold.none
    /// Recomputes the presentation when a menu item that lasts a while runs out with nothing else
    /// changing then (the older-device item's 10 minutes).
    @ObservationIgnored private var presentationExpiry: Task<Void, Never>?
    @ObservationIgnored private var presentationExpiryAt: Date?

    init() {
        let settings = HostSettings()
        self.settings = settings
        permissions = PermissionsModel(settings: settings)
        let updates = UpdateChecker(configuration: DebugHooks.updateConfiguration(testPattern: CommandLine.arguments.contains("--synthetic")),
                                    automatic: false)   // Sill Desktop Host: Sill's releases are not this app's
        self.updates = updates
        // The switch reaches the checker from launch on: Settings… is in the menu before the host
        // is up (up to a second or more), and -SillSetAfter counts from launch. Before `start()`
        // the checker only records it.
        settings.onUpdateCheckChange = { [updates] in updates.setAutomatic(false) }   // Sill Desktop Host: never
        presentation = StatusText.present(snapshot: HostStatusSnapshot(),
                                          permissions: PermissionState(screenRecording: true, accessibility: true),
                                          startupError: nil, hasCoordinator: false)
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unbundled" }

    /// Starts the host: the same coordinator as the CLI, under the AppKit loop that is already
    /// running, asking for no permission at launch. Never exits on an error.
    func start() {
        observePresentation()
        // The lock notifications: the ask rule's second witness that this Mac is locked
        // (SessionLock), beside the session dictionary the CLI has alone.
        SessionLock.shared.watchNotifications()
        Task { @MainActor in
            do {
                // The identity before the coordinator: its TXT record (the tag, and `p` for Require
                // pairing) goes into the first Bonjour registration, and the home door speaks TLS
                // with it. A keychain failure leaves the home door closed and remote access
                // unavailable, not the app (docs/home-pairing-plan.md §6.1).
                let remote = makeRemoteAccess()
                settings.config.requirePairing = launchRequirePairing(remote)
                // The window lists carry this Sill's version, when it has one (the bare binary's
                // "dev" does not parse): later devices can tell which Mac to update.
                let c = try StreamCoordinator(config: settings.config, synthetic: synthetic, appKitLoop: true, remote: remote,
                                              homePairing: true, testHooks: !Self.bundled,
                                              hostVersion: SillVersion(Self.version) != nil ? Self.version : nil)
                c.keepRunningOnListenerFailure()
                coordinator = c
                // One path from the controls to the host, synchronous: the host's target equals
                // settings.config at every main-actor turn, so a device's change and a menu click
                // never undo each other.
                settings.onChange = { [settings, weak c] in c?.setTarget(settings.config) }
                // A device's change goes through HostSettings like a menu click: saved (only the keys
                // it changed) and shown live in Settings and the menu. Laid over settings.config, never
                // over the host's value: over the away quality for a device away from home, which
                // never changes the home one (docs/remote-bundle-plan.md §5). No validated(): the host
                // accepted only menu values, and validating here would rewrite unrelated hand-set
                // keys (which save(changedFrom:) would then write).
                c.onDeviceSettingsChange = { [settings] change, away in
                    settings.config = away ? settings.config.applyingAway(change) : settings.config.applying(change)
                    return settings.config
                }
                // Not in HostConfig (it moves no listener): handed over on its own.
                remote.setAddressName(settings.remoteAddressName)
                settings.onAddressNameChange = { [settings, weak remote] in remote?.setAddressName(settings.remoteAddressName) }
                await c.start(preselect: nil, promptForPermissions: false)
                Stats.shared.startPrinting()
                print("Sill \(Self.version) (\(Self.build)) running from \(Bundle.main.bundlePath); log file \(HostLog.shared.fileURL?.path ?? "none")")
                onboardIfNeeded()
            } catch {
                startupError = "\(error)"
                print("Sill couldn’t start: \(error)")
            }
            // Never before the host is up, and also when it could not start: a newer Sill may be the fix.
            startUpdates()
        }
    }

    // MARK: Updates

    /// The update check's schedule and the Mac waking (its switch is wired from `init`).
    private func startUpdates() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updates.systemDidWake() }
        }
        updates.start()
    }

    // MARK: Pairing and remote access

    /// The Mac's identity and trust list, and Require pairing beside them: a keychain in Sill.app,
    /// picked by IdentityStorePlan (docs/keychain-plan.md). An entitled Developer ID build (a
    /// provisioning profile embedded, so it holds a `keychain-access-groups` entitlement) uses the
    /// data-protection keychain, which no other process can pre-create or read; any other real
    /// Sill.app — a development build, or a release with no profile — uses the legacy login keychain.
    /// A test never touches a keychain: `--synthetic` keeps them in memory, and so does the bare
    /// SillMenuBar binary, whose ad hoc signature changes with every build. TEST ONLY: the bare
    /// binary with `--synthetic` (a test host) keeps them in SILL_TEST_REMOTE_DIR (a 0700 directory)
    /// instead; a real Sill.app ignores it with a line (a caller could hand it a trust list of its
    /// own).
    private func makeRemoteAccess() -> RemoteAccess {
        let store = makeIdentityStore()
        let remote = RemoteAccess(store: store)
        if let problem = remote.identityProblem { print("Remote access unavailable: \(problem)") }
        remote.restoreSeen(settings.remoteDevicesSeen())
        remote.onSeen = { [weak self, weak remote] prefix, at, route in
            let keep = Set(remote?.pairedPrefixes ?? [])
            self?.settings.rememberRemoteDevice(prefix, at: at, route: route, keep: keep)
        }
        remote.onPairingOffer = { [weak self] offer in self?.pairingOffered(offer) }
        // A device paired by itself over the USB cable: the notice, once per pairing.
        remote.onCablePaired = { [weak self] name, fingerprint in self?.showCableNotice?(CableNotice(name: name, fingerprint: fingerprint)) }
        return remote
    }

    /// The identity store IdentityStorePlan names for this launch (docs/keychain-plan.md), and one
    /// log line saying which keychain the identity is in and why. SILL_TEST_REMOTE_DIR is honoured
    /// only for a test host and otherwise ignored with a line, as before.
    private func makeIdentityStore() -> IdentityStore {
        let dir = ProcessInfo.processInfo.environment["SILL_TEST_REMOTE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let choice = IdentityStorePlan.choose(bundled: Self.bundled, synthetic: synthetic,
                                              entitledAccessGroup: Self.entitledKeychainAccessGroup(), testRemoteDir: dir)
        if dir != nil, case .testDirectory = choice {} else if dir != nil {
            print("SILL_TEST_REMOTE_DIR ignored: only a test host takes it (one that does not advertise and is not Sill.app itself).")
        }
        switch choice {
        case .dataProtection(let group):
            // The strong keychain: no other process can pre-create or read these items. Logged so a
            // release build can be confirmed hardened (and Noah's on-device pass can read it back).
            print("Remote access: the identity is in the data-protection keychain (access group \(group)).")
            return KeychainIdentityStore(accessGroup: group)
        case .legacy:
            // No keychain-access-groups entitlement (a development build, or a release with no
            // embedded provisioning profile): the login keychain, the profile-free fallback. Said in
            // the log so a build that should have hardened but did not is visible.
            print("Remote access: the identity is in the login keychain (no keychain-access-groups entitlement — a development build, or a release with no embedded provisioning profile; docs/keychain-plan.md).")
            return KeychainIdentityStore()
        case .memory:
            return MemoryIdentityStore()
        case .testDirectory(let path):
            do { return try FileIdentityStore(directory: URL(fileURLWithPath: path)) }
            catch { print("SILL_TEST_REMOTE_DIR=\(path) ignored: \(error)"); return MemoryIdentityStore() }
        }
    }

    /// The `keychain-access-groups` entitlement the running binary actually holds, from its own
    /// signature — the first group ending in the app's suffix, else the first. Nil for any build
    /// without an embedded provisioning profile (every development and ad hoc build reads its own
    /// entitlement as nil, measured 2026-09-27), which is exactly the signal to use the legacy store.
    /// This reads only this process's own entitlements; it authenticates nothing about other apps.
    private static func entitledKeychainAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) else { return nil }
        if let groups = value as? [String], !groups.isEmpty {
            return groups.first { $0.hasSuffix(".me.saffer.sill.mac") } ?? groups.first
        }
        if let group = value as? String, !group.isEmpty { return group }
        return nil
    }

    /// Require pairing at launch, from the identity store beside the trust list: on when it was
    /// never saved (an existing install comes up on), and never from UserDefaults, where any process
    /// of this user could turn it off (docs/home-pairing-plan.md §6.5). The bare binary also takes
    /// `-requirePairing YES|NO` and saves it in its own store (memory, or the test directory);
    /// Sill.app ignores the argument with a line.
    private func launchRequirePairing(_ remote: RemoteAccess) -> Bool {
        let stored = remote.storedRequirePairing()
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "requirePairing") != nil else { return stored }
        if Self.bundled {
            print("requirePairing ignored: Sill.app keeps Require pairing with its paired devices, never in its defaults or arguments; change it in Settings › Devices.")
            return stored
        }
        let wanted = defaults.bool(forKey: "requirePairing")
        // Off only once saved; on in any case (the safe side).
        if remote.saveRequirePairing(wanted) != nil, !wanted { return stored }
        return wanted
    }

    /// Settings › Devices' Require pairing (and the bare binary's -SillSetAfter): saved with the
    /// trust list first, then applied through `settings.config`, the one path to the host (the TXT
    /// record's `p`, and a goodbye to every unpaired device when it turns on). Turning it off takes
    /// effect only once saved: a save that fails leaves it on, with the keychain line in the pane.
    /// Turning it on always takes effect, for this run at least.
    func setRequirePairing(_ on: Bool) {
        guard on != settings.config.requirePairing else { requirePairingProblem = nil; return }
        guard let remote else { return }
        if let problem = remote.saveRequirePairing(on) {
            requirePairingProblem = RequirePairingProblem(wanted: on, reason: problem)
            guard on else { return }
        } else {
            requirePairingProblem = nil
        }
        settings.config.requirePairing = on
    }

    /// The host's remote access, once the coordinator is up.
    var remote: RemoteAccess? { coordinator?.remote }

    /// Pair iPhone or iPad… (the menu, the panes, -SillPairAfter): opens a pairing window, or
    /// brings the open one forward with its code (one a device opened becomes the remote door's too).
    func pairDevice() {
        // A window up already comes forward at once; the offer made again (with addresses, when a
        // device opened it) follows once the remote door's port and addresses are known.
        _ = bringPairingForward?()
        remote?.openPairing(requestedBy: nil)
    }

    /// The menu's "‹device› Wants to Pair": its window forward while it shows the code ("A code is
    /// showing."), else a window opened on the Mac, asked by that device ("Click to show a code.",
    /// or after the Mac was unlocked), which the request then follows (RemoteAccess: it ends when
    /// that window closes, or when the device pairs).
    func showPairingRequest(name: String, showing: Bool) {
        if showing, bringPairingForward?() == true { return }
        remote?.openPairing(requestedBy: name)
    }

    /// The pairing window was closed, or its Cancel clicked: the code dies with it.
    func cancelPairing() {
        remote?.cancelPairing()
    }

    /// Remove in the pane (and -SillUnpairAfter). Nil when done; otherwise why the device is still
    /// paired (the keychain could not be written), and its "last connected" stays too.
    @discardableResult
    func removeDevice(_ id: String) -> String? {
        let prefix = coordinator?.status.snapshot.remote?.paired.first { $0.id == id }?.keyPrefix
        if let problem = remote?.remove(fingerprint: id) { return problem }
        if let prefix { settings.forgetRemoteDevice(prefix) }
        return nil
    }

    func renameDevice(_ id: String, to name: String) {
        remote?.rename(fingerprint: id, to: name)
    }

    /// The pairing window's Turn On Remote Access: the Mac user's click. A pairing never turns it
    /// on by itself.
    func turnOnRemoteAccess() {
        settings.config.remoteAccess = true
    }

    /// An offer from the host: the window shows it. TEST ONLY: with the file store (--synthetic
    /// and SILL_TEST_REMOTE_DIR) the link and the code are also left in its directory, mode 0600,
    /// for a test client to read. Never printed: the print shadow copies stdout into Sill.log.
    private func pairingOffered(_ offer: RemoteAccess.PairingOffer) {
        if let dir = remote?.testDirectory {
            try? FileIdentityStore.writePrivate(Data(offer.url.utf8), to: dir.appendingPathComponent("pairing.url"))
            try? FileIdentityStore.writePrivate(Data(offer.code.utf8), to: dir.appendingPathComponent("pairing.code"))
        }
        showPairing?(offer)
    }

    // MARK: Status

    /// Recomputes the presentation now and again after anything it read changes: the host's
    /// snapshot, the coordinator appearing, the permissions, a startup error. Observation fires
    /// once, before the change lands, so each change hops to the next main-actor turn, re-reads
    /// the permissions (a revoked one shows with the status change it causes) and re-arms.
    private func observePresentation() {
        let next = withObservationTracking {
            currentPresentation()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.permissions.refresh()
                self?.observePresentation()
            }
        }
        publish(next)
    }

    private func currentPresentation() -> StatusPresentation {
        StatusText.present(snapshot: coordinator?.status.snapshot ?? HostStatusSnapshot(),
                           permissions: PermissionState(screenRecording: permissions.screenRecording,
                                                        accessibility: permissions.accessibility),
                           startupError: startupError, hasCoordinator: coordinator != nil, now: Date())
    }

    /// The older-device item ends 10 minutes after the connection it tells of, when nothing else
    /// need change: work the presentation out again then. (The "Wants to Pair" item's 5 minutes end
    /// in the host, which publishes.)
    private func scheduleExpiry() {
        let end = coordinator?.status.snapshot.remote?.olderDeviceAt?.addingTimeInterval(StatusText.olderDeviceShownFor)
        guard end != presentationExpiryAt else { return }       // the once-a-second stats change nothing here
        presentationExpiryAt = end
        presentationExpiry?.cancel()
        presentationExpiry = nil
        guard let end else { return }
        let left = end.timeIntervalSinceNow
        guard left > 0 else { return }
        presentationExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(left + 0.5))
            guard !Task.isCancelled, let self else { return }
            self.publish(self.currentPresentation())
        }
    }

    private func publish(_ next: StatusPresentation) {
        if next != presentation || loggedStatus == nil {
            presentation = next
            onPresentation?(next)
        }
        // One line per change of header or explanation; tests grep for "Status:".
        let line = next.subtitle.map { "\(next.header) — \($0)" } ?? next.header
        if line != loggedStatus {
            loggedStatus = line
            print("Status: \(line)")
        }
        let snapshot = coordinator?.status.snapshot
        holdAppNapOff(devices: snapshot?.devices.count ?? 0, remote: snapshot?.remoteDeviceCount ?? 0)
        scheduleExpiry()
    }

    private enum NapHold { case none, connected, remote }

    /// App Nap would coalesce this windowless app's timers once it is in the background, among
    /// them the 30 ms link keepalive ticks that keep a device's Wi-Fi out of power save, and the
    /// 2026-09-22 stutter would be back. So while a device is connected Sill holds a
    /// latency-critical activity, which still lets the Mac sleep when idle: a device at home can
    /// wake it (Bonjour Sleep Proxy) or walk over. A device connected from away cannot, so while
    /// one is, the activity is `.userInitiated`, which also keeps the Mac from idle sleep (the
    /// display may still sleep; docs/remote-access-plan.md §6.5). Switching ends one activity and
    /// begins the other.
    private func holdAppNapOff(devices: Int, remote: Int) {
        let want: NapHold = remote > 0 ? .remote : (devices > 0 ? .connected : .none)
        guard want != napHold else { return }
        if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
        napHold = want
        switch want {
        case .remote:
            napActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                reason: "Sill is serving a device connected from away")
        case .connected:
            napActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                                reason: "Sill is serving a connected device")
        case .none:
            break
        }
    }

    /// First launch, or any launch until the user closes Settings on it: when a permission is
    /// missing, Settings opens on Permissions. The test pattern needs none.
    private func onboardIfNeeded() {
        permissions.refresh()
        guard !synthetic, !permissions.allGranted, !settings.permissionsOnboardingDismissed else { return }
        showSettings?(.permissions)
    }
}
