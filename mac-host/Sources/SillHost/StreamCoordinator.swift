import Foundation
import AppKit
import Network
import ScreenCaptureKit
import StreamProtocol

/// Owns the pipeline for the life of the process and points it at whatever source the client
/// picks. Threading: this class is main-actor; frames flow capture queue → VT thread → network
/// queue without touching it. Network callbacks hop here with Task { @MainActor }.
@MainActor
package final class StreamCoordinator {
    /// The knobs (HostConfig.swift): the CLI's `standard` values and flag, or the app's Settings.
    /// A new value is taken only between pipelines, inside `select` (see `setTarget`), so one
    /// pipeline never mixes two. The knob properties below read it, so every existing read keeps
    /// its text.
    package private(set) var config: HostConfig
    /// Settings from the app or a device that wait for the next `select` (a restart, or a switch in
    /// flight). This, else `config`, is the `target`: what the Mac's menu and the devices show.
    private var pendingConfig: HostConfig?
    /// Ceiling for the stream rate (HostConfig). Each device asks for its own panel's rate
    /// through the viewport: 120 on ProMotion, 60 elsewhere, 60 while Low Power Mode caps it.
    private var maxFPS: Int { config.maxFPS }
    /// The rate the current pipeline runs at, re-read from `wantedFPS` at every select. Capture
    /// interval, encoder session and virtual display refresh all follow it.
    private(set) var fps: Int = 60
    /// Each connected client's wanted rate (60 for one that has not said). The stream runs at the
    /// highest, so a ProMotion device is not held to a 60 Hz one beside it; a re-sent viewport
    /// from either is then a no-op instead of a restart. Cleared when the client leaves.
    private var clientFPS: [ObjectIdentifier: Int] = [:]
    private var wantedFPS: Int { min(maxFPS, max(24, clientFPS.values.max() ?? 60)) }
    /// What the next pipeline will run at: the software encoder is not asked for more than 60.
    private var effectiveFPS: Int { useSoftwareEncoder ? min(wantedFPS, 60) : wantedFPS }
    /// The bitrate knob is per 60 fps; a faster stream gets proportionally more so each frame
    /// keeps its share of bits.
    private var streamBitrate: Int { bitrate * fps / 60 }
    /// The quality the pipeline runs: the away pair while it runs the away quality (`awayRunning`),
    /// else the home pair (HostConfig.effective).
    private var scale: CGFloat { config.effective(away: awayRunning).captureScale }
    private var bitrate: Int { config.effective(away: awayRunning).bitrate }
    private var prioritizeSpeed: Bool { config.prioritizeSpeed }

    let server: StreamServer
    let catalog = WindowCatalog()
    let capture = WindowCapture()
    /// `--synthetic`: the Desktop source streams a test pattern instead of the screen.
    let synthetic: Bool
    let syntheticCapture = SyntheticCapture()
    let injector = InputInjector()
    let sizer = WindowSizer()
    /// The Mac's pointer (PointerWatch): who moves it, and where it is in the streamed source, for
    /// the devices that are not moving it (kind 26, sent by StreamServer). Its geometry follows the
    /// source (`pointerGeometry`); InputInjector and VirtualStage note Sill's own motion there.
    let pointer: PointerWatch
    /// The test pattern's size in points (a synthetic host's Desktop), and the space the TEST ONLY
    /// scripted pointer moves in.
    static let testPatternRect = CGRect(x: 0, y: 0, width: 1512, height: 949)
    /// TEST ONLY (SILL_TEST_SOFTWARE_ENCODER=1, a synthetic host): every stream runs on the software
    /// encoder, the launch probe never runs and the re-check never starts, so no test touches the
    /// Mac's one hardware encoder while Noah streams (PointerTestHooks).
    private let softwareOnly: Bool
    /// The TEST ONLY hooks' lines (PointerTestHooks, InputInjector.testInputLog), printed as `start`
    /// begins; empty without them.
    private let testHookLines: [String]
    /// A picked window streams from its own HiDPI display (see VirtualStage): the CLI's
    /// `--virtual-display`, or the app's setting. Every branch this adds is behind this flag;
    /// without it the coordinator behaves as before. It changes only inside `select` (`adopt`).
    private var virtualDisplay: Bool { config.virtualDisplay }
    /// This process runs NSApplication's event loop (the app always, the CLI under
    /// --virtual-display), so `NSWorkspace.frontmostApplication` is current (see `activePID`).
    /// The virtual display needs that loop too: without it the setting is forced off.
    private let appKitLoop: Bool
    let stage: VirtualStage
    /// What the menu bar app shows. Written here, at the moment things happen; never read back.
    package let status: HostStatus
    /// Set by the signal handler: a select in flight when Ctrl-C lands must not stage anything new.
    private var shuttingDown = false
    private var stageLosses = 0
    /// The private CGVirtualDisplay API is checked once per run, the first time the mode is on.
    private var apiChecked = false
    /// Why that check failed, if it did: the virtual display then stays off for the whole run.
    private var apiProblem: String?
    private var encoder: HEVCEncoder? { didSet { encoderBox.current = encoder } }
    /// Hardware HEVC normally. When a hardware session stops returning frames, or the launch probe
    /// gets no answer, the stream runs on the software encoder at half the capture scale and up to
    /// 60 fps, slow but alive (`enterSoftwareFallback`), until a re-check finds the hardware keeping
    /// up with the stream again (`recheckLoop`, `hardwareIsBack`). The hardware has been stuck for
    /// hours (2026-09-22) and busy for seconds (2026-09-24, when this used to last until the host
    /// relaunched: 3 h at half resolution after a 1.8 s stall).
    private var useSoftwareEncoder = false
    private var softwareRestarts = 0
    private var lastSoftwareHangAt: CFAbsoluteTime = 0
    /// The re-check while on the software encoder. It runs only while a device is connected, so an
    /// idle host opens no hardware session. Only the task itself clears it, when its loop has ended
    /// (`stopRecheck` only cancels), so there is never a second loop, and never two tests at once;
    /// `recheckToken` keeps an ended task from clearing a newer one.
    private var recheckTask: Task<Void, Never>?
    private var recheckToken = 0
    /// Seconds from one re-check to the next: 30 at first, doubled up to 300 by a check where the
    /// hardware did not keep up (no answer, or too slow) or by a hardware hang within 5 min of a
    /// return (the busy spell was still on), and back to 30 when a return had lasted 10 min.
    private var recheckInterval = StreamCoordinator.recheckFirstInterval
    /// When the next re-check may run, and when the last one ran (or the fallback began).
    private var recheckDue: CFAbsoluteTime = 0
    private var lastRecheck: CFAbsoluteTime = 0
    /// The re-check found `maxStuckProbes` probes still stuck and said so; cleared by a return.
    private var recheckHeldBack = false
    /// When the stream last went back to the hardware encoder (0: never), and the newest encoder
    /// at that moment: a hang reported by an encoder no newer than that is stale and must not put
    /// the host back on the software encoder.
    private var lastReturnAt: CFAbsoluteTime = 0
    private var returnSerial = 0
    /// 30 s, and 300 s at most. TEST ONLY: `SILL_TEST_RECHECK_SECONDS=N` makes them N and 10 N, so
    /// the backoff and the stuck-probe limit can be run through in a minute.
    private static let recheckFirstInterval = TimeInterval(ProcessInfo.processInfo.environment["SILL_TEST_RECHECK_SECONDS"] ?? "") ?? 30
    private static let recheckMaxInterval = recheckFirstInterval * 10
    /// A hang this soon after a return doubles the interval; a return that lasted this long resets it.
    private static let returnDidNotLast: TimeInterval = 300
    private static let returnLasted: TimeInterval = 600
    /// What the encoder engine does alone, in pixels a second, for the rate a return needs
    /// (`EncoderProbe.returnBar`): the best any re-check's test measured this run, and until then
    /// an assumed rate below what this Mac's engine does.
    private var enginePixelRate = EncoderProbe.assumedEnginePixelRate
    /// TEST ONLY. `SILL_TEST_PROBE_SIZE=WxH`: the re-check tests this size instead of the stream's,
    /// as for a Retina 5K or 6K Desktop on a smaller screen. Read once; nil without it.
    private static let testProbeSize: (width: Int, height: Int)? = {
        let parts = (ProcessInfo.processInfo.environment["SILL_TEST_PROBE_SIZE"] ?? "").split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] >= 64, parts[1] >= 64 else { return nil }
        return (parts[0] & ~1, parts[1] & ~1)
    }()
    /// Probes whose frame never came back each hold a blocked thread (a stuck encoder never lets
    /// go); with this many out, the re-check stops probing until one comes back. A busy encoder
    /// hands them back within seconds, so only a stuck one reaches it (after 22–28 min of checks
    /// with no answer).
    private static let maxStuckProbes = 8
    /// The current encoder, readable off the main actor: the network queue asks it for a keyframe
    /// after dropping a delta. A lock instead of an actor hop keeps that request immediate.
    private let encoderBox = EncoderBox()
    private final class EncoderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: HEVCEncoder?
        var current: HEVCEncoder? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }
    package private(set) var active: StreamSource = .none {
        didSet {
            if case .window(let id) = active { catalog.activeWindowID = id } else { catalog.activeWindowID = nil }
            if active == .none { status.update { $0.stream = nil } }
            server.setStreaming(active != .none)   // link keepalive ticks while a source is live
            cursorShapes.running = active != .none
            pointer.setGeometry(pointerGeometry(), fps: fps)   // also on a restart of the same source
            menuTargetChanged()                     // the menus' app follows the source (only for devices that asked)
        }
    }
    private var rectCache: (id: CGWindowID, rect: CGRect, at: CFAbsoluteTime)?
    private var pendingLaunch: String?
    private var switching = false
    /// A restart of the active source is in flight (a settings change, a resize, a rate change,
    /// the encoder fallback, a lost display): the source being restarted. Nil during a switch to
    /// another source.
    private var restartOf: StreamSource?
    /// A device's pick of a different source that came in during that restart (`handlePick`);
    /// taken by select's defer. Never set during a switch to another source: the device's automatic
    /// Desktop request can land then (StreamClient's window list handling) and must not override
    /// the user's pick.
    private var pickArrivedWhileSwitching: StreamSource?
    /// The client's last stream panel size and text scale. One stream, so with several clients
    /// the last one to report wins.
    private var viewport: Viewport?
    /// The windows Sill sized for a device in regular mode, each with its way back (WindowRestore,
    /// issue #57): recorded at the first fit (`fitToViewport`), put back when the window stops
    /// streaming (`restoreFits`), handed to the virtual display's stage when it takes the window.
    private var fits = WindowRestore.Ledger<WindowSizer.Placement>()
    /// The window streaming in regular mode was in full screen when the catalog last listed it (its
    /// frame covered a display), or when it was picked: off the list, it may be leaving full screen
    /// (`windowsChanged`, WindowRestore.keepsStreaming).
    private var listedFullScreen: CGWindowID?
    /// Each connection's kind 17 changes of the last second (applied or refused), and when its
    /// "ignored" line was last printed: `settingsPerSecond` a second, one line a second at most.
    private var settingsArrivals: [ObjectIdentifier: [CFAbsoluteTime]] = [:]
    private var settingsIgnoredLineAt: [ObjectIdentifier: CFAbsoluteTime] = [:]
    static let settingsPerSecond = 4
    /// Trackpad gestures (kind 28, docs/trackpad-gestures-plan.md §7): the view Sill's last gesture
    /// opened, which the opposite gesture closes (GestureChords), and each connection's gestures of
    /// the last second: `gesturesPerSecond` a second, the rest dropped with one line a minute.
    private var gestureChords = GestureChords()
    private var gestureArrivals: [ObjectIdentifier: [CFAbsoluteTime]] = [:]
    static let gesturesPerSecond = 4
    private lazy var gestureDrops = RefusalSummary(queue: .main, categories: ["gestures"]) { counts in
        "Gestures ignored: \(counts["gestures"] ?? 0) in a minute, from devices sending more than \(StreamCoordinator.gesturesPerSecond) a second."
    }
    /// Gestures waiting for a switch in flight to finish, in arrival order, and the task posting them.
    private var pendingGestures: [(gesture: TrackpadGesture, device: String)] = []
    private var gestureDrain: Task<Void, Never>?
    /// A host that does not advertise (the synthetic test hosts, which tests reach by port) posts no
    /// gesture's chord: it logs the one it would post, "(not posted: a test host)", and counts
    /// `in.gestureDry`, so a test can send gestures without touching this Mac.
    private let gesturesDry: Bool
    /// TEST ONLY: a test host's SILL_TEST_HOTKEYS table (GestureChords.testTable), used instead of
    /// this Mac's Keyboard Shortcuts; nil on every other host.
    private let testHotKeys: [Int: HotKey]?
    /// This macOS had no getters for its Keyboard Shortcuts at a gesture: said once.
    private var saidHotKeysMissing = false
    /// A viewport that came in mid-switch, when `active` still names the old source: applied once
    /// the switch is done, so a rotation during a restart is not lost.
    private var viewportArrivedWhileSwitching = false
    /// The last client left mid-switch, when `select(.none)` would have been refused (or `active`
    /// still named the old source): applied once the switch settles, if the room is still empty.
    /// Matters most with `--virtual-display`, where a switch can take seconds and would otherwise
    /// leave the window on the virtual display, streaming to nobody.
    private var deselectWhenSettled = false
    /// The Mac's cursor shape, streamed to the clients that draw the pointer themselves.
    let cursorShapes = CursorShapeWatcher()
    private let macName = Host.current().localizedName ?? "Mac"
    /// In every window list (`WindowList.launchID`): a device moving its session from AWDL to the
    /// network checks that the new connection reaches this same running host, since the Bonjour
    /// name it found it by can belong to another Mac too. Per launch, so nothing is stored.
    private let launchID: String
    /// In every window list (`WindowList.hostVersion`, with `protocol`): Sill.app's version; nil
    /// from the CLI, which has no bundle. For later devices, which can then say which Mac to update.
    private let hostVersion: String?
    /// Remote access (RemoteAccess): Sill.app always, SillHost only with --remote or --pairing
    /// (with --pairing alone, an identity for the TLS home door and no remote door). Nil: no
    /// identity, no TXT tag, no kind 18, no remote door, no `away` in kind 16: exactly the host
    /// as before.
    package let remote: RemoteAccess?
    /// Each admitted connection's route (home and its origin, or the remote door's), from the server.
    private var routes: [ObjectIdentifier: ClientRoute] = [:]
    /// Away from home (docs/remote-bundle-plan.md §5; AwayPolicy): every connected device is away,
    /// so the away quality is the target. Kept while no device is connected; the next to register
    /// decides (`routesChanged`). What the Mac's card, menu and every device are told.
    private var awayWanted = false
    /// The away quality runs: the value the last `select` (or `adopt`) took. The pipeline reads it.
    private(set) var awayRunning = false
    /// A device that joined and flipped `awayWanted` (`routesChanged`): its first viewport, which
    /// carries its rate and which a device sends as soon as it is connected, takes the flip in the
    /// same restart as the rate; without one within a second (a test client), the flip goes alone.
    /// Nothing else applies the flip meanwhile but a `select` that runs anyway, which takes it.
    private var flipWait: ObjectIdentifier?
    private var flipWaitToken = 0
    /// Each connection whose catalog went out (`sendCatalog`): the ones settings states reach.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Each connection's link while it does not keep up (LinkJudge, docs/remote-bundle-plan.md §6.5):
    /// its kind 16's `link`, and the card's. A state leaves out a report whose bitrate (the running
    /// one when it was judged) is no longer the target's, so the answer to the pick that lowers it
    /// already carries none (the restart's reset follows). The bitrate alone: a change of the capture
    /// scale alone may restart nothing (the software encoder runs at points).
    private var linkReports: [ObjectIdentifier: LinkReport] = [:]
    /// The quality the devices' links are judged at: the running stream's (`select`'s commit), nil
    /// while nothing streams. A restart that keeps it keeps their judgement (LinkJudge.judgedAfresh).
    private var judgedQuality: LinkJudge.Quality?
    /// When each connection last asked for a pairing code (kind 21): once per 30 s.
    private var lastPairingWanted: [ObjectIdentifier: CFAbsoluteTime] = [:]
    /// The streamed app's menus, for the devices that asked for them (kinds 24, 25 and 27,
    /// MenuMirror). Reads and presses nothing for a device that never asked.
    let menus: MenuMirror
    /// The clipboard both ways (kind 32, HostClipboard; docs/clipboard-plan.md), for the devices that
    /// subscribed, while Share clipboard with devices (`HostConfig.shareClipboard`) is on. Looks at
    /// nothing while nobody subscribes.
    let clipboard: HostClipboard
    /// TEST ONLY. `SILL_TEST_MENU_PID=<pid>` on a --synthetic host: the test pattern's menus are that
    /// process's (the gates' fixture, Scripts/menufixture.swift), read and pressed through the same
    /// code, never activated (the Desktop's rule). Nil otherwise; `testMenuLine` is what `start`
    /// prints about it, only when the variable is set.
    private let testMenuPID: pid_t?
    private let testMenuLine: String?
    /// The Desktop's frontmost app is looked at again 0.3 s after a device's click or key, at most
    /// once per 0.5 s (a click on another app's window activates it 50–200 ms later).
    private var menuFrontCheckAt: CFAbsoluteTime = 0
    private var menuFrontCheckPending = false
    /// Under the AppKit loop, while a device subscribes: app activations on the Mac.
    private var frontmostObserver: NSObjectProtocol?

    /// `config` is validated, and its virtual display forced off without the AppKit loop, which
    /// the display needs (VirtualDisplay.swift, "Event loop"). `appKitLoop`: see the property.
    /// `homePairing`: the home door speaks TLS with `remote`'s identity and trust list
    /// (docs/home-pairing-plan.md §4.9; Sill.app, SillHost --pairing), or has no listener at all
    /// when that identity could not be loaded; without it the home door is plain, as before (the
    /// CLI's default). `testHooks`: false for Sill.app's own executable, which honours no TEST ONLY
    /// hook that bears on who gets in or what pairing needs (§4.3): with it false, or on a host
    /// that advertises, those hooks are ignored with one line each. `hostVersion`: Sill.app's
    /// version for the window lists, when it has one that parses.
    package init(config: HostConfig, synthetic: Bool = false, appKitLoop: Bool, remote: RemoteAccess? = nil,
                 homePairing: Bool = false, testHooks: Bool = true, hostVersion: String? = nil) throws {
        var config = config.validated()
        if !appKitLoop { config.virtualDisplay = false }
        self.config = config
        self.synthetic = synthetic
        self.appKitLoop = appKitLoop
        self.hostVersion = hostVersion
        let env = ProcessInfo.processInfo.environment
        let path = PointerTestHooks.pointerPath(synthetic: synthetic, environment: env)
        let software = PointerTestHooks.softwareEncoder(synthetic: synthetic, environment: env)
        let inputLog = InputInjector.testInputLog(synthetic: synthetic, environment: env)
        pointer = PointerWatch(synthetic: synthetic, path: path.path)
        softwareOnly = software.on
        testHookLines = [path.line, software.line, inputLog.line].compactMap { $0 }
        status = HostStatus()
        var home = StreamServer.HomeDoorMode.plain
        if homePairing, let remote {
            if let identity = remote.identity {
                home = .tls(StreamServer.HomeTLS(identity: identity, trust: remote.trust))
            } else {
                home = .closed("Sill couldn’t use its key \(remote.keyPlace) (\(remote.identityProblem ?? "no identity"))")
            }
        }
        // The test pattern is for test clients, not devices.
        server = try StreamServer(advertise: !synthetic, home: home, testHooks: testHooks)
        server.macName = macName                           // the update goodbye names this Mac (DeviceGate)
        TestHooks.reportIgnored(testHost: server.isTestHost)
        // A host that does not advertise, `--synthetic` in the CLI and in the app alike (as
        // `injector.dryRun` below), not `server.isTestHost`, which also leaves out Sill.app's own
        // executable: that narrowing is for the door and pairing hooks (TestHooks), and a gesture's
        // chord must never be posted from the test pattern.
        gesturesDry = synthetic                            // a test host never posts a gesture (§7.4)
        testHotKeys = synthetic ? Self.testHotKeyTable() : nil
        menus = MenuMirror(server: server)
        let launch = UUID().uuidString
        launchID = launch
        // A synthetic host shares a pasteboard of its own, never this Mac's clipboard.
        clipboard = HostClipboard(server: server, enabled: config.shareClipboard, launchID: launch, synthetic: synthetic)
        let hook = Self.testMenuHook(synthetic: synthetic)
        testMenuPID = hook.pid
        testMenuLine = hook.line
        self.remote = remote
        // Direct Wireless is the listener's: built with it at start, replaced when it changes (adopt).
        server.setPeerToPeer(config.directWireless)
        stage = VirtualStage(sizer: sizer, catalog: catalog)
        // Sill's own motion is Sill's: the server counts each device's input, the injector notes
        // each post just before it (and a synthetic host posts nothing: the test pattern is not the
        // screen, docs/pointer-visibility-plan.md Q10), the stage its warp home.
        server.pointerWatch = pointer
        injector.watch = pointer
        injector.dryRun = synthetic
        injector.testLog = synthetic && inputLog.on
        stage.onWarp = { [pointer] in pointer.sillMoved() }
        // The identity's TXT record (its tag, and `p` on a TLS home door) must be in the first
        // registration: set before `server.start()`.
        remote?.attach(server: server, status: status, macName: macName, requirePairing: config.requirePairing)
        catalog.preferMainDisplay = virtualDisplay   // the Desktop source must never capture the virtual display
        stage.onLost = { [weak self] in Task { @MainActor in await self?.stageLost() } }
        status.update { $0.synthetic = synthetic; $0.virtualDisplayOn = config.virtualDisplay }
        // Every change of the snapshot re-publishes the devices' settings state (deduplicated, so
        // the once-a-second stats send nothing). One before `server.start()` reaches nobody, and
        // every device gets a fresh state in `sendCatalog`, so early calls are harmless.
        status.onChange = { [weak self] in self?.publishSettings() }
        menus.prepare = { [weak self] in await self?.focusForMenus() ?? true }
        menus.currentTarget = { [weak self] in self?.menuTarget() }
        menus.onSubscribersChanged = { [weak self] any in self?.watchFrontmostApp(any) }
        catalog.onPolled = { [weak self] in self?.menusPolled() }

        server.onClientConnected = { [weak self] connection, route, link in
            Task { @MainActor in
                guard let self else { return }
                let id = ObjectIdentifier(connection)
                self.routes[id] = route
                // A paired device shows its paired name until its own stats arrive, and a remote one
                // its route; a home device its link (Wired, Wi-Fi, Direct) as soon as it is known.
                self.status.update {
                    $0.devices.append(HostStatusSnapshot.Device(id: id, endpoint: "\(connection.endpoint)", name: route.pairedName,
                                                                route: link, remoteRoute: route.label))
                }
                // A paired key's session, at either door: the pane's "last connected", and over the
                // cable the iPhone or iPad the key runs on (learned once).
                if let fp = route.fingerprint, route.pairedName != nil {
                    let words = route.label ?? Self.homeRouteWords(route, link: link)
                    self.remote?.sessionStarted(fingerprint: fp, route: words, cableDevice: route.cableDevice)
                }
                // Home or away before its catalog: its settings state says which quality it sets.
                self.routesChanged(joined: id, endpoint: "\(connection.endpoint)")
                // Catalog first: the client's UI needs it even if the keyframe is slow to come.
                self.catalog.thumbnailsWanted = true
                self.sendCatalog(to: connection)
                self.encoder?.requestKeyframe()
            }
        }
        // Each device's link (LinkJudge): the report its kind 16 carries, the card's row, one line.
        server.onClientLinkChanged = { [weak self] connection, verdict in
            let id = ObjectIdentifier(connection)
            Task { @MainActor in self?.linkChanged(id, verdict) }
        }
        server.onKeyframeNeeded = { [weak self] in
            // Network queue → encoder lock: the next repaint carries the keyframe, or the last frame is
            // re-encoded once the window has been still for 50 ms (HEVCEncoder.requestKeyframe).
            self?.encoderBox.current?.requestKeyframe()
        }
        server.onClientDisconnected = { [weak self] connection in
            Task { @MainActor in
                guard let self else { return }
                self.clientFPS[ObjectIdentifier(connection)] = nil
                self.settingsArrivals[ObjectIdentifier(connection)] = nil
                self.settingsIgnoredLineAt[ObjectIdentifier(connection)] = nil
                let id = ObjectIdentifier(connection)
                self.gestureArrivals[id] = nil
                self.routes[id] = nil
                self.lastPairingWanted[id] = nil
                self.connections[id] = nil
                self.lastPublished[id] = nil
                self.linkReports[id] = nil
                if self.flipWait == id { self.flipWait = nil }
                self.menus.clientLeft(connection)
                self.clipboard.clientLeft(connection)
                self.releaseKeys(of: id)
                self.status.update { $0.devices.removeAll { $0.id == id } }
                // The last device at home left devices away behind: the away quality, at once.
                let flipped = self.routesChanged(joined: nil, endpoint: nil)
                // A 120 Hz device left a 60 Hz one behind: come down to its rate. The restart takes
                // the flip too (select's commit), so a device that leaves costs one.
                if self.active != .none, self.catalog.clientCount > 1, self.effectiveFPS != self.fps {
                    await self.select(self.active)
                } else if flipped {
                    await self.applyPending()
                }
            }
        }
        server.onClientCountChanged = { [weak self] count in
            Task { @MainActor in
                guard let self else { return }
                let wasEmpty = self.catalog.clientCount == 0
                self.catalog.clientCount = count          // the catalog idles itself at 0
                // Nobody is watching: stop capturing and encoding. The next client picks afresh.
                if count == 0 { self.viewport = nil; self.clientFPS = [:] }   // the next device starts from scratch
                if count == 0 { self.gestureChords.forget() }                 // and did not open a view it could close
                // On the software encoder, the hardware is checked only while someone watches.
                if count == 0 { self.stopRecheck() } else { self.devicesPresent(firstArrived: wasEmpty) }
                if count > 0 {
                    self.deselectWhenSettled = false
                } else if self.switching {
                    self.deselectWhenSettled = true     // `select` would refuse it now; its tail applies it
                } else if self.active != .none {
                    await self.select(.none)
                }
            }
        }
        cursorShapes.onChange = { [weak self] blob in
            self?.server.broadcast(StreamMessage(kind: .cursorShape, timestamp: Date().timeIntervalSince1970,
                                                 isKeyframe: false, payload: blob))
        }
        catalog.onInstalledAppsReady = { [weak self] apps in
            guard let self else { return }
            self.server.broadcast(StreamMessage(kind: .appList, timestamp: Date().timeIntervalSince1970,
                                                isKeyframe: false, payload: Wire.encode(apps)))
        }
        server.onMessage = { [weak self] message, connection in
            Task { @MainActor in await self?.handle(message, from: connection) }
        }
        catalog.onWindowsChanged = { [weak self] infos in
            Task { @MainActor in await self?.windowsChanged(infos) }
        }
        catalog.onThumbnail = { [weak self] id, jpeg in
            self?.server.broadcast(StreamMessage(kind: .thumbnail, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                                 payload: ImageBlob.encodeThumbnail(windowID: id, jpeg: jpeg)))
        }
        catalog.onNewIcon = { [weak self] id, png in
            self?.server.broadcast(StreamMessage(kind: .appIcon, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                                 payload: ImageBlob.encodeIcon(bundleID: id, png: png)))
        }
        capture.onStopped = { [weak self] error in
            print("Capture stopped: \(error.localizedDescription)")
            Task { @MainActor in await self?.select(.none) }
        }
        // Status for the menu bar app. The server's callbacks hop here from its network queue; the
        // stats tick runs on the main queue, which under the CLI's dispatchMain is drained by a
        // worker thread, so it hops too instead of assuming main-actor isolation (that traps).
        server.onListenerState = { [weak self] state in
            let network: HostStatusSnapshot.Network
            switch state {
            case .ready: network = .registering          // refined in `listenerChanged`
            case .waiting(let e): network = .waiting("\(e)")
            case .failed(let e): network = .failed("\(e)")
            default: return
            }
            Task { @MainActor in self?.listenerChanged(network) }
        }
        server.onServiceRegistered = { [weak self] name in
            Task { @MainActor in self?.serviceRegistered(name) }
        }
        // Display only: the menu card's word for how the device reaches this Mac.
        server.onClientRouteChanged = { [weak self] connection, route in
            let id = ObjectIdentifier(connection)
            Task { @MainActor in
                self?.status.update {
                    guard let i = $0.devices.firstIndex(where: { $0.id == id }) else { return }
                    $0.devices[i].route = route
                }
            }
        }
        // A device's hello names it before its first stats (a second later): the card shows
        // "iPad (iPad14,1)" from the first moment instead of an address. Its stats replace it, as
        // they always did; a remote device keeps its paired name meanwhile.
        server.onClientHello = { [weak self] connection, hello in
            let id = ObjectIdentifier(connection)
            let name = SafeText.label(hello.device ?? "")
            guard !name.isEmpty else { return }
            Task { @MainActor in
                self?.status.update {
                    guard let i = $0.devices.firstIndex(where: { $0.id == id }), $0.devices[i].name == nil else { return }
                    $0.devices[i].name = name
                }
            }
        }
        server.onClientStats = { [weak self] connection, stats in
            let id = ObjectIdentifier(connection)
            // The device's own words, cleaned before the menu, Settings or a log line shows them.
            let name = SafeText.label(stats.device)
            Task { @MainActor in
                self?.status.update {
                    guard let i = $0.devices.firstIndex(where: { $0.id == id }) else { return }
                    $0.devices[i].name = name.isEmpty ? nil : name
                    $0.devices[i].fps = stats.fps
                    $0.devices[i].frameAgeMs = stats.frameAgeMs
                    $0.devices[i].rttMs = stats.rttMs
                }
                // How long this device waits for a menu (the second's worst round trip; the median
                // from an older device): a request whose turn comes later is not read.
                self?.menus.clientStats(connection, rttMs: stats.rttMaxMs ?? stats.rttMs)
            }
        }
        Stats.shared.onTick = { [weak self] counts in
            let encoded = counts["enc.out"] ?? 0
            Task { @MainActor in self?.status.update { $0.encodedFPS = encoded } }
        }
        // A check's frame came back late (on a utility queue): the encoder may not be stuck after all.
        EncoderProbe.onStalledProbeBack = { [weak self] seconds in
            Task { @MainActor in self?.stalledProbeCameBack(after: seconds) }
        }
    }

    /// How the Devices pane says a paired device last connected at home: "over the USB cable",
    /// "on this Mac", "directly" (peer-to-peer Wi-Fi), "over Wi‑Fi", "over Ethernet", else "at home".
    static func homeRouteWords(_ route: ClientRoute, link: ClientLink.Route?) -> String {
        if route.cableDevice != nil { return "over the USB cable" }
        if route.origin == .loopback { return "on this Mac" }
        switch link {
        case .direct?: return "directly"
        case .wifi?: return "over Wi\u{2011}Fi"
        case .wired?: return "over Ethernet"
        case nil: return route.origin == .direct ? "directly" : "at home"
        }
    }

    /// The listener is up, waiting or failed. Up means registering until Bonjour confirms a name,
    /// or not advertised at all in synthetic mode; a late "ready" never undoes a registered name.
    private func listenerChanged(_ network: HostStatusSnapshot.Network) {
        status.update {
            guard network == .registering else { $0.network = network; return }
            if synthetic {
                $0.network = .notAdvertised(port: Int(server.port ?? 0))
            } else if case .advertising = $0.network {
                return
            } else {
                $0.network = .registering
            }
        }
    }

    /// Bonjour registered this name (nil: the registration went away, to come back).
    private func serviceRegistered(_ name: String?) {
        status.update {
            if let name {
                $0.network = .advertising(name)
            } else if case .advertising = $0.network {
                $0.network = .registering
            }
        }
    }

    /// `preselect` is the optional command-line match; without it nothing streams until a client picks.
    /// `promptForPermissions: false` (the app) asks for nothing at launch: no Accessibility alert,
    /// and no window list before Screen Recording is granted, because the first ScreenCaptureKit
    /// call raises the system's Screen Recording alert. That should follow a click in Settings or
    /// a device connecting, not a login.
    package func start(preselect: String?, promptForPermissions: Bool = true) async {
        for line in testHookLines { print(line) }
        if let line = clipboard.testHookLine { print(line) }   // TEST ONLY, and only with one of its variables set
        if !synthetic, promptForPermissions { InputInjector.ensureAccessibility() }   // prompts once; input is dropped silently without it
        if softwareOnly {
            // TEST ONLY: a gate that must never touch the Mac's one hardware encoder (Noah may be
            // streaming): the software encoder from the start, no probe, no re-check.
            useSoftwareEncoder = true
            status.update { $0.softwareEncoder = true }
        } else {
            // One small frame through the hardware encoder before anything streams. If the Mac's
            // hardware encoder is stuck or busy, start on the software encoder now, instead of
            // hanging the first stream for 1.5 s and restarting it; the re-check comes back to the
            // hardware once it answers.
            let hardwareResponds = await Task.detached(priority: .userInitiated) { EncoderProbe.hardwareResponds() }.value
            if !hardwareResponds { enterSoftwareFallback(afterHang: false) }
        }
        if virtualDisplay { enableVirtualDisplay() }
        catalog.start()
        // The only startup line Direct Wireless adds, and only when it is on: the default path
        // prints what it always printed.
        if config.directWireless {
            print("Direct wireless connection on: also advertised over peer-to-peer Wi-Fi (AWDL), which takes this Mac's Wi-Fi off its channel for up to ~100 ms twice a second.")
        }
        if let testMenuLine { print(testMenuLine) }   // TEST ONLY, and only with SILL_TEST_MENU_PID set
        server.start()
        remote?.apply(config)        // the remote door, when Remote Access is on (or a pairing window opens later)
        if promptForPermissions || CGPreflightScreenCaptureAccess() { await catalog.refreshWindows() }
        if let match = preselect?.lowercased(),
           let w = catalog.infos.first(where: { $0.appName.lowercased().contains(match) || $0.title.lowercased().contains(match) }) {
            await select(.window(w.id), bringForward: true)   // a pick, made on the command line
        }
    }

    // MARK: Settings (the app's menu and Settings window, and devices through .changeSettings, on both hosts)

    /// The virtual display's parts, for the CLI's flag at launch or the app's setting turning on.
    /// The private API is checked on the first call only, printing what the CLI always printed.
    /// Every call clears a run-level disable left by repeated display losses (the app's Try
    /// Again); a missing API stays a disable for the whole run.
    private func enableVirtualDisplay() {
        if !apiChecked {
            apiChecked = true
            // Decide once whether the private API is there; a picked window falls back to plain
            // window capture (with a log line) when it is not.
            let problems = VirtualDisplay.checkPrivateAPI()
            if problems.isEmpty {
                print("Virtual display: private CGVirtualDisplay API present (\(VirtualDisplay.privateAPISurface.count) selectors); a picked window streams from its own HiDPI display.")
            } else {
                apiProblem = problems.joined(separator: "; ")
                print("Virtual display unavailable: \(apiProblem!). Streaming real windows as before.")
            }
        }
        stageLosses = 0
        stage.disabledReason = apiProblem
        status.update {
            $0.virtualDisplayProblem = apiProblem
            $0.virtualDisplayAPIMissing = apiProblem != nil
        }
    }

    /// What the host is set to: a value still waiting for its restart, else the running one. What
    /// the Mac's menu checks and what devices are told. (Private: the app merges over its own
    /// settings, never over this.)
    private var target: HostConfig { pendingConfig ?? config }

    /// Who keeps the settings when a device changes one. Sill.app lays the change over its
    /// HostSettings (saved, shown in its menu and Settings) and returns the result: over the away
    /// quality (`applyingAway`) for a device away from home (`away`), else over the home one
    /// (`applying`). Unset (the CLI): the change lands on `target` the same way and lasts until the
    /// process ends. Set it before `start`.
    package var onDeviceSettingsChange: (@MainActor (HostSettingsChange, _ away: Bool) -> HostConfig)?

    /// New settings from the app or a device, applied live. Synchronous: validated, the virtual
    /// display kept off without the AppKit loop, compared with the target, told to every device.
    /// The pipeline takes them in a Task: at once when nothing streaming depends on what changed,
    /// otherwise through one restart of the current source, `select` taking them between the old
    /// pipeline and the new one. A value that arrives mid-switch waits (select's defer comes back
    /// to `applyPending`), and a newer value replaces one still waiting, so requests that arrive
    /// out of order still converge on the last. Returns whether the target moved.
    ///
    /// Why the pipeline work is scheduled rather than awaited: the device handler must answer
    /// before any await; a burst of changes that arrives before the Task runs is one restart; and
    /// `applyPending` tolerates repeated calls (it returns while switching, and a later Task finds
    /// `pendingConfig` already consumed).
    @discardableResult
    package func setTarget(_ requested: HostConfig) -> Bool {
        guard !shuttingDown else { return false }
        var new = requested.validated()
        if !appKitLoop { new.virtualDisplay = false }
        // Share clipboard with devices, at once rather than between pipelines: off must stop what goes
        // out now, not after a restart. The lists say `clipboard` again (or no longer).
        if clipboard.setEnabled(new.shareClipboard) { broadcastList() }
        guard new != target else { return false }
        pendingConfig = new
        publishSettings()
        Task { @MainActor in await self.applyPending() }   // a burst before it runs is one restart
        return true
    }

    /// Takes what waits for the pipeline: settings (`pendingConfig`), and a flip between the home and
    /// the away quality (`awayWanted` against `awayRunning`) unless it waits for a joined device's
    /// first viewport (`flipWait`), which then brings both in one restart. At once when nothing
    /// streaming depends on it, else through one restart of the current source.
    private func applyPending() async {
        let flip = awayWanted != awayRunning && flipWait == nil
        guard pendingConfig != nil || flip, !switching, !shuttingDown else { return }   // select's defer calls it again
        let new = pendingConfig ?? config
        // A flip still waiting for its viewport stays out of a settings change that needs no restart;
        // a restart takes it anyway (select's commit).
        let away = flipWait == nil ? awayWanted : awayRunning
        guard restartNeeded(for: new, away: away) else { pendingConfig = nil; adopt(new, away: away); return }
        // A restart, not a pick. Turning the virtual display off still brings the staged window
        // forward as it comes home: select's commit decides that, from the value it actually takes.
        await select(active)   // committed inside select
    }

    /// Home or away (docs/remote-bundle-plan.md §5.4): a device registered (`joined`, before its
    /// catalog) or one left (nil). The away quality becomes the target once every connected device
    /// is away, the home one once any is at home; with nobody connected the flag stays (AwayPolicy).
    /// A flip prints its line; one from a device that joined waits for that device's first viewport
    /// (`flipAwaits`), one from a device that left is the caller's to apply. Returns whether it
    /// flipped.
    @discardableResult
    private func routesChanged(joined: ObjectIdentifier?, endpoint: String?) -> Bool {
        let before = awayWanted
        awayWanted = AwayPolicy.wanted(devicesAway: routes.values.map(\.isAway), current: awayWanted)
        let flipped = awayWanted != before
        if flipped {
            print(awayWanted ? AwayPolicy.awayLine(target) : AwayPolicy.homeLine(target, endpoint: endpoint ?? "a device"))
            if let joined { flipAwaits(joined) } else { flipWait = nil }
        }
        status.update { $0.away = awayWanted && !routes.isEmpty }   // publishes (status.onChange)
        return flipped
    }

    /// The flip waits for `id`'s first viewport, which carries its rate, so the two go in one
    /// restart; after a second without one (a test client) it goes alone.
    private func flipAwaits(_ id: ObjectIdentifier) {
        flipWaitToken += 1
        let token = flipWaitToken
        flipWait = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard self.flipWaitToken == token, self.flipWait == id else { return }
            self.flipWait = nil
            await self.applyPending()
        }
    }

    /// Whether the running pipeline would come out different under `new` with the home or the away
    /// quality (`away`): its rate (the devices' highest under the new limit, 60 at most on the
    /// software encoder), capture scale and bitrate (the pair `away` picks), encoder speed, or, for a
    /// window, the virtual display. The Desktop never uses the display. Direct Wireless is
    /// deliberately absent: it is the listener's (`adopt` hands it over).
    ///
    /// A new bitrate needs a new encoder session. VideoToolbox accepts AverageBitRate on a live
    /// session and reads it back, but the hardware HEVC encoder's rate control does not follow it
    /// (measured 2026-09-25 on this M2 Pro, 1512×948 at 60 fps: raised from 8 to 40 Mbps the output
    /// stayed at 9.6 Mbps for 5 s and across a keyframe, against 28 Mbps for a session made at 40;
    /// lowered from 40 to 8 it dropped 41 of the next 60 frames). Only the software encoder and
    /// low-latency rate control follow a live change.
    private func restartNeeded(for new: HostConfig, away: Bool) -> Bool {
        guard active != .none else { return false }
        let wanted = min(new.maxFPS, max(24, clientFPS.values.max() ?? 60))
        let newFPS = useSoftwareEncoder ? min(wanted, 60) : wanted
        let pair = new.effective(away: away)
        let newScale = useSoftwareEncoder ? min(pair.captureScale, 1.0) : pair.captureScale
        if newFPS != fps || newScale != captureScale { return true }
        if pair.bitrate != bitrate || new.prioritizeSpeed != config.prioritizeSpeed { return true }
        if new.virtualDisplay != config.virtualDisplay, case .window = active { return true }
        return false
    }

    /// Makes `next` the running settings, and `away` the quality the pipeline runs, inside `select`
    /// or at once when nothing running depends on what changed. Logs one "Settings:" line when the
    /// settings changed; a flip alone prints nothing here (`routesChanged` said it).
    private func adopt(_ next: HostConfig, away: Bool) {
        awayRunning = away
        let old = config
        guard next != old else { return }
        config = next
        // The listener's, not the pipeline's: StreamServer replaces it and connected devices keep streaming.
        if old.directWireless != next.directWireless { server.setPeerToPeer(next.directWireless) }
        // The doors', not the pipeline's: RemoteAccess starts, stops or moves the remote door, and
        // Require pairing changes who the home door admits (and its TXT record).
        if old.remoteAccess != next.remoteAccess || old.remotePort != next.remotePort || old.internetAccess != next.internetAccess
            || old.requirePairing != next.requirePairing {
            remote?.apply(next)
        }
        catalog.preferMainDisplay = next.virtualDisplay   // the Desktop source must never capture the virtual display
        if old.virtualDisplay && !next.virtualDisplay {
            stage.release()        // idempotent: select has already sent a staged window home
            status.update { $0.lastStageFailure = nil }
        }
        if !old.virtualDisplay && next.virtualDisplay { enableVirtualDisplay() }
        status.update { $0.virtualDisplayOn = next.virtualDisplay }
        print("Settings: " + old.changes(to: next))
    }

    /// Settings › Virtual Display › Try Again: clear a run-level disable, and stage the streamed
    /// window again.
    package func retryVirtualDisplay() async {
        enableVirtualDisplay()
        if virtualDisplay, case .window = active { await select(active) }
    }

    /// The app keeps running when the Bonjour listener fails, with the failure in its menu; the
    /// CLI exits as it always has. Call before `start`.
    package func keepRunningOnListenerFailure() {
        server.onListenerFailed = { [weak self] error in
            Task { @MainActor in self?.status.update { $0.network = .failed("\(error)") } }
        }
    }

    /// Windows in the catalog's last look, for the CLI's startup line.
    package var windowCount: Int { catalog.infos.count }

    /// A window is staged on the virtual display and in a full-screen Space there. The app's Quit
    /// takes it out of full screen first (`beginLeavingFullScreenForQuit`), or it cannot go home.
    package var stagedWindowIsFullScreen: Bool {
        guard let p = stage.placement else { return false }
        return WindowSizer.isFullScreen(p.element)
    }

    /// Presses the staged window's full-screen button; the app's Quit then waits for
    /// `stagedWindowSettled`.
    package func beginLeavingFullScreenForQuit() {
        guard let p = stage.placement else { return }
        _ = WindowSizer.perform(.fullScreen, element: p.element)
    }

    /// The staged window (if any) is out of full screen and back on a window list, so it can be
    /// put back where it was. Leaving full screen, a window is off every list for about a second;
    /// the same test as `VirtualStage.leaveFullScreenIfNeeded`.
    package var stagedWindowSettled: Bool {
        guard let p = stage.placement else { return true }
        return !WindowSizer.isFullScreen(p.element) && WindowSizer.liveBounds(of: p.windowID) != nil
    }

    /// Whether `id` is a Sill virtual display, which the app keeps its own windows off.
    package static func isSillVirtualDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == VirtualStage.vendorID
    }

    // MARK: Each device's link (docs/remote-bundle-plan.md §6)

    /// The stream's quality as `select` commits it (nil: nothing streams). The devices' links are
    /// judged afresh when it changes (LinkJudge.judgedAfresh: another bitrate, rate or resolution, or
    /// no stream), and keep their judgement through a restart that keeps it, so a device's report,
    /// line and callout neither go nor come back for a window picked or a rotation.
    private func judgeLinks(_ quality: LinkJudge.Quality?) {
        if LinkJudge.judgedAfresh(from: judgedQuality, to: quality) { server.resetLinks() }
        judgedQuality = quality
    }

    /// A device's link changed: behind or stalled becomes its report (the running quality, what was
    /// withheld, the carried rate and what would fit at the running pair and the stream's rate), a
    /// line when the state is new, and the card's row; a report that only moves the carried rate
    /// prints nothing, and changes nothing unless it changes the suggestion; fine clears it, with
    /// "keeping up again" only for a judged recovery, never for a restart's reset. The snapshot
    /// change publishes, and each connection's state carries its own.
    private func linkChanged(_ id: ObjectIdentifier, _ v: LinkJudge.Verdict) {
        guard routes[id] != nil else { return }       // gone meanwhile
        let device = status.snapshot.devices.first { $0.id == id }
        let who = device?.name ?? device?.endpoint ?? "a device"
        switch v.state {
        case .fine:
            let had = linkReports.removeValue(forKey: id) != nil
            status.update {
                guard let i = $0.devices.firstIndex(where: { $0.id == id }) else { return }
                $0.devices[i].link = nil
            }
            if had, !v.reset { print(LinkJudge.fineLine(device: who)) }
        case .behind, .stalled:
            let behind = v.state == .behind
            let fps = status.snapshot.stream?.fps ?? self.fps
            let suggestion = LinkJudge.suggestion(carriedKbps: v.carriedKbps, bitrate: bitrate, fps: fps, captureScale: Double(captureScale))
            let report = LinkReport(state: behind ? LinkReport.behind : LinkReport.stalled, withheldPerSecond: v.withheld,
                                    bitrate: bitrate, carriedKbps: v.carriedKbps,
                                    suggestedBitrate: suggestion?.bitrate, suggestedCaptureScale: suggestion?.captureScale)
            let previous = linkReports[id]
            // The same state with the same suggestion (the judge reporting its rate as it moves): the
            // device and the card have nothing new to show, so nothing is published.
            if let previous, previous.state == report.state, previous.suggestedBitrate == report.suggestedBitrate,
               previous.suggestedCaptureScale == report.suggestedCaptureScale { return }
            linkReports[id] = report
            let shown = HostStatusSnapshot.LinkStatus(state: behind ? .behind : .stalled, withheld: v.withheld, bitrate: bitrate,
                                                      carriedKbps: v.carriedKbps, suggestedBitrate: suggestion?.bitrate,
                                                      suggestedCaptureScale: suggestion?.captureScale)
            status.update {
                guard let i = $0.devices.firstIndex(where: { $0.id == id }) else { return }
                $0.devices[i].link = shown
            }
            guard previous?.state != report.state else { return }
            print(behind ? LinkJudge.behindLine(device: who, bitrate: bitrate, withheld: v.withheld, offered: v.offered,
                                                carriedKbps: v.carriedKbps, suggestion: suggestion)
                         : LinkJudge.stalledLine(device: who, waiting: v.waiting))
        }
    }

    // MARK: Client messages

    private func handle(_ message: StreamMessage, from connection: NWConnection) async {
        switch message.kind {
        case .selectSource:
            guard let source = Wire.decode(StreamSource.self, from: message.payload) else { return }
            // A window picked comes forward on the Mac, which closes a view a gesture opened; the
            // Desktop picked (as a device does before a gesture made over a window) leaves it.
            if case .window = source { gestureChords.forget() }
            // A pick from the device's switcher: the device never selects a window by itself (its
            // automatic requests are for the Desktop only).
            await handlePick(source)
        case .windowCommand:
            // The bar's long-press menu: the window's own traffic lights, pressed through
            // Accessibility. The staged window's element is already matched; others are looked up.
            guard let cmd = Wire.decode(WindowCommand.self, from: message.payload) else { return }
            gestureChords.forget()              // a window's own button: a view a gesture opened is left behind
            let done: Bool
            if virtualDisplay, let p = stage.placement, p.windowID == cmd.id {
                done = WindowSizer.perform(cmd.action, element: p.element)
            } else if let w = catalog.window(id: cmd.id) {
                done = sizer.perform(cmd.action, on: w)
            } else {
                done = false
            }
            print("Window \(cmd.id) \(cmd.action.rawValue): \(done ? "done" : "refused")")
            Stats.shared.bump("win.\(cmd.action.rawValue)")
            await catalog.refreshWindows()      // show the result now, not at the next poll
        case .launchApp:
            guard let req = Wire.decode(LaunchApp.self, from: message.payload),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: req.bundleID) else { return }
            gestureChords.forget()              // the app comes forward, which closes a view a gesture opened
            pendingLaunch = req.bundleID
            let config = NSWorkspace.OpenConfiguration()
            // The launch itself takes no focus on the Mac. Its first window is then picked for the
            // device (`windowsChanged`), which in regular mode brings it forward like any pick.
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error { print("Launch failed: \(error.localizedDescription)") }
            }
        case .input:
            guard let event = Wire.decode(InputEvent.self, from: message.payload) else { return }
            let device = ObjectIdentifier(connection)
            guard let rect = currentSourceRect() else {
                // Nothing streams (between sources, or the stream stopped: the window closed under a
                // drag): input has nowhere to land. The up of a key or a button the Mac has down still
                // goes (DroppedInput), a button's where the pointer is (`.null`), so no modifier this
                // device pressed stays down to make a later click a ⌘-click, and no button to make
                // every later move a drag.
                if injector.isUpOfSomethingDown(event) { deliver(event, in: .null, from: device) }
                return
            }
            // A click, a key or text may close a view a gesture opened; a move or a scroll does not.
            gestureChords.input(Self.gestureInput(event))
            // A synthetic host acts on nothing: it posts no event (InputInjector.dryRun), so it
            // activates and raises nothing either.
            if !synthetic { raiseIfInteracting(event) }
            deliver(event, in: rect, from: device)
            desktopInputMayActivate(event)
        case .gesture:
            // A three- or four-finger gesture (docs/trackpad-gestures-plan.md §7.4), which the Mac
            // turns into its own shortcut. At most `gesturesPerSecond` a second per connection: a
            // stroke makes one, so more is a runaway or hostile client.
            guard let gesture = Wire.decode(TrackpadGesture.self, from: message.payload) else { return }
            let id = ObjectIdentifier(connection)
            let now = CFAbsoluteTimeGetCurrent()
            var recent = (gestureArrivals[id] ?? []).filter { now - $0 < 1 }
            guard recent.count < Self.gesturesPerSecond else {
                gestureArrivals[id] = recent
                gestureDrops.count("gestures")
                return
            }
            recent.append(now)
            gestureArrivals[id] = recent
            queueGesture(gesture, from: deviceName(connection))
        case .viewport:
            guard let v = Wire.decode(Viewport.self, from: message.payload) else { return }
            viewport = v
            let id = ObjectIdentifier(connection)
            clientFPS[id] = v.fps ?? 60
            // The flip its connection made waited for this, its rate (`flipAwaits`): the restart the
            // rate needs takes the flip too, and the flip alone restarts once when the rate needs none.
            let flipWaited = flipWait == id
            if flipWaited { flipWait = nil }
            if switching { viewportArrivedWhileSwitching = true; return }   // select's defer applies both
            await applyViewportToActiveWindow()
            if flipWaited { await applyPending() }
        case .pairingWanted:
            // "Show your pairing code" (Pair This iPad…): only from a device near the Mac (the home
            // door, from loopback, this network or peer-to-peer Wi-Fi), once per 30 s per connection.
            // At a TLS home door only from an unpaired session (Require pairing off), which goes
            // through the ask rule; a paired session's is ignored.
            let id = ObjectIdentifier(connection)
            guard let remote, case .home(let origin, let peer)? = routes[id], [.loopback, .lan, .direct].contains(origin) else { return }
            if server.homeTLS, peer.map({ remote.isPaired($0.fingerprint) }) ?? true { return }
            let now = CFAbsoluteTimeGetCurrent()
            if let last = lastPairingWanted[id], now - last < 30 { return }
            lastPairingWanted[id] = now
            var session: (fingerprint: Data, source: String, display: String, from: String, fromThisMac: Bool)?
            if server.homeTLS, let peer, let s = Door.source(of: connection) {
                let thisMac = DoorPolicy.isFromThisMac(source: s.bytes, ownAddresses: InterfaceSnapshot.ownAddresses())
                let source: String
                if case .hostPort(let host, _) = connection.endpoint { source = StreamServer.addressText(host).text } else { source = s.display }
                session = (peer.fingerprint, source, s.display,
                           origin == .direct ? "nearby" : (thisMac || origin == .loopback ? "on this Mac" : "on this network"), thisMac)
            }
            remote.pairingWanted(by: deviceName(connection), session: session)
        case .changeSettings:
            // A device's settings control. No `await` in this case: the answer leaves in request
            // order, per device and across devices, and before any restart (setTarget schedules the
            // pipeline work). Malformed JSON has no token to answer, so it gets nothing.
            guard let change = Wire.decode(HostSettingsChange.self, from: message.payload) else { return }
            let who = deviceName(connection)
            // At most `settingsPerSecond` changes a second per connection: a panel's control sends
            // one per tap, so more is a runaway or hostile client, and each could cost a restart.
            // The excess applies nothing and is answered with the state as it stands, so the
            // device's ledger still hears back.
            let id = ObjectIdentifier(connection)
            let now = CFAbsoluteTimeGetCurrent()
            var recent = (settingsArrivals[id] ?? []).filter { now - $0 < 1 }
            if recent.count >= Self.settingsPerSecond {
                settingsArrivals[id] = recent
                if now - (settingsIgnoredLineAt[id] ?? 0) >= 1 {
                    settingsIgnoredLineAt[id] = now
                    print("Settings from \(who) ignored: more than \(Self.settingsPerSecond) changes a second.")
                }
                server.send(settingsMessage(settingsState(for: id, answering: change.token)), to: connection)
                return
            }
            recent.append(now)
            settingsArrivals[id] = recent
            // A connection whose route is not known (never: it is set before any message is
            // handled) counts as remote, so nothing it sends can widen exposure.
            let (ok, refused) = DeviceSettings.accepted(change, virtualDisplayAvailable: appKitLoop,
                                                        fromRemote: routes[id].map { $0.isRemote } ?? true)
            if !refused.isEmpty { print("Settings from \(who) refused: \(refused.joined(separator: ", "))") }
            if !ok.isEmpty, !shuttingDown {
                let before = target
                // A device away from home sets the away quality, never the home one (§5.1).
                let away = routes[id]?.isAway ?? false
                // The app: the hook assigns its settings, whose didSet has already set the target
                // (this call then finds it equal). The CLI: the change lands on the target.
                setTarget(onDeviceSettingsChange?(ok, away) ?? (away ? before.applyingAway(ok) : before.applying(ok)))
                if target != before { print("Settings from \(who): " + before.changes(to: target)) }
            }
            // Exactly one answer, to this device alone: the settings as they now stand, so a
            // refused or ignored field goes back to the Mac's value on the device.
            server.send(settingsMessage(settingsState(for: id, answering: change.token)), to: connection)
        case .fetchMenu:
            // The Mac's menus (MenuMirror): no `await` here either; the mirror schedules its reads
            // and answers this device alone. JSON that does not decode has no token to answer.
            guard let r = Wire.decode(FetchMenu.self, from: message.payload) else { return }
            menus.fetch(r, from: connection, who: deviceName(connection))
        case .clipboard:
            // The clipboard (HostClipboard): a subscription, a device's text, or its stop. No `await`:
            // it reads and writes the pasteboard at once, and says nothing per copy.
            clipboard.received(message.payload, from: connection, who: deviceName(connection))
        case .pressMenuItem:
            guard let r = Wire.decode(PressMenuItem.self, from: message.payload) else { return }
            // One of the Mac's menu items chosen from a device acts as a click on it would, and may
            // bring a window forward: a view a gesture opened is left behind, as after a click.
            gestureChords.forget()
            menus.press(r, from: connection, who: deviceName(connection))
        default:
            break
        }
    }

    // MARK: Where input lands

    /// The active source's rectangle on screen, in CG global points (top-left origin), which is
    /// what the injector maps the client's fractions onto. Nil when nothing is streaming, so
    /// input that arrives between sources is dropped rather than poked at the wrong window.
    private func currentSourceRect() -> CGRect? {
        switch active {
        case .none:
            return nil
        case .desktop:
            // The test pattern with the TEST ONLY scripted pointer: its own space, where a test
            // client's input moves that pointer (a synthetic host posts nothing).
            if synthetic, pointer.hasTestPointer { return Self.testPatternRect }
            return catalog.display?.frame
        case .window(let id):
            // On the virtual display the video is the captured crop, not the whole window: an app
            // that took a larger size than asked overhangs the display and the overhang is not shown.
            if virtualDisplay, stage.isStaged, let onScreen = stage.captureRectOnScreen { return onScreen }
            // The catalog only refreshes every 2 s, so ask the window server for live bounds —
            // but cache them briefly, or a 120 Hz Pencil drag hits it on every single event.
            let now = CFAbsoluteTimeGetCurrent()
            if let cached = rectCache, cached.id == id, now - cached.at < 0.1 { return cached.rect }
            guard let rect = Self.liveBounds(of: id) ?? catalog.window(id: id)?.frame else { return nil }
            rectCache = (id, rect, now)
            return rect
        }
    }

    private static func liveBounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    // MARK: The Mac cursor
    //
    // The video never carries the Mac cursor. The client draws the pointer where its trackpad or
    // Pencil says it is (no round trip), and `cursorShapes` streams the Mac's current cursor image
    // so that pointer takes the right shape. Toggling `showsCursor` on a running SCStream with
    // `updateConfiguration` wedged the capture on macOS 27, so it is fixed at start.
    //
    // While the Mac (its own mouse or trackpad), or another device, moves the pointer, the devices
    // draw it from where the host says it is (kind 26: `pointer`, StreamServer), in the same shape.

    /// What the Mac's pointer is judged against (docs/pointer-visibility-plan.md §4.7): the streamed
    /// source's rectangle in global points, the injector's own (`currentSourceRect`). The Desktop:
    /// its display. A window on the virtual display: the crop, or the full-screen band. A window in
    /// regular mode: its live bounds, which the watch re-reads, and it must be on screen. A
    /// synthetic host has one only for the test pattern under the TEST ONLY scripted pointer, so it
    /// never reads the real pointer (a real window picked there included).
    private func pointerGeometry() -> PointerWatch.Geometry? {
        switch active {
        case .none:
            return nil
        case .desktop:
            if synthetic { return pointer.hasTestPointer ? .rect(Self.testPatternRect) : nil }
            return catalog.display.map { .rect($0.frame) }
        case .window(let id):
            guard !synthetic else { return nil }
            if virtualDisplay, stage.isStaged, let onScreen = stage.captureRectOnScreen { return .rect(onScreen) }
            return currentSourceRect().map { .window(id, $0) }
        }
    }

    // MARK: Fitting the window to the client

    /// Resizes the streamed window to the client's panel at its text scale, if one is set and the
    /// window is not already there. Returns the size the window actually took, or nil if nothing
    /// changed. Mac points throughout: the panel in device points divided by the scale (device
    /// points per Mac point). Scale nil means leave the window alone, and so is a window in full
    /// screen (WindowRestore.fit). Every resize the app took, or left unanswered (a busy app may take
    /// it later), is a fit for `fits`: the window goes back to its own frame when it stops streaming
    /// (`restoreFits`, issue #57). None once the host is shutting down: nothing would put it back.
    private func fitToViewport(_ window: SCWindow) -> CGSize? {
        guard !shuttingDown, let v = viewport, let textScale = v.scale, textScale > 0, v.width > 0, v.height > 0 else { return nil }
        let target = CGSize(width: (v.width / textScale).rounded(), height: (v.height / textScale).rounded())
        let current = Self.liveBounds(of: window.windowID)?.size ?? window.frame.size
        if abs(current.width - target.width) <= 2, abs(current.height - target.height) <= 2 { return nil }
        guard let fit = sizer.resize(window: window, to: target) else { return nil }
        fits.fitted(window.windowID, handle: fit.placement, before: fit.before, after: fit.after, asked: target)
        let actual = fit.after.size
        // Asked again for a size the app already refused (its minimum): nothing moved.
        guard abs(actual.width - current.width) >= 1 || abs(actual.height - current.height) >= 1 else { return nil }
        Stats.shared.bump("win.resized")
        print("Resized \(window.owningApplication?.applicationName ?? "?") to \(Int(actual.width))×\(Int(actual.height)) pt "
              + "(asked \(Int(target.width))×\(Int(target.height)) for a \(Int(v.width))×\(Int(v.height)) panel at \(textScale)×)")
        return actual
    }

    /// A new viewport while a window streams. The encoder is fixed to the old size, but the
    /// catalog's resize check (`windowsChanged`) already restarts the pipeline when the window's
    /// size changes; refreshing now just saves waiting up to two seconds for its next poll.
    /// The desktop and nothing-streaming ignore viewports.
    private func applyViewportToActiveWindow() async {
        // A different rate (a ProMotion device joined, Low Power Mode toggled) needs a new capture
        // interval and encoder session: one restart, whatever the source.
        if active != .none, effectiveFPS != fps { await select(active); return }
        if virtualDisplay, stage.isStaged, case .window(let id) = active {
            // One restart: prepare re-places the window on the same display (the display is only
            // recreated if the envelope grew). The client's identical re-send after a switch is a
            // no-op through the 2 pt compare.
            var found = catalog.window(id: id)
            if found == nil { found = await catalog.resolveWindow(id: id) }
            // The lookup may have suspended for up to 3 s with `switching` clear, so another
            // select can have run to completion meanwhile: only restart if `id` is still active.
            guard let w = found, case .window(let now) = active, now == id else { return }
            let want = wantedStage(for: w)
            if stage.matches(windowID: id, size: want.size) { return }
            await select(.window(id))
            return
        }
        guard case .window(let id) = active, let w = catalog.window(id: id) else { return }
        if fitToViewport(w) != nil { await catalog.refreshWindows() }
    }

    /// `--virtual-display`: how big the window should be on the virtual display and how big the
    /// display must be, from the last viewport (or the window's own size before any arrived).
    private func wantedStage(for w: SCWindow) -> (size: CGSize, envelope: CGSize) {
        let own = Self.liveBounds(of: w.windowID)?.size ?? w.frame.size
        let size = VirtualStage.windowSize(for: viewport, own: own)
        // The envelope also covers the window's current size: an app's minimum is never larger
        // than what it shows now, so the "insists on a larger size, grow the display" recreate
        // (seen twice per rotation for Chrome and Claude) does not happen.
        var env = VirtualStage.envelope(for: viewport, windowSize: size)
        // Not while the window is full screen: its frame is the whole display, and growing the
        // envelope to it would recreate the display under the full-screen Space.
        if !(stage.isStaged && stage.windowStillFullScreen) {
            env = CGSize(width: max(env.width, own.width), height: max(env.height, own.height))
        }
        return (size, env)
    }

    // MARK: Source switching

    /// A pick from a device's switcher, and one that waited out a restart (select's defer): one
    /// rule for both, so a queued pick is not lost to a select that starts before its Task runs.
    /// While the active source restarts (a settings change, a resize, a rate change, the encoder
    /// fallback, a lost display), the pick waits for it and runs once it is done: the newest
    /// wins, and a pick of the source being restarted needs nothing. During a switch to another
    /// source it is dropped, as before this rule existed: the device's automatic Desktop request
    /// can land then and must not override the user's pick.
    ///
    /// The host cannot tell that request from a Desktop tap. The device holds it back when the
    /// user has picked since the watched window closed (StreamClient's window list); an older
    /// device, or a pick made before the device heard of the close, can still let it land during
    /// a restart that follows the user's pick, and then it is queued like the user's own.
    private func handlePick(_ source: StreamSource) async {
        if switching {
            if let r = restartOf, source != r { pickArrivedWhileSwitching = source }
            return
        }
        await select(source, bringForward: true)
    }

    /// Streams `source` in place of whatever streams now. Also how the host restarts the current
    /// source (a resize, a rate change, the encoder fallback, a lost virtual display).
    /// `bringForward` marks a pick instead: the device's switcher, the command line, an app
    /// launched from the device. In regular mode a picked window comes forward on the Mac, and a
    /// pick that falls back from the virtual display to the real window counts as regular mode;
    /// restarts leave Mac focus where it is, and so does staging a window on the virtual display.
    /// One exception: a staged window that comes home because the virtual display was turned off
    /// comes forward too, whichever select commits that change (see `cameHome`).
    func select(_ source: StreamSource, bringForward: Bool = false) async {
        guard !switching, !shuttingDown else { return }
        switching = true
        if source != active { missingPolls = 0 }    // a window's looks off the list are its own
        restartOf = (source == active && source != .none) ? source : nil
        defer {
            switching = false
            restartOf = nil
            var pick = pickArrivedWhileSwitching
            pickArrivedWhileSwitching = nil
            // Requests that arrived mid-switch, applied now that `switching` is clear again (every
            // return path, including the early ones). A last client leaving wins over a viewport
            // and over a queued pick: there is nobody left to fit the window to or stream to.
            if deselectWhenSettled {
                deselectWhenSettled = false
                if catalog.clientCount == 0, active != .none {
                    viewportArrivedWhileSwitching = false
                    Task { @MainActor in await self.select(.none) }
                }
            }
            if catalog.clientCount == 0 { pick = nil }
            if let pick, pick != active {
                // The pick's own select fits the latest viewport. Run after it has started, the
                // viewport tail would resize the old window, which `active` still names mid-switch.
                viewportArrivedWhileSwitching = false
                // Through the handler's rule again, not straight to `select`: another restart can
                // start before this Task runs (a viewport's new rate, an encoder hang, a lost
                // display), and `select` would drop the pick; the rule queues it behind that one.
                Task { @MainActor in await self.handlePick(pick) }
            } else if viewportArrivedWhileSwitching {
                viewportArrivedWhileSwitching = false
                Task { @MainActor in await self.applyViewportToActiveWindow() }
            }
            // Settings, or a flip between the home and the away quality, that came in meanwhile; a
            // no-op when the pick's select commits them first.
            if pendingConfig != nil || (awayWanted != awayRunning && flipWait == nil) { Task { @MainActor in await self.applyPending() } }
            // A stream that did not start (its window gone, capture refused): nothing streams, so
            // the links have nothing to be judged at, and a window sized for it goes back.
            if active == .none { judgeLinks(nil); restoreFits(keeping: nil) }
        }

        await capture.stop()
        await syntheticCapture.stop()
        capture.onFrame = nil; syntheticCapture.onFrame = nil   // both queues drained: let the old encoder go
        rectCache = nil
        // Input held for the old source must not replay into the new one, but what acts on the whole
        // Mac still goes, in order: a gesture's chord held behind it, and the up of a key or a button
        // the Mac has down (DroppedInput: a modifier left down makes the next click a ⌘-click, a
        // button every move a drag), a button's where the pointer is (`.null`), not where the old
        // source would have put it. The keys of devices that left meanwhile go up after them.
        let dropped = heldInput
        heldInput = []; holdUntil = 0
        for item in dropped {
            switch item {
            case .input(let event, _, let device):
                if injector.isUpOfSomethingDown(event) { injector.apply(event, in: .null, from: device) }
            case .chord(let keyCode, let flags):
                injector.chord(keyCode: keyCode, flags: flags)
            }
        }
        releaseKeysOfDevicesThatLeft()
        encoder = nil                  // deinit invalidates the VT session
        server.resetForNewStream()          // every client waits for the next parameter sets + keyframe
        // New settings take effect here, between pipelines, before the rate, the scale and the
        // stage are worked out for the next one.
        var leftStage = false
        // The virtual display turned off (from the Mac or a device) sends a staged window home, and
        // it comes forward the way a pick does in regular mode (Q3). Decided here, from the value
        // this commit takes, not by the caller: any select can take that change, a restart
        // included (a newer value replaces the one that started it during the awaits above), and
        // a restart raises nothing on its own.
        var cameHome = false
        if let first = pendingConfig {
            if config.virtualDisplay && !first.virtualDisplay {
                // The virtual display block below is skipped once the flag reads off: send the
                // window home now, and re-read the catalog so the .window lookup below gets its
                // home frame, not the staged one.
                cameHome = stage.isStaged
                await stage.leaveFullScreenIfNeeded(); stage.release()
                if case .window = source { await catalog.refreshWindows() }
                leftStage = true
            }
            // The newest value: another may have arrived during those awaits.
            let next = pendingConfig ?? first
            pendingConfig = nil
            adopt(next, away: awayWanted)
        } else if awayWanted != awayRunning {
            // Home or away changed (a device joined or left): the pipeline takes the other pair.
            adopt(config, away: awayWanted)
        }
        fps = effectiveFPS             // the devices' panel rate (highest), or 60 before any has said
        // The devices' links: judged afresh when the stream comes back at another quality or not at
        // all, kept through a restart that keeps it (a window picked, a rotation, a resize).
        judgeLinks(source == .none ? nil : LinkJudge.Quality(bitrate: bitrate, fps: fps, captureScale: Double(captureScale)))
        let comeForward = bringForward || cameHome

        if virtualDisplay {
            // The stage follows the selection. A different window sends the staged one home first
            // and keeps the display for the newcomer; the same window keeps its place (prepare then
            // skips the move); none or desktop puts the window back and removes the display.
            if case .window(let id) = source {
                if let staged = stage.placement, staged.windowID != id {
                    await stage.leaveFullScreenIfNeeded()
                    stage.releaseWindow()
                }
            } else {
                await stage.leaveFullScreenIfNeeded()
                stage.release()
            }
        }
        // In regular mode, every window Sill sized but the one about to stream goes back to its own
        // frame (WindowRestore, issue #57): another window or the Desktop picked, `.none` when the
        // last device leaves or the stream stops. A restart of the same window keeps it fitted.
        if case .window(let next) = source { restoreFits(keeping: next) } else { restoreFits(keeping: nil) }

        var filter: SCContentFilter?     // nil only for the synthetic test pattern
        var sourceRect: CGRect? = nil    // set only when the window streams from the virtual display
        var picked: SCWindow?            // the resolved window, for the fallback after a failed start
        let width: Int, height: Int
        var describe = ""
        var title = ""                   // for the app's menu: "Safari — Apple Developer", "Whole Desktop"
        var kind = HostStatusSnapshot.Stream.Kind.window
        switch source {
        case .none:
            active = .none
            broadcastList()
            return
        case .window(let id):
            // On the virtual display the window may have left the on-screen list; look it up fully.
            var found = catalog.window(id: id)
            if found == nil, virtualDisplay || leftStage { found = await catalog.resolveWindow(id: id) }
            guard let w = found else {
                if virtualDisplay { stage.release() }
                active = .none; broadcastList(); return
            }
            print("Selecting window \(w.windowID) \(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "") frame \(w.frame) onScreen \(w.isOnScreen) active \(w.isActive)")
            picked = w
            listedFullScreen = WindowRestore.coversDisplay(w.frame, WindowSizer.displayFrames()) ? id : nil
            title = Self.menuTitle(for: w)
            var size = w.frame.size
            if virtualDisplay, stage.disabledReason == nil {
                let want = wantedStage(for: w)
                // A window Sill sized in regular mode (the virtual display turned on while it
                // streamed): the stage keeps the frame it would have gone back to as its way home.
                let home = stageHome(for: id)
                do {
                    let prepared = try await stage.prepare(window: w, wanted: want.size, envelope: want.envelope, captureScale: captureScale,
                                                           refreshHz: fps, home: home)
                    _ = fits.take(id)     // the stage puts it back from now on; a staging that failed keeps the record
                    guard !shuttingDown else { stage.release(); active = .none; broadcastList(); return }
                    filter = prepared.filter
                    sourceRect = prepared.sourceRect
                    size = prepared.outputSize ?? prepared.sourceRect.size
                    describe = prepared.describe + (useSoftwareEncoder ? " (software encoder)" : "")
                    status.update { $0.lastStageFailure = nil }
                } catch {
                    print("Virtual display fallback for \(w.owningApplication?.applicationName ?? "?"): \(error). Streaming the real window instead.")
                    Stats.shared.bump("vd.fallback")
                    stage.release()
                    // For the menu: why this window streams in place, and whether the stage gave up
                    // for the run (it does after repeated display creation failures).
                    let why = (error as? VirtualStage.Failure)?.summary ?? "\(error)"
                    status.update {
                        $0.lastStageFailure = why
                        if let off = stage.disabledReason { $0.virtualDisplayProblem = off }
                    }
                }
            }
            if sourceRect == nil {
                // Today's path: capture the window where it is.
                filter = SCContentFilter(desktopIndependentWindow: w)
                // Regular mode raises the picked window (2026-09-23, Noah: the Mac must show the
                // picked window). A covered window stops repainting, so it would stream frozen, and
                // keys go to the active app's key window. Done before capture starts, so the first
                // frames already show it uncovered. The virtual display's fallback lands here too.
                if comeForward, !shuttingDown { activateAndRaise(window: w) }
                // Fit the window to the client's panel before capture starts, so the stream comes up
                // at the new size instead of restarting once the catalog notices. `w` is a snapshot
                // with the old frame; the window server has the new one.
                if let resized = fitToViewport(w) { size = Self.liveBounds(of: id)?.size ?? resized }
                describe = "\(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "")\(useSoftwareEncoder ? " (software encoder)" : "")"
            }
            width = evenPixels(size.width * captureScale); height = evenPixels(size.height * captureScale)
            // Staged on the virtual display, nothing is activated or raised on select: the window
            // cannot be covered there, and the AX moves that put it there touch no focus.
        case .desktop:
            if synthetic {
                // A 1512×949-point test pattern: the same size as a typical streamed window, so the
                // encoder and the fallback see realistic load without Screen Recording.
                width = evenPixels(1512 * captureScale); height = evenPixels(949 * captureScale)
                describe = "a synthetic test pattern\(useSoftwareEncoder ? " (software encoder)" : "")"
                title = "Test Pattern"; kind = .testPattern
            } else {
                guard let d = catalog.display else { active = .none; broadcastList(); return }
                // Sill's own windows (Settings, Log, the pairing window with its code) never go out
                // in a Desktop stream. Fixed here at pipeline start: a running SCStream is never
                // reconfigured, so a host that can show a pairing code (remote access) looks for
                // Sill among every window when the last on-screen look missed it; excluding nothing
                // would let a pairing window opened later reach the devices. Without Sill anywhere
                // (the CLI has no windows), as before.
                var own = catalog.ownApplication
                if own == nil, remote != nil {
                    own = await catalog.resolveOwnApplication()
                    guard !shuttingDown else { active = .none; broadcastList(); return }
                }
                if let own {
                    filter = SCContentFilter(display: d, excludingApplications: [own], exceptingWindows: [])
                } else {
                    filter = SCContentFilter(display: d, excludingWindows: [])
                }
                width = evenPixels(CGFloat(d.width) * captureScale); height = evenPixels(CGFloat(d.height) * captureScale)
                describe = "the whole desktop\(useSoftwareEncoder ? " (software encoder)" : "")"
                title = "Whole Desktop"; kind = .desktop
            }
        }

        do {
            try await startPipeline(source: source, filter: filter, sourceRect: sourceRect, width: width, height: height, describe: describe,
                                    title: title, kind: kind)
        } catch {
            // `picked`, not a catalog lookup: a staged window may have left the on-screen list.
            if virtualDisplay, stage.isStaged, let w = picked {
                // The display filter failed to start: send the window home and stream it there.
                print("Capture on the virtual display failed: \(error); retrying with the real window.")
                status.update { $0.lastStageFailure = "capture on the display failed" }
                stage.release()
                if comeForward, !shuttingDown { activateAndRaise(window: w) }   // regular mode now: a pick comes forward
                let fallback = "\(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "")\(useSoftwareEncoder ? " (software encoder)" : "")"
                do {
                    try await startPipeline(source: source, filter: SCContentFilter(desktopIndependentWindow: w), sourceRect: nil,
                                            width: evenPixels(w.frame.width * captureScale), height: evenPixels(w.frame.height * captureScale),
                                            describe: fallback, title: title, kind: kind)
                } catch {
                    print("Could not start streaming \(fallback): \(error)")
                    active = .none
                }
            } else {
                print("Could not start streaming \(describe): \(error)")
                if virtualDisplay { stage.release() }   // nothing streams: never leave a window on the virtual display
                active = .none
            }
        }
        broadcastList()
        // Mid-switch requests (a viewport, the last client leaving) are applied by the defer.
    }

    /// Encoder, then capture (ScreenCaptureKit for a filter, the test pattern without one), then
    /// `active`. Throws with `active` untouched if either refuses; the caller decides what to do.
    /// `title` and `kind` describe the stream in the app's menu.
    private func startPipeline(source: StreamSource, filter: SCContentFilter?, sourceRect: CGRect?, width: Int, height: Int, describe: String,
                               title: String, kind: HostStatusSnapshot.Stream.Kind) async throws {
        let enc = try HEVCEncoder(width: width, height: height, fps: fps, bitrate: streamBitrate, prioritizeSpeed: prioritizeSpeed,
                                  software: useSoftwareEncoder)
        enc.onHung = { [weak self, weak enc] in
            Task { @MainActor in
                guard let enc else { return }
                await self?.encoderHung(enc)
            }
        }
        let server = self.server
        enc.onEncoded = { data, isKey, parameterSets in
            let now = Date().timeIntervalSince1970
            if let ps = parameterSets {
                server.broadcast(StreamMessage(kind: .parameterSets, timestamp: now, isKeyframe: true, payload: ps.encoded()))
            }
            server.broadcast(StreamMessage(kind: .frame, timestamp: now, isKeyframe: isKey, payload: data))
        }
        if let filter {
            capture.onFrame = { pixelBuffer, pts in enc.encode(pixelBuffer, pts: pts) }
            try await capture.start(filter: filter, width: width, height: height, fps: fps, showsCursor: false, sourceRect: sourceRect)
        } else {
            syntheticCapture.onFrame = { pixelBuffer, pts in enc.encode(pixelBuffer, pts: pts) }
            syntheticCapture.start(width: width, height: height, fps: fps)
        }
        encoder = enc
        active = source
        print("Streaming \(describe) at \(width)×\(height), \(fps) fps, \(streamBitrate / 1_000_000) Mbps")
        status.update {
            $0.stream = HostStatusSnapshot.Stream(kind: kind, title: title, width: width, height: height, fps: fps,
                                                  mbps: streamBitrate / 1_000_000, onVirtualDisplay: sourceRect != nil,
                                                  softwareEncoder: useSoftwareEncoder)
        }
        // Frames can reach the encoder while `capture.start` is still awaiting, so its watchdog
        // may already have fired, and that report was ignored (no current encoder yet).
        if enc.isDead { Task { @MainActor in await self.encoderHung(enc) } }
    }

    // MARK: Bringing the target forward
    //
    // On select, regular mode raises the picked window (`activateAndRaise`, 2026-09-23, Noah: the
    // Mac must show the picked window). A window staged on the virtual display never touches Mac
    // focus on select (a pick that falls back to the real window is regular mode), and neither do
    // the host's own restarts. On interaction, both modes do what a real click does: a click,
    // keystroke or typed text into the streamed window first activates its app, because keys go to
    // the active app's key window and a first click into an inactive app is otherwise eaten as
    // "activate". On the regular path the window is also raised when another window covers the
    // click or scroll point, so the event reaches it and it repaints; on the virtual display a
    // cover can only be a stranger, which is moved off instead. Activation is Accessibility only
    // (the direct NSRunningApplication call is refused from a background process since macOS 14,
    // and a Launch Services "open" trips app-based Focus automations); the app comes up a moment
    // later, so the events that triggered it are held and replayed in order once it is up. A pick always goes
    // through Accessibility. Interaction stays cheap: one frontmost lookup per half second at
    // most, and Accessibility only when the app is not active or a cover is found. An app that
    // lets the activation run into its timeout (a beach ball) gets no further AX calls from
    // either: each would hold the main actor for another second.
    /// Consecutive catalog polls the streamed window has been missing from the list while it may be
    /// entering or leaving full screen: the staged full-screen window, or in regular mode one that was
    /// full screen when last listed or that Sill fitted (`windowsChanged`).
    private var missingPolls = 0
    private var lastRaiseCheck: CFAbsoluteTime = 0
    private var lastActivationAt: CFAbsoluteTime = 0
    /// Input held for an activation, replayed in order once the app is up, each with the device that
    /// sent it (its keys are its own, KeyStrokes); a gesture's chord that arrives meanwhile waits
    /// behind it, so a click just before the gesture lands first.
    private enum Held { case input(InputEvent, CGRect, KeyStrokes.Device), chord(keyCode: UInt16, flags: UInt64) }
    private var heldInput: [Held] = []
    private var holdUntil: CFAbsoluteTime = 0
    /// Devices that left while input was held: their keys go up after it (`releaseKeys`).
    private var leftWhileHeld: [KeyStrokes.Device] = []
    /// How long held input waits for the app to become frontmost before it is replayed anyway.
    private static let activationTimeout: TimeInterval = 0.6

    private func deliver(_ event: InputEvent, in rect: CGRect, from device: KeyStrokes.Device) {
        // Queue while holding, and while anything is still queued, so order is never inverted.
        if !heldInput.isEmpty || CFAbsoluteTimeGetCurrent() < holdUntil { heldInput.append(.input(event, rect, device)); return }
        logClick(event, in: rect)
        injector.apply(event, in: rect, from: device)
    }

    private func releaseHeldInput() {
        holdUntil = 0
        let held = heldInput
        heldInput = []
        for item in held {
            switch item {
            case .input(let event, let rect, let device): logClick(event, in: rect); injector.apply(event, in: rect, from: device)
            case .chord(let keyCode, let flags): injector.chord(keyCode: keyCode, flags: flags)
            }
        }
        releaseKeysOfDevicesThatLeft()
    }

    /// A device left: the keys it still holds down on the Mac go up (InputInjector.releaseKeys),
    /// after whatever of its input is still held for an activation, so no up of its own is overtaken
    /// and no down of its own comes after.
    private func releaseKeys(of device: KeyStrokes.Device) {
        if !heldInput.isEmpty || CFAbsoluteTimeGetCurrent() < holdUntil { leftWhileHeld.append(device); return }
        injector.releaseKeys(of: device)
    }

    private func releaseKeysOfDevicesThatLeft() {
        let left = leftWhileHeld
        leftWhileHeld = []
        for device in left { injector.releaseKeys(of: device) }
    }

    private func raiseIfInteracting(_ event: InputEvent) {
        // Nothing mid-switch, pick or restart: `active` names the old source until capture has
        // started, and by then a pick has already raised the new window. Raising or activating
        // the old one here would put it back in front of the pick (a flick's momentum scroll keeps
        // arriving through a tap on the switcher). The event itself is still delivered, so no
        // key-up or button-up goes missing.
        guard !switching, case .window(let id) = active else { return }
        // Scroll routes to the window under the cursor whatever the active app is: it only needs
        // uncovering (regular path). Clicks, keys and text need the app active and the window key.
        let needsFocus: Bool
        switch event {
        case .pointer(let action, _, _): guard action == .leftDown || action == .rightDown else { return }; needsFocus = true
        case .scroll: needsFocus = false
        case .scrollGesture(let phase, _, _): guard phase == .began else { return }; needsFocus = false
        case .key(_, let down, _): guard down else { return }; needsFocus = true
        case .text: needsFocus = true
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRaiseCheck > 0.5 else { return }     // a burst of keys or scroll ticks is one check
        lastRaiseCheck = now
        let staged = virtualDisplay && stage.isStaged
        guard let pid = staged ? stage.placement?.pid : catalog.window(id: id)?.owningApplication?.processID else { return }
        // `NSWorkspace.frontmostApplication` is stale in a process without an AppKit run loop
        // (measured: it named an app that had not been active for minutes), so it is only used
        // under that loop (the app; the CLI's --virtual-display). Otherwise the active app is read
        // off the window list: the owner of the topmost layer-0 window. Covered = another app's
        // window under the click point.
        let point = injectorProbePoint(event)
        let cover = point.flatMap { Self.topmostWindow(at: $0) }
        let covered = cover != nil && cover?.id != id            // any other window over the spot, same app or not
        // On the virtual display a cover is a stranger (a window left there by an earlier run):
        // move it off, then the click lands.
        if staged, covered { stage.evictForeignWindows() }
        let notActive = needsFocus && Self.activePID(trustAppKit: appKitLoop) != pid
        guard notActive || covered else { return }
        // A failed activation must not stall every later interaction: one attempt per 2 s.
        guard now - lastActivationAt > 2 else { return }
        lastActivationAt = now
        // An app that let the activation run into its timeout gets no more AX calls, each of which
        // would wait out another second; the hold below still applies.
        let answered = notActive ? activate(pid: pid) : true
        // The streamed window must also be the app's key window, or its first click only makes it
        // key (acceptsFirstMouse is false for most controls). Raising lifts it above the cover.
        // One window lookup serves both.
        if answered {
            if staged, let element = stage.placement?.element {
                if needsFocus { WindowSizer.makeKey(element) }
            } else if let w = catalog.window(id: id), let element = sizer.element(for: w) {
                if needsFocus { WindowSizer.makeKey(element) }
                if covered, WindowSizer.raise(element) { Stats.shared.bump("win.raised") }
            }
        }
        holdUntil = now + Self.activationTimeout
        Task { @MainActor in
            // Replay as soon as our window is the one under the click (usually 50–200 ms), or at
            // the timeout. On the virtual display nothing can cover it: wait for activation only.
            let deadline = CFAbsoluteTimeGetCurrent() + Self.activationTimeout
            while CFAbsoluteTimeGetCurrent() < deadline {
                let active = Self.activePID(trustAppKit: self.appKitLoop) == pid
                let onTop = staged || point.flatMap { Self.topmostWindow(at: $0) }?.pid == pid
                if active && onTop { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            self.releaseHeldInput()
        }
    }

    /// A pick in regular mode: the window comes forward on the Mac as if clicked there. Its app is
    /// activated, the window raised to the front and made key, so capture starts on an uncovered
    /// window and typed keys go to it. `raiseIfInteracting`'s throttle is left alone: a click
    /// right after a pick that finds the app not up yet still activates and holds as usual.
    /// Every AX call here is synchronous on the main actor, and a hung app (a beach ball, a
    /// debugger pause) holds every device's input and the catalog for a second per call: raise
    /// and key share one window lookup, and none is made once the activation ran into its timeout.
    private func activateAndRaise(window w: SCWindow) {
        guard let pid = w.owningApplication?.processID else { return }
        guard activate(pid: pid) else {
            print("\(w.owningApplication?.applicationName ?? "?") is not answering Accessibility; its window is not raised.")
            return
        }
        guard let element = sizer.element(for: w) else { return }
        if WindowSizer.raise(element) { Stats.shared.bump("win.raised") }
        WindowSizer.makeKey(element)
    }

    /// Makes `pid` the active app, through Accessibility only: synchronous, and it touches only this
    /// app's ordering. Never through Launch Services: "opening" an already-running app that way
    /// counts as opening it, and it switched on Noah's Work Focus (an app-based Focus automation)
    /// every time (2026-09-22 and 23). If AX refuses, the app stays where it is and the raise below
    /// still runs. False when the app did not answer at all, so the caller makes no further AX
    /// calls into it. Only a call that ran out the whole timeout counts: `.cannotComplete` is also
    /// a quick refusal from a live app, whose window may still take a raise.
    private func activate(pid: pid_t) -> Bool {
        let timeout: Float = 1.0
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let started = CFAbsoluteTimeGetCurrent()
        let err = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if err == .success {
            Stats.shared.bump("win.activated")
            return true
        }
        Stats.shared.bump("win.activateRefused")
        let timedOut = err == .cannotComplete && CFAbsoluteTimeGetCurrent() - started >= Double(timeout) * 0.9
        if timedOut { Stats.shared.bump("win.axTimeout") }
        return !timedOut
    }

    /// One line per second at most: where a click lands on the Mac and which window is there,
    /// against the one being streamed. The quickest way to see a mapping or ordering problem.
    private var lastClickLog: CFAbsoluteTime = 0
    private func logClick(_ event: InputEvent, in rect: CGRect) {
        guard case .pointer(let action, let x, let y) = event, action == .leftDown || action == .rightDown,
              case .window(let id) = active else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastClickLog > 1 else { return }
        lastClickLog = now
        let p = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        let top = Self.topmostWindow(at: p)
        let verdict = top?.id == id ? "the streamed window" : "window \(top.map { String($0.id) } ?? "none"), not the streamed \(id)"
        print("Click at (\(Int(p.x)),\(Int(p.y))) in (\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))×\(Int(rect.height))) → \(verdict)")
    }

    /// The screen point an interaction lands on (for the topmost-window check); nil for keys.
    private func injectorProbePoint(_ event: InputEvent) -> CGPoint? {
        guard let rect = currentSourceRect() else { return nil }
        switch event {
        case .pointer(_, let x, let y), .scroll(let x, let y, _, _), .scrollGesture(_, let x, let y):
            return CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        default: return nil
        }
    }

    /// The on-screen layer-0 window under `point` (any point when nil, i.e. the frontmost normal
    /// window on screen) and its owner, or nil when unknown.
    private static func topmostWindow(at point: CGPoint?) -> (id: CGWindowID, pid: pid_t)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {   // front to back
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,   // invisible overlays are not covers
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if let point, !rect.contains(point) { continue }
            return (id, pid)
        }
        return nil
    }

    /// The active app's pid. AppKit's answer only when this process runs the AppKit loop (the
    /// app, or the CLI's --virtual-display); otherwise the owner of the frontmost normal window,
    /// which is what the window server considers active for input.
    private static func activePID(trustAppKit: Bool) -> pid_t? {
        if trustAppKit, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { return pid }
        return topmostWindow(at: nil)?.pid
    }

    /// Retina normally; points when the software encoder is carrying the stream.
    private var captureScale: CGFloat { useSoftwareEncoder ? min(scale, 1.0) : scale }

    /// "Safari — Apple Developer" for the app's menu; just the app for an untitled window.
    private static func menuTitle(for w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "?"
        let title = w.title ?? ""
        return title.isEmpty ? app : "\(app) — \(title)"
    }

    // MARK: The Mac's menus (MenuMirror; docs/menu-bar-plan.md §4.5)
    //
    // Which app's menus a device is shown: the streamed window's, or on the Desktop the frontmost
    // app's (never Sill's own: a device's "Quit Sill" would end the host). The mirror hears of a
    // change only while a device subscribes; with none, `menuTargetChanged` is one comparison.

    /// The app behind the current source, for the menus: nil for nothing streaming and for Sill.
    private func menuTarget() -> MenuMirror.Target? {
        switch active {
        case .none:
            return nil
        case .window(let id):
            if virtualDisplay, let p = stage.placement, p.windowID == id {
                return p.pid == WindowCatalog.ownPID ? nil : Self.menuTarget(pid: p.pid, window: id)
            }
            guard let app = catalog.window(id: id)?.owningApplication, app.processID != WindowCatalog.ownPID else { return nil }
            return Self.menuTarget(pid: app.processID, window: id)
        case .desktop:
            return desktopMenuTarget()
        }
    }

    /// The Desktop's: the frontmost app (AppKit's under its loop, else the owner of the topmost
    /// window; see `activePID`). A synthetic host has none, but for the TEST ONLY hook's process.
    private func desktopMenuTarget() -> MenuMirror.Target? {
        if synthetic {
            guard let pid = testMenuPID, MenuReader.alive(pid) else { return nil }
            return Self.menuTarget(pid: pid)
        }
        guard let pid = Self.activePID(trustAppKit: appKitLoop), pid != WindowCatalog.ownPID else { return nil }
        return Self.menuTarget(pid: pid)
    }

    /// One name for an app whichever source names it (the window list's and AppKit's can differ).
    private static func menuTarget(pid: pid_t, window: CGWindowID? = nil) -> MenuMirror.Target {
        let app = NSRunningApplication(processIdentifier: pid)
        return MenuMirror.Target(pid: pid, app: app?.localizedName ?? "pid \(pid)", bundleID: app?.bundleIdentifier, window: window)
    }

    /// The source, or the Desktop's frontmost app, may have changed.
    private func menuTargetChanged() {
        guard menus.hasSubscribers else { return }
        menus.setTarget(menuTarget())
    }

    /// Every catalog poll (2 s) while a device is connected.
    private func menusPolled() {
        guard menus.hasSubscribers else { return }
        if active == .desktop { menuTargetChanged() }
        menus.catalogPolled()
    }

    /// A device's click or key on the Desktop can bring another app forward (50–200 ms later): its
    /// menus are looked at again 0.3 s after, at most once per 0.5 s.
    private func desktopInputMayActivate(_ event: InputEvent) {
        guard active == .desktop, menus.hasSubscribers, !menuFrontCheckPending else { return }
        switch event {
        case .pointer(let action, _, _): guard action == .leftDown || action == .rightDown else { return }
        case .key(_, let down, _): guard down else { return }
        default: return
        }
        menuFrontCheckPending = true
        let wait = max(0.3, menuFrontCheckAt + 0.5 - CFAbsoluteTimeGetCurrent())
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            self.menuFrontCheckPending = false
            self.menuFrontCheckAt = CFAbsoluteTimeGetCurrent()
            if self.active == .desktop { self.menuTargetChanged() }
        }
    }

    /// Under the AppKit loop (Sill.app, the CLI's --virtual-display), while a device subscribes:
    /// the Desktop's menus follow an app activated on the Mac at once, not at the next poll.
    private func watchFrontmostApp(_ on: Bool) {
        guard appKitLoop else { return }
        if on, frontmostObserver == nil {
            frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.active == .desktop else { return }
                    self.menuTargetChanged()
                }
            }
        } else if !on, let observer = frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            frontmostObserver = nil
        }
    }

    /// Before a menu of a window source is read or one of its items pressed: its app active and the
    /// window key, as a click from the device makes them (`raiseIfInteracting`: Accessibility only,
    /// one activation attempt per 2 s, never Launch Services). An inactive app's states differ (its
    /// Copy, Close and Minimize read disabled: the probe), and a press must act on the streamed
    /// window, not another of the app's. No raise: a menu needs the app active, not the window
    /// uncovered. True when the app is frontmost as this returns. The Desktop's app is frontmost
    /// already, and a synthetic host's hook is never activated: true at once for both and for
    /// nothing. During a switch (`active` still names the old source) nothing is activated.
    private func focusForMenus() async -> Bool {
        guard case .window(let id) = active else { return true }
        let staged = virtualDisplay && stage.isStaged
        guard let pid = staged ? stage.placement?.pid : catalog.window(id: id)?.owningApplication?.processID else { return false }
        let frontmost = Self.activePID(trustAppKit: appKitLoop) == pid
        if switching { return frontmost }
        var answered = true
        if !frontmost {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastActivationAt > 2 else { return false }
            lastActivationAt = now
            answered = activate(pid: pid)
        }
        // An app that let the activation run into its timeout gets no more AX calls from here.
        guard answered else { return false }
        if staged, let element = stage.placement?.element {
            WindowSizer.makeKey(element)
        } else if let w = catalog.window(id: id), let element = sizer.element(for: w) {
            WindowSizer.makeKey(element)
        }
        if frontmost { return true }
        let deadline = CFAbsoluteTimeGetCurrent() + Self.activationTimeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            if Self.activePID(trustAppKit: appKitLoop) == pid { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return Self.activePID(trustAppKit: appKitLoop) == pid
    }

    /// TEST ONLY: `SILL_TEST_MENU_PID`, honoured only by a --synthetic host (which does not
    /// advertise), with the one line `start` prints about it. Nothing, and no line, without it.
    private static func testMenuHook(synthetic: Bool) -> (pid: pid_t?, line: String?) {
        guard let raw = ProcessInfo.processInfo.environment["SILL_TEST_MENU_PID"] else { return (nil, nil) }
        let shown = SafeText.label(raw, limit: 32)
        guard synthetic else { return (nil, "SILL_TEST_MENU_PID=\(shown) ignored: only a --synthetic host takes it.") }
        guard let pid = pid_t(raw), pid > 0, MenuReader.alive(pid) else {
            return (nil, "SILL_TEST_MENU_PID=\(shown) ignored: not a running process.")
        }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName.map { SafeText.label($0) } ?? "no app name"
        return (pid, "Test menus: the test pattern's menus are pid \(pid)'s (\(name)); read and pressed without activating it.")
    }

    // MARK: Virtual display lifecycle

    /// The window server removed the virtual display (sleep/wake, display arbitration). The stage
    /// has already put the window back; stage it again, or after repeated losses give up on the
    /// virtual display for this run and stream the real window.
    private func stageLost() async {
        stageLosses += 1
        print("The system removed the virtual display; the window is back on a real display.")
        if stageLosses > 2 {
            stage.disabledReason = "the system removed the virtual display \(stageLosses) times"
            status.update { $0.virtualDisplayProblem = stage.disabledReason }
        }
        if case .window = active { await select(active) }
    }

    /// Called by HostShutdown on the main queue just before `exit` (or, for the app's Quit, just
    /// before AppKit exits): every key and button a device holds down on the Mac goes up (a modifier
    /// left down would outlive Sill: the Mac's next click a ⌘-click), every connected device hears why
    /// (kind 22 "quit", at most 0.1 s), then a window Sill sized goes back to its own frame
    /// (`restoreFits`), the staged window home, display gone. Capture and encoder need no stop; the
    /// process is about to end. The CLI without --virtual-display lets go of the keys, puts a sized
    /// window back and dies of the signal with no goodbye (`releaseKeysForExit`): its devices notice
    /// by liveness.
    package func shutdownForExit() {
        injector.releaseAll()
        server.goodbyeAll(Goodbye(reason: Goodbye.quit), within: 0.1)
        shuttingDown = true
        restoreFits(keeping: nil)
        stage.release()
    }

    /// The CLI's default path at a signal (HostShutdown.installKeyRelease), just before it dies of it:
    /// every key and button a device holds down on the Mac goes up, and a window Sill sized for a
    /// device goes back to its own frame (a line each, only when a window was sized); nothing else
    /// happens (no goodbye), as before.
    package func releaseKeysForExit() {
        injector.releaseAll()
        restoreFits(keeping: nil)
    }

    // MARK: A window Sill sized goes back (WindowRestore, issue #57)

    /// Puts back every window Sill sized but `keep` (nil: every one) as it stops streaming
    /// (`WindowRestore.Ledger.restore`, which runs `WindowRestore.stop` for each): WindowRestore decides
    /// from its frame now (gone, already home, left as it is because it is full screen or was resized on
    /// the Mac, or restored: its whole original frame, or its own size where it was moved), and it is
    /// moved through the element its first fit matched, as the virtual display's restore moves a window.
    /// A window the virtual display holds goes home with the stage, to the frame `stageHome` gave it:
    /// only when Quit or a signal lands while `select` waits in `prepare`. One line for each window acted
    /// on; none for one gone or already home.
    private func restoreFits(keeping keep: CGWindowID?) {
        var windows = WindowSizer.AXWindows(sizer: sizer)
        for s in fits.restore(keeping: keep, staged: stage.placement?.windowID, on: &windows) {
            if case .restore = s.decision { Stats.shared.bump(s.done ? "win.restored" : "win.restoreFailed") }
            if let line = s.line { print(line) }
        }
    }

    /// Where a window Sill sized would go back to now, for the virtual display's stage to keep as its
    /// way home when it takes the window (`VirtualStage.prepare(…, home:)`); nil when it has no
    /// record, or would stay as it is.
    private func stageHome(for id: CGWindowID) -> CGRect? {
        guard let entry = fits.entries[id] else { return nil }
        var windows = WindowSizer.AXWindows(sizer: sizer)
        return WindowRestore.stageHome(entry.handle, entry.record, on: &windows)
    }

    /// An encoder's watchdog fired. A hardware hang is remembered whichever encoder reports it, as
    /// long as that encoder is newer than the last return to the hardware (an older one's report
    /// is stale and must not undo the return), but only the encoder carrying the stream may
    /// restart it: a replaced encoder whose frame is still stuck inside VideoToolbox times out
    /// later, and must not disturb its successor. A hardware hang: switch to the software encoder
    /// and restart the source; the re-check brings it back. If even the software encoder dies
    /// repeatedly, stop streaming rather than loop.
    private func encoderHung(_ enc: HEVCEncoder, attempt: Int = 0) async {
        if !enc.software, !useSoftwareEncoder, enc.serial > returnSerial {
            enterSoftwareFallback(afterHang: true)
        }
        guard enc === encoder, active != .none else { return }
        if switching {
            // Reported in the tail of a switch: `select` would drop it. Try again once it has settled.
            guard attempt < 50 else { print("Encoder hang report could not be applied: a switch never finished."); return }
            try? await Task.sleep(for: .milliseconds(100))
            await encoderHung(enc, attempt: attempt + 1)
            return
        }
        if enc.software {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastSoftwareHangAt > 60 { softwareRestarts = 0 }   // three hangs within a minute stop the stream
            lastSoftwareHangAt = now
            softwareRestarts += 1
            guard softwareRestarts <= 3 else {
                print("Software encoder hung too; stopping the stream.")
                await select(.none)
                return
            }
        }
        await select(active)
    }

    // MARK: The software fallback and the way back

    /// From here the software encoder carries every stream, at half the capture scale and up to 60
    /// fps: a hardware session stopped returning frames (`afterHang`), or the launch probe got no
    /// answer. Busy or stuck cannot be told apart yet (a busy engine's frame comes back seconds
    /// later, and the encoder's deinit says so), so both start the re-check. A hang soon after a
    /// return means the busy spell is still on: the next check waits longer.
    private func enterSoftwareFallback(afterHang: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if lastReturnAt > 0 {
            let lasted = now - lastReturnAt
            if lasted < Self.returnDidNotLast {
                recheckInterval = min(recheckInterval * 2, Self.recheckMaxInterval)
            } else if lasted >= Self.returnLasted {
                recheckInterval = Self.recheckFirstInterval
            }
        }
        useSoftwareEncoder = true
        status.update { $0.softwareEncoder = true }
        Stats.shared.bump("enc.fallback")
        lastRecheck = now
        recheckDue = now + recheckInterval
        let next = Int(recheckInterval)
        if afterHang {
            print("Hardware HEVC encoder is not returning frames (busy or stuck); switching to the software encoder at half scale until the hardware keeps up again (next check in \(next) s).")
        } else {
            print("The Mac's hardware video encoder is not answering; streaming with the software encoder at half scale until a check finds it keeping up (every \(next) s while a device is connected).")
        }
        startRecheck()
    }

    /// A device connected (`firstArrived`: the first after none). On the software encoder a check
    /// runs at once if the last one is 30 s old, so a stream that starts now can start on the
    /// hardware, then the re-check goes on while devices stay.
    private func devicesPresent(firstArrived: Bool) {
        guard useSoftwareEncoder else { return }
        if firstArrived {
            recheckDue = min(recheckDue, max(CFAbsoluteTimeGetCurrent(), lastRecheck + Self.recheckFirstInterval))
        }
        startRecheck()
    }

    private func startRecheck() {
        guard useSoftwareEncoder, !softwareOnly, !shuttingDown, recheckTask == nil, catalog.clientCount > 0 else { return }
        recheckToken += 1
        let token = recheckToken
        recheckTask = Task { @MainActor [weak self] in
            await self?.recheckLoop()
            guard let self, self.recheckToken == token else { return }
            self.recheckTask = nil
            // A device that connected while this cancelled loop finished its test or its sleep, a
            // wake (`stalledProbeCameBack`), a fallback that came as it ended; a no-op otherwise.
            self.startRecheck()
        }
    }

    /// The last device left: no hardware session is opened while nobody watches. A test already
    /// running cannot be cut short, so the task stays `recheckTask` until its loop has ended: a
    /// device that connects meanwhile gets no second loop (two tests at once split the engine,
    /// and each backed off for the other), and the ending task's tail starts one for it.
    private func stopRecheck() {
        recheckTask?.cancel()
    }

    /// Main actor. Waits for `recheckDue`, runs a short test of the hardware at the stream's size
    /// off the main actor (`EncoderProbe.throughput`: no line, no counter), and goes back to it when
    /// it keeps up. A check where it does not (no answer, or too slow: busy) prints one line and
    /// doubles the wait. Ends when cancelled (no device), when the hardware is back, or when the
    /// host shuts down. A test running when the loop is cancelled goes on to its end: a return is
    /// still taken, and anything else is dropped without a line when no device is left.
    private func recheckLoop() async {
        while !Task.isCancelled, useSoftwareEncoder, !shuttingDown {
            let wait = recheckDue - CFAbsoluteTimeGetCurrent()
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                continue      // look again: cancelled, back already, or the due time moved
            }
            let stuck = EncoderProbe.stuckProbes
            if stuck >= Self.maxStuckProbes {
                // Every further probe of a stuck encoder would block one more thread for good. The
                // menu says so: a restart of the Mac, not waiting, fixes this one.
                if !recheckHeldBack {
                    recheckHeldBack = true
                    print("Hardware encoder: \(stuck) checks never got their frame back, so it is stuck, not busy; no more checks until one comes back. Restarting the Mac fixes a stuck encoder.")
                }
                status.update { $0.hardwareEncoderStuck = true }
                recheckDue = CFAbsoluteTimeGetCurrent() + Self.recheckMaxInterval
                continue      // until then, unless a frame comes back first (`stalledProbeCameBack`)
            }
            leaveStuck(cameBackAfter: nil)   // a probe came back while this loop slept: checking again
            // At the size the stream would have on the hardware, and fast enough for it: a small
            // frame answers even while a busy engine starves a stream (EncoderProbe), and a large
            // one is asked no more than a free engine gives at its size (`returnBar`).
            let size = hardwareProbeSize
            let pixels = size.width * size.height
            let needed = EncoderProbe.returnBar(streamFPS: wantedFPS, pixels: pixels, enginePixelRate: enginePixelRate)
            let result = await withCheckedContinuation { (c: CheckedContinuation<(ok: Bool, fps: Double?, ms: Int), Never>) in
                // The probe waits on a semaphore, up to 1 s a frame: a GCD thread, not the main
                // actor or a Swift concurrency thread. Not utility: the software encoder keeps the
                // CPU busy meanwhile, and a late wake-up between frames would count against the engine.
                DispatchQueue.global(qos: .userInitiated).async {
                    c.resume(returning: EncoderProbe.throughput(width: size.width, height: size.height))
                }
            }
            let now = CFAbsoluteTimeGetCurrent()
            lastRecheck = now
            guard useSoftwareEncoder, !shuttingDown else { return }
            if result.ok, let fps = result.fps { enginePixelRate = max(enginePixelRate, fps * Double(pixels)) }
            let measured = result.fps.map { "\(Int($0.rounded())) fps at \(size.width)×\(size.height)" } ?? "answered at \(size.width)×\(size.height)"
            if result.ok, (result.fps ?? .infinity) >= needed {
                // Taken even if the last device left meanwhile: the next stream then starts on it.
                // In a task of its own, which cancelling the re-check cannot reach: the restart's
                // own waits (Task.sleep in the stage and here) must not end early.
                let back = await Task { @MainActor in await self.hardwareIsBack(measured: measured, needed: needed) }.value
                // Back: the loop ends, unless the restart's new session already hung and set the
                // flag and the next check again (then it goes on). A later hang starts a new
                // re-check (startRecheck).
                if !back { recheckDue = CFAbsoluteTimeGetCurrent() + recheckInterval }   // a switch never settled; try later
                continue
            }
            if catalog.clientCount == 0 {
                // The last device left while the test ran (this loop is cancelled): no line and no
                // backoff for a check nobody waits for. The next device's check comes 30 s after
                // this one at the earliest (`devicesPresent`).
                recheckDue = now + recheckInterval
                return
            }
            recheckInterval = min(recheckInterval * 2, Self.recheckMaxInterval)
            recheckDue = now + recheckInterval
            if result.ok {
                print("Hardware encoder answers but is busy (\(measured) in a test, under the \(Int(needed.rounded())) fps a return needs; another app is using it); next check in \(Int(recheckInterval)) s.")
            } else {
                print("Hardware encoder still not answering after \(result.ms) ms; next check in \(Int(recheckInterval)) s.")
            }
        }
    }

    /// The size a hardware stream would have now: the running one's at the full capture scale, or
    /// the Desktop's while nothing streams (a device asks for the Desktop first).
    private var hardwareProbeSize: (width: Int, height: Int) {
        if let size = Self.testProbeSize { return size }
        if active != .none, let enc = encoder {
            let factor = enc.software ? scale / min(scale, 1.0) : 1   // the software encoder runs at points
            return (evenPixels(CGFloat(enc.width) * factor), evenPixels(CGFloat(enc.height) * factor))
        }
        if synthetic { return (evenPixels(1512 * scale), evenPixels(949 * scale)) }
        if let d = catalog.display { return (evenPixels(CGFloat(d.width) * scale), evenPixels(CGFloat(d.height) * scale)) }
        return (evenPixels(1920 * scale), evenPixels(1080 * scale))
    }

    /// A re-check found the hardware keeping up: the next pipeline uses it, and a running stream
    /// restarts on it now (one restart, like a settings change: Mac focus is left alone). Waits out
    /// a switch in flight first, which may be building a software encoder; false when it never
    /// settled, and the re-check tries again later.
    private func hardwareIsBack(measured: String, needed: Double) async -> Bool {
        var waited = 0
        while switching {
            guard waited < 50 else { return false }
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard useSoftwareEncoder, !shuttingDown else { return true }
        useSoftwareEncoder = false
        softwareRestarts = 0
        lastReturnAt = CFAbsoluteTimeGetCurrent()
        returnSerial = HEVCEncoder.latestSerial
        recheckHeldBack = false
        status.update { $0.softwareEncoder = false; $0.hardwareEncoderStuck = false }
        Stats.shared.bump("enc.hardwareBack")
        let test = "\(measured) in a test, \(Int(needed.rounded())) needed"
        if active != .none {
            print("Hardware encoder is back (\(test)); restarting the stream on it.")
            await select(active)   // nothing awaited since `switching` read false: this select runs
        } else {
            print("Hardware encoder is back (\(test)); the next stream uses it.")
        }
        return true
    }

    /// Out of "stuck": fewer than `maxStuckProbes` checks are still out, since one's frame came back
    /// (`seconds` after it went in, when the probe said). The menu stops asking for a restart of
    /// the Mac, and the log says so once, as it said "stuck" once.
    private func leaveStuck(cameBackAfter seconds: TimeInterval?) {
        guard recheckHeldBack else { return }
        recheckHeldBack = false
        status.update { $0.hardwareEncoderStuck = false }
        let after = seconds.map { " after \(String(format: "%.1f", $0)) s" } ?? ""
        print("Hardware encoder: a check's frame came back\(after), so it is not stuck; checks resume.")
    }

    /// A check's stalled frame came back (EncoderProbe's hook). While the re-check is held back as
    /// stuck and this brings the count under the limit, the menu stops saying "stuck" now, not when
    /// the held-back loop wakes (up to 300 s later, or never while no device is connected), and a
    /// check runs at once while a device is connected (the next device's first thing otherwise).
    private func stalledProbeCameBack(after seconds: TimeInterval) {
        guard recheckHeldBack, EncoderProbe.stuckProbes < Self.maxStuckProbes else { return }
        leaveStuck(cameBackAfter: seconds)
        recheckDue = CFAbsoluteTimeGetCurrent()
        recheckTask?.cancel()   // ends the held-back loop's sleep; its tail starts a new loop while a device is connected
    }

    private func windowsChanged(_ infos: [WindowInfo]) async {
        // The pointer's rectangle follows the catalog: the Desktop's display, a window's bounds.
        defer { pointer.setGeometry(pointerGeometry(), fps: fps) }
        if let pending = pendingLaunch, let w = infos.first(where: { $0.bundleID == pending }) {
            pendingLaunch = nil
            await select(.window(w.id), bringForward: true)   // launched from the device to use it: a pick
            return
        }
        if case .window(let id) = active {
            guard let w = infos.first(where: { $0.id == id }) else {
                // Alive on the virtual display even if the on-screen list dropped it.
                if virtualDisplay, stage.isStaged, Self.liveBounds(of: id) != nil { broadcastList(); return }
                // Leaving full screen, a window is off every list for a second or two. Give it
                // three polls before calling it closed, then restart so the stage re-places it.
                if virtualDisplay, stage.isStaged, stage.fullScreen {
                    missingPolls += 1
                    if missingPolls <= 3 { broadcastList(); return }
                    missingPolls = 0
                } else if !(virtualDisplay && stage.isStaged) {
                    // In regular mode too: one that was full screen when last listed, or that Sill fitted
                    // and Accessibility says is full screen now, keeps streaming through three looks, so a
                    // fitted window's way back is not decided mid-change (issue #57's review).
                    missingPolls += 1
                    var windows = WindowSizer.AXWindows(sizer: sizer)
                    if WindowRestore.keepsStreaming(fits.entries[id]?.handle, looks: missingPolls, wasFullScreen: listedFullScreen == id, on: &windows) {
                        broadcastList(); return
                    }
                    missingPolls = 0
                }
                await select(.none); return
            }
            missingPolls = 0
            if !(virtualDisplay && stage.isStaged), let scw = catalog.window(id: id) {
                listedFullScreen = WindowRestore.coversDisplay(scw.frame, WindowSizer.displayFrames()) ? id : nil
            }
            if virtualDisplay, stage.isStaged {
                // Full screen: the crop is a band of the display, not the window's frame. Stay put
                // while the window still covers the display; restart once it has left full screen.
                if stage.fullScreen {
                    if stage.windowStillFullScreen { broadcastList() } else { await select(active) }
                    return
                }
                // The crop differs from the window's frame, so the encoder-size check below would
                // restart every poll; compare against the display instead.
                if stage.windowLeftDisplay { await select(active); return }   // dragged off (Mission Control): re-place it
                if let live = stage.liveCaptureRect(),
                   abs(live.width - stage.captureRect.width) > 2 || abs(live.height - stage.captureRect.height) > 2 {
                    await select(active); return                              // the app resized itself: same display, new crop
                }
                broadcastList()
                return
            }
            // The encoder is fixed to one size, so a resized window means a fresh pipeline.
            if let scw = catalog.window(id: id),
               evenPixels(scw.frame.width * captureScale) != encoderWidth || evenPixels(scw.frame.height * captureScale) != encoderHeight {
                _ = w
                await select(active)
                return
            }
        }
        broadcastList()
    }

    private var encoderWidth: Int { encoder?.width ?? 0 }
    private var encoderHeight: Int { encoder?.height ?? 0 }

    // MARK: Trackpad gestures

    /// Posts gestures in arrival order, once a switch in flight is done (at most 2 s later): a
    /// gesture made while a window streamed comes right after the device's Desktop pick, the
    /// window may be on its way home from the virtual display, and the view should open over the
    /// Desktop, which is the only source that shows it.
    private func queueGesture(_ gesture: TrackpadGesture, from device: String) {
        pendingGestures.append((gesture, device))
        guard gestureDrain == nil else { return }
        gestureDrain = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = CFAbsoluteTimeGetCurrent() + 2
            while self.switching, CFAbsoluteTimeGetCurrent() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            while !self.pendingGestures.isEmpty {
                let next = self.pendingGestures.removeFirst()
                self.performGesture(next.gesture, from: next.device)
            }
            self.gestureDrain = nil
        }
    }

    /// One gesture: the Mac's shortcut for it as its Keyboard Shortcuts are now (GestureChords),
    /// one line saying what it did, and the chord posted, behind input held for an activation; on
    /// a host that does not advertise, only counted. Nothing is raised or activated first: these
    /// views act on the whole Mac (App Exposé on the app in front), as they do from its keyboard.
    private func performGesture(_ gesture: TrackpadGesture, from device: String) {
        guard !shuttingDown else { return }
        let outcome = gestureChords.resolve(gesture.gesture, table: hotKeyTable())
        print(GestureChords.line(device: device, gesture: gesture.gesture, fingers: gesture.fingers,
                                 outcome: outcome, dryRun: gesturesDry))
        guard case .chord(_, _, let keyCode, let flags) = outcome else { return }
        if gesturesDry {
            Stats.shared.bump("in.gestureDry")
            return
        }
        if !heldInput.isEmpty || CFAbsoluteTimeGetCurrent() < holdUntil {
            heldInput.append(.chord(keyCode: keyCode, flags: flags))
            return
        }
        injector.chord(keyCode: keyCode, flags: flags)
    }

    /// A device's input as `GestureChords` weighs it: whether it can close a view a gesture opened.
    static func gestureInput(_ event: InputEvent) -> GestureChords.Input {
        switch event {
        case .pointer(let action, _, _):
            switch action {
            case .move: return .pointerMove
            case .leftDown, .rightDown: return .buttonDown
            case .leftUp, .rightUp: return .buttonUp
            }
        case .scroll, .scrollGesture: return .scroll
        case .key(_, let down, _): return down ? .keyDown : .keyUp
        case .text: return .text
        }
    }

    /// This Mac's Keyboard Shortcuts for the gestures, read now (SymbolicHotKeys); macOS 27's own
    /// when this macOS has no getters for them (said once); a test host's SILL_TEST_HOTKEYS table.
    private func hotKeyTable() -> [Int: HotKey] {
        if let testHotKeys { return testHotKeys }
        if let table = SymbolicHotKeys.read(GestureChords.hotKeyIDs) { return table }
        if !saidHotKeysMissing {
            saidHotKeysMissing = true
            print("Gestures: this macOS does not say what its keyboard shortcuts are; using macOS 27's own.")
        }
        return GestureChords.defaults
    }

    /// TEST ONLY: SILL_TEST_HOTKEYS, read once by a host that does not advertise: "defaults", or
    /// `ID=off` and `ID=KEYCODE:MODIFIERS` entries over them (GestureChords.testTable). A value that
    /// does not parse is ignored with one line.
    private static func testHotKeyTable() -> [Int: HotKey]? {
        guard let raw = ProcessInfo.processInfo.environment["SILL_TEST_HOTKEYS"], !raw.isEmpty else { return nil }
        guard let table = GestureChords.testTable(raw) else {
            print("SILL_TEST_HOTKEYS=\(raw) ignored: \"defaults\", or ID=off and ID=KEYCODE:MODIFIERS entries.")
            return nil
        }
        print("TEST: gestures use SILL_TEST_HOTKEYS=\(raw), not this Mac's keyboard shortcuts.")
        return table
    }

    // MARK: Catalog to clients

    private func listMessage() -> StreamMessage {
        StreamMessage(kind: .windowList, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                      payload: Wire.encode(WindowList(macName: macName, windows: catalog.infos, active: active, launchID: launchID,
                                                      hostVersion: hostVersion, protocol: SillProtocol.current,
                                                      gestures: TrackpadGesture.generation, clipboard: clipboard.advertised)))
    }

    private func broadcastList() { server.broadcast(listMessage()) }

    private func sendCatalog(to connection: NWConnection) {
        let now = Date().timeIntervalSince1970
        print("Catalog → \(connection.endpoint): \(catalog.infos.count) windows, \(catalog.allIcons.count) icons, \(catalog.installedApps.count) apps")
        server.send(listMessage(), to: connection)
        // What the settings are, silently (the line above is the only one printed on connect). An
        // older device skips the kind. Recorded as what this connection was last sent, and only
        // then does it join the publishes: none goes out ahead of its window list, and the catalog
        // keeps its order (2, 16, 18).
        let id = ObjectIdentifier(connection)
        let state = settingsState(for: id)
        server.send(settingsMessage(state), to: connection)
        lastPublished[id] = state
        connections[id] = connection
        // Who this Mac is and how to reach it from afar (kind 18, signed), on both doors, only from
        // a host with an identity. An older device skips it too.
        if let info = remote?.macInfoMessage() { server.send(info, to: connection) }
        for (id, png) in catalog.allIcons {
            server.send(StreamMessage(kind: .appIcon, timestamp: now, isKeyframe: false,
                                      payload: ImageBlob.encodeIcon(bundleID: id, png: png)), to: connection)
        }
        server.send(StreamMessage(kind: .appList, timestamp: now, isKeyframe: false,
                                  payload: Wire.encode(catalog.installedApps)), to: connection)
        if let shape = cursorShapes.current {
            server.send(StreamMessage(kind: .cursorShape, timestamp: now, isKeyframe: false, payload: shape), to: connection)
        }
    }

    // MARK: Settings to devices

    /// The last state each connection was sent: at connect (`sendCatalog`) and by each publish.
    /// Answers never touch it.
    private var lastPublished: [ObjectIdentifier: HostSettingsState] = [:]

    /// Connection `id`'s state (docs/remote-bundle-plan.md §5.4): the pair its controls set (the
    /// away quality for a device away), the home and away qualities with which one is the target
    /// (`away`, from a host with an identity, `remote`: SillHost --pairing alone too, where no
    /// connection is ever away), and the rest shared. A pure function of the target,
    /// `awayWanted`, the connection's route, the status snapshot and two constants (appKitLoop,
    /// whether the hook is set). The target changes only in `setTarget`, the snapshot only in
    /// `HostStatus.update`, and `awayWanted` only in `routesChanged`, which updates the snapshot
    /// with it; all three publish, so no change can be missed and none can stick. Never the
    /// pipeline's `awayRunning`: it changes in `adopt`, which publishes only through a snapshot
    /// change, and none comes while nothing streams.
    private func settingsState(for id: ObjectIdentifier, answering: Int? = nil) -> HostSettingsState {
        let t = target, s = status.snapshot
        let thisAway = routes[id]?.isAway ?? false
        // A report about the bitrate that runs while it is still the target's; one about a bitrate a
        // pick has just replaced is stale (the restart's reset clears it a moment later).
        let link = linkReports[id].flatMap { $0.bitrate == t.effective(away: awayWanted).bitrate ? $0 : nil }
        let away = remote.map { _ in
            AwayQuality(homeBitrate: t.bitrate, homeCaptureScale: Double(t.captureScale),
                        awayBitrate: t.awayBitrate, awayCaptureScale: Double(t.awayCaptureScale),
                        thisConnectionAway: thisAway, awayRunning: awayWanted)
        }
        return HostSettingsState(settings: t.streamSettings(away: thisAway),
                                 persistent: onDeviceSettingsChange != nil,
                                 virtualDisplayAvailable: appKitLoop,
                                 virtualDisplayNote: virtualDisplayNote(target: t, snapshot: s),
                                 softwareEncoder: s.softwareEncoder,
                                 stream: s.stream?.wire,
                                 answering: answering,
                                 away: away,
                                 link: link)
    }

    /// The Mac's Virtual Display pane in its order (SettingsPanes.swift, `statusText`), without the
    /// permission lines: permissions are polled, not event-driven, and a missing one still reaches
    /// the device as the fallback reason on the next pick.
    private func virtualDisplayNote(target t: HostConfig, snapshot s: HostStatusSnapshot) -> String? {
        if !appKitLoop { return "Start SillHost with --virtual-display to use it." }
        if s.virtualDisplayAPIMissing, let p = s.virtualDisplayProblem { return "Not available on this version of macOS: \(p)" }
        guard t.virtualDisplay else { return nil }
        if let p = s.virtualDisplayProblem { return "Off for this session: \(p). Turn it off and on to try again." }
        if let f = s.lastStageFailure { return "The last window streamed where it is: \(f)" }
        return nil
    }

    private func settingsMessage(_ state: HostSettingsState) -> StreamMessage {
        StreamMessage(kind: .hostSettings, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                      payload: Wire.encode(state))
    }

    /// To every device whose catalog went out, its own state, when that differs from the last one
    /// it was sent. Prints nothing, so the CLI's output only changes when a device sends a change.
    private func publishSettings() {
        var messages: [(NWConnection, StreamMessage)] = []
        for (id, connection) in connections {
            let state = settingsState(for: id)
            guard state != lastPublished[id] else { continue }
            lastPublished[id] = state
            messages.append((connection, settingsMessage(state)))
        }
        if !messages.isEmpty { server.send(each: messages) }
    }

    /// "iPad (iPad14,1)" once the device has sent its stats, its address until then.
    private func deviceName(_ connection: NWConnection) -> String {
        status.snapshot.devices.first { $0.id == ObjectIdentifier(connection) }?.name ?? "\(connection.endpoint)"
    }
}

extension ClientRoute {
    /// Away from home: the remote door from a VPN or the internet (AwayPolicy.isAway). Its Quality and
    /// Resolution picks set the away quality, which runs while every connected device is away. Here,
    /// not beside ClientRoute in StreamServer.swift, which the pacing harness compiles without the
    /// coordinator's files.
    var isAway: Bool { AwayPolicy.isAway(remoteDoor: isRemote, origin: origin) }
}
