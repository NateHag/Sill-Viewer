import Foundation
import Network
import StreamProtocol

/// Advertises _sill._tcp over Bonjour and pushes messages to every connected client.
/// Slow clients drop delta frames rather than building a queue (that queue is latency).
///
/// Test only, read once from the environment, never set outside a test and not in the README:
/// `SILL_TEST_SERVICE_TYPE=_silltest._tcp` registers a host that otherwise does not advertise (the
/// `--synthetic` hosts) as "Sill test ‹pid›" under that type, with the listener's own peer-to-peer
/// flag, so a dns-sd browse can check whether the registration includes AWDL while no device (they
/// browse `_sill._tcp` only) ever finds it. `SILL_TEST_SWAP_FAIL=port` makes a Direct Wireless
/// replacement's same-port bind fail as EADDRINUSE without binding, and `=all` its any-port bind
/// too, so the fallback and the listener-failure rule can be exercised without a real conflict.
/// `SILL_TEST_PEER_TO_PEER_INTERFACE=en0` counts a client whose address is scoped to that interface
/// as one on peer-to-peer Wi-Fi, so turning Direct Wireless off disconnects it: a link-local test
/// client on en0 stands in for a device on awdl0, which no test can reach.
/// `SILL_TEST_ORIGIN=vpn|internet` makes loopback sources classify as that origin, so the origin
/// gate can refuse a test client; `SILL_TEST_REMOTE_ORIGIN=vpn|internet` does so at the remote door
/// alone, so one loopback host serves a device away from home (the remote door) beside one at home
/// (the home door, where loopback stays loopback): docs/remote-bundle-plan.md's H8 and S4. `SILL_TEST_MIN_DEVICE_VERSION=1.2` raises the device floor
/// (DeviceGate) from "0", so the gate below runs, and `SILL_TEST_GOODBYE='<JSON>'` makes its
/// refusals send that kind 22 payload instead (a reason this build does not know, for the device's
/// tests). `SILL_TEST_LOOPBACK=1` makes both doors listen on 127.0.0.1 alone, so a test host takes
/// no connection from another machine (the Application Firewall never asks) and `lsof` shows it as
/// `127.0.0.1:PORT`: devices and test clients on this Mac, the simulator included, reach it by
/// 127.0.0.1. All are honoured only on a test host (DoorPolicy.isTestHost: one that does not
/// advertise and is not Sill.app's own executable), so a stray variable can never touch a real host.
///
/// The home door (this listener) admits only loopback, link-local (AWDL included) and this Mac's
/// own networks (OriginPolicy): a refused connection is cancelled with zero bytes from Sill and
/// only counted, one summary line a minute at most. Every client message is capped at
/// `StreamMessage.maxClientPayload`. It speaks one of three ways (`HomeDoorMode`,
/// docs/home-pairing-plan.md §4.5): plain TCP as it always has (the CLI without --pairing), its
/// origin checked at `.ready`; TLS 1.3 with both keys pinned, admitted by `Door(.home)` exactly as
/// the remote door admits (Sill.app, SillHost --pairing), with `p` in its TXT record; or not at all
/// (the identity could not be loaded: fail closed).
///
/// The device gate (DeviceGate, `gate`): with the floor above "0", a ready session on any door is
/// held unregistered until its first message, which must be a hello the floor admits; any other
/// device gets kind 22 "update" and is closed, never registered. At a TLS door (the remote door,
/// and the home door in Sill.app and SillHost --pairing) the hello is the first message inside TLS
/// and the gate runs in its Door once the key is admitted, one place for both doors; the Door then
/// judges again what changed while it was held (DoorPolicy.afterGate: the key removed, Require
/// pairing turned on, Remote Access or internet access off, the session limit; and at home Direct
/// Wireless turned off). The plain home door (the CLI without --pairing) runs it at `.ready`, Direct
/// Wireless's change included. With the floor at "0" (every build that ships so far) nothing
/// waits, and a device's hello is only logged.
///
/// Each TLS door's Door hands its admitted sessions here (`serve`), so every door shares the
/// framing, the catalog and the stream; remote clients get their own eviction (silence, a longer
/// drain backstop) and pacing, by the bytes their connection has not taken (`paceRemote`), because
/// a slow uplink is normal there. A session at a TLS home door is a home client in all of this: the
/// home rule of `broadcast` and the home eviction, as on the plain door.
final class StreamServer {
    private final class Client {
        let connection: NWConnection
        var inflight = 0          // every message still unacknowledged (backpressure for delta drops)
        var inflightFrames = 0    // video frames only
        var oldestUnackedFrameAt: TimeInterval?   // last time a frame was drained, or queued from 0 (dead-peer detection)
        /// When it was admitted (registered), which is when the dead-peer grace starts.
        var connectedAt = Date().timeIntervalSince1970
        var needsKeyframe = true
        var lastStatsPrint = 0.0  // CFAbsoluteTime of the last clientStats line, to rate-limit the log
        /// The worst frame age and rtt reported since that line, -1 for none. The next line prints
        /// them, so a report the rate limit skips still shows its spike. Only newer clients send maxima.
        var worstFrameAgeSincePrint = -1
        var worstRttSincePrint = -1
        /// Which door and from where: `.home(origin, peer:)` decided at `.ready`, or the remote door's.
        var route = ClientRoute.home(.loopback, peer: nil)
        /// The device's own name from its last ClientStats, cleaned (SafeText), for its stats line
        /// and the line that says why it was disconnected; nil until its first report.
        var device: String?
        /// A home client's link (ClientLink.route) as last reported (`onClientConnected`, then
        /// `onClientRouteChanged` on a change): Wired, Wi-Fi, Direct or nil. Read once it is
        /// registered (admitted at `.ready`): a path update before that reports nothing, the device
        /// has no row yet. Always nil for a remote session, whose card names its route instead.
        var link: ClientLink.Route?
        /// The last header received from it (remote clients: silence eviction).
        var lastHeardAt = Date().timeIntervalSince1970
        /// No keyframe has reached it since it was admitted or the stream changed: a remote client's
        /// next one goes out whatever its queue holds, and no client's skipped frames count against
        /// its link meanwhile (LinkJudge: that wait is the connect or a restart, not the link).
        var awaitingFirstKeyframe = true
        /// Remote clients: a frame was dropped for it and a keyframe should be asked for, when
        /// `remoteKeyframeDue` (at most every 2 s across all remote clients, later beside a home one).
        var keyframeWanted = false
        /// When a message was last handed to it (TLS clients skip a tick right after one).
        var lastSentAt: TimeInterval = 0
        /// Its connection is TLS: every remote session, and every home session at a TLS home door.
        var encrypted = false
        /// A TLS home session over the USB cable to an iPhone or iPad (CableLink, read at
        /// registration): no radio to keep awake, so no ticks.
        var onCable = false
        /// Bytes handed to the connection that it has not taken yet (`.contentProcessed`), every
        /// message `inflight` counts: every client's, which its link judge reads (the home branch of
        /// `broadcast` never does); and, remote clients only, the keyframes among them it is still
        /// taking (sequence number and size, oldest first), with their bytes. Usually none or one;
        /// two when a keyframe comes while another is still being taken: a restarted stream's first
        /// (a pick, a rotation, a settings change), or the next one on a link that takes a keyframe
        /// longer than the time between two.
        var pendingBytes = 0
        var keyframesInFlight: [(seq: Int, bytes: Int)] = []
        var keyframeBytesInFlight = 0
        var keyframeSeq = 0
        /// Remote clients: the smallest backlog since the keyframes it was taking were all taken,
        /// which starts at what they left behind them (the frames that queued while they were).
        var backlogFloor = 0
        /// Its link (docs/remote-bundle-plan.md §6): this second's frames sent and withheld (not
        /// those before its first keyframe) and the bytes its connection took, closed by the sweep
        /// each second into the judge.
        var sentThisSecond = 0
        var withheldThisSecond = 0
        var takenThisSecond = 0
        var judge = LinkJudge()
        /// The plain home door's device gate is reading its first message (floor above "0"): not
        /// registered yet. (A TLS door's gate runs in its Door, before the session reaches `serve`.)
        var judging = false
        /// Plain home door: the listener that accepted it included peer-to-peer Wi-Fi (Direct
        /// Wireless on), so it may run over AWDL; the gate checks again as it admits one.
        var acceptedPeerToPeer = false
        /// A hello (kind 23) came on this connection: only the first counts.
        var helloSeen = false
        /// The input messages (kind 8) read from it. Every kind 26 sent to it carries the count, so the
        /// device can drop one the host built before it read that device's latest input
        /// (docs/pointer-visibility-plan.md §3.3).
        var inputsRead = 0
        /// The last kind 26 sent to it; nil also while it drives the pointer, so the next one goes out
        /// whatever it says.
        var lastPointer: MacPointer?
        init(_ c: NWConnection) { connection = c }
    }

    /// The network queue: both doors, their connections, the verify blocks and the timers.
    let queue: DispatchQueue
    private var clients: [ObjectIdentifier: Client] = [:]
    private var lastParameterSets: Data?
    /// A client was admitted (home door at `.ready`, remote door once paired and checked), with
    /// its route (which door, from where) and, for a home client, its link (ClientLink.route; nil
    /// when its connection does not say, and always for a remote session). Called on the network
    /// queue.
    var onClientConnected: ((NWConnection, ClientRoute, ClientLink.Route?) -> Void)?
    /// A connected home client's link changed with its connection's path. Only reported, never
    /// acted on: the menu card shows it. Called on the network queue.
    var onClientRouteChanged: ((NWConnection, ClientLink.Route?) -> Void)?
    /// A message from a client (selectSource, launchApp). Called on the network queue.
    var onMessage: ((StreamMessage, NWConnection) -> Void)?
    /// A client fell behind and lost a delta frame; the encoder should produce a keyframe now
    /// rather than in up to 4 s. Called on the network queue.
    var onKeyframeNeeded: (() -> Void)?
    /// Number of connected clients changed. Called on the network queue. Zero means the host can idle.
    var onClientCountChanged: ((Int) -> Void)?
    /// One connection ended (before `onClientCountChanged`), for per-client state such as its rate.
    var onClientDisconnected: ((NWConnection) -> Void)?
    /// The listener failed. Called on the network queue after "Listener failed: …" is printed.
    /// Unset, the process exits(1) as it always has (the CLI); the menu bar app sets it and keeps
    /// running with the failure in its menu. Set it only before `start()`.
    var onListenerFailed: ((NWError) -> Void)?
    /// Every listener state change (ready, waiting, failed…). Called on the network queue.
    var onListenerState: ((NWListener.State) -> Void)?
    /// The name Bonjour actually registered, which differs from the Mac's name after a clash
    /// ("… (2)"); nil when that registration went away. Called on the network queue.
    var onServiceRegistered: ((String?) -> Void)?
    /// Every ClientStats report, about once a second per device (the log prints every other one).
    /// Called on the network queue.
    var onClientStats: ((NWConnection, ClientStats) -> Void)?
    /// A device's hello (kind 23), the first of its connection, once it is registered. Called on the
    /// network queue.
    var onClientHello: ((NWConnection, Hello) -> Void)?
    /// A device's link changed (LinkJudge, docs/remote-bundle-plan.md §6): behind, stalled, fine again,
    /// fine because the stream restarted at another quality (`reset`), or the same state once its
    /// carried rate is first measured. Called on the network queue, from the once-a-second sweep and
    /// `resetLinks`.
    var onClientLinkChanged: ((NWConnection, LinkJudge.Verdict) -> Void)?
    /// The Mac's pointer (PointerWatch): who moves it, sampled at each tick and, while it moves over
    /// the source and a device is sent it, at the stream's frame rate; every device that is not
    /// moving it is sent where it is (kind 26). Set before `start()`.
    var pointerWatch: PointerWatch?

    /// The oldest device version served (DeviceGate): the shipped "0" admits every device and
    /// nothing waits for a hello. TEST ONLY: SILL_TEST_MIN_DEVICE_VERSION on a host that does not
    /// advertise.
    let deviceFloor: SillVersion
    /// The Mac's name, for the update goodbye's message. Set by the coordinator before `start()`.
    var macName = "Mac"
    /// TEST ONLY: SILL_TEST_GOODBYE's payload, sent by a refusal instead of the update goodbye.
    private let testGoodbye: Data?

    // MARK: Link keepalive
    //
    // Measured 2026-09-22: with nothing streaming, the iPad's ping round trip climbs 5 → 100 → 200 →
    // 300 ms in a sawtooth every few seconds while a simulator on the same Mac stays at 0 ms. That is
    // the device's Wi-Fi radio dozing whenever the downlink goes quiet; every next packet waits for a
    // wake window. During a steady video stream it never happens. A trackpad stroke over a static
    // window starts from a quiet link, so its first frames arrive 100–300 ms late and then bunch up:
    // the stutter. While a session is live we keep the downlink lightly busy with an empty 14-byte
    // tick every 30 ms (~0.5 KB/s). "Live" = the coordinator says a source is streaming, or a client
    // sent input in the last 3 s. Idle sessions tick nothing and let the radio sleep.
    //
    // The tick also samples the Mac's pointer (PointerWatch) and sends where it is (kind 26) to every
    // device that is not moving it, when that changed; a kind 26 stands in for that device's tick.
    // While the pointer moves over the source and a device is sent it, the frame-rate sampler
    // samples it at the stream's rate instead (docs/pointer-visibility-plan.md Q4, decided
    // 2026-09-26), so the device draws it as smoothly as the picture, and the tick only keeps the
    // link awake; at 33 fps and below the tick samples as often, and no sampler runs
    // (PointerWatch.samplerInterval). Without a geometry (nothing streams, or a synthetic host
    // without its scripted pointer) nothing is read.
    private var tickTimer: DispatchSourceTimer?
    private var lastInputAt: TimeInterval = 0
    private var streaming = false
    private static let tickInterval = 0.030
    private static let inputRecency = 3.0

    /// The coordinator flips this with the active source. Thread-safe.
    func setStreaming(_ on: Bool) {
        queue.async { [self] in streaming = on; updateTicking() }
    }

    /// On the network queue.
    private func updateTicking() {
        let wanted = !clients.isEmpty && (streaming || Date().timeIntervalSince1970 - lastInputAt < Self.inputRecency)
        if wanted, tickTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            tickTimer = t
        } else if !wanted, let t = tickTimer {
            t.cancel(); tickTimer = nil
            setPointerSampler(interval: nil)
        }
    }

    /// On the network queue. Re-evaluates the recency rule so the timer stops itself after a quiet spell.
    private func tick() {
        let live = streaming || Date().timeIntervalSince1970 - lastInputAt < Self.inputRecency
        guard live, !clients.isEmpty else { updateTicking(); return }
        let now = Date().timeIntervalSince1970
        // The Mac's pointer, unless the frame-rate sampler has it while it moves.
        let reported = pointerSampler == nil ? samplePointer(now: now) : []
        let data = StreamMessage(kind: .tick, timestamp: now, isKeyframe: false, payload: Data()).serialized()
        for (id, client) in clients where client.connection.state == .ready {
            // A kind 26 just sent keeps its link awake this turn.
            if reported.contains(id) { continue }
            // Over TLS every record costs CPU (the remote plan's H20): skip a tick right after
            // anything else went out. The link is busy anyway, so the device's radio stays awake
            // exactly as before. The plain door keeps every tick.
            if client.encrypted, now - client.lastSentAt < Self.tickInterval { continue }
            // The USB cable has no radio to keep awake.
            if client.encrypted, client.onCable { continue }
            client.connection.send(content: data, completion: .contentProcessed { _ in })   // not counted as inflight
        }
        Stats.shared.bump("net.tick")
    }

    // MARK: The Mac's pointer (kind 26)

    /// The frame-rate sampler: while the pointer moves over the source and a device is sent it, the
    /// pointer is sampled every frame interval of the stream instead of at the tick, when that is
    /// more often (PointerWatch.samplerInterval). On `queue`.
    private var pointerSampler: DispatchSourceTimer?
    private var pointerSamplerInterval = 0.0

    /// On `queue`: one sample of the Mac's pointer, and to every ready device that is not moving it a
    /// kind 26 when its report differs from the last one it was sent: at most one a sample, only on
    /// a change, sent as the tick is (not counted in `inflight`, so it can never make a slow link
    /// drop frames). A device that moves it is sent nothing and its last report is forgotten, so
    /// the next one goes out once it stops. Starts the frame-rate sampler while the pointer moves
    /// over the source and a device is sent it, faster than the tick, and stops it otherwise
    /// (PointerWatch.samplerInterval). Returns the devices sent one.
    @discardableResult
    private func samplePointer(now: TimeInterval) -> Set<ObjectIdentifier> {
        let ready = clients.compactMap { $0.value.connection.state == .ready ? $0.key : nil }
        guard let watch = pointerWatch, let reading = watch.sample(devices: ready) else {
            setPointerSampler(interval: nil)
            return []
        }
        var sent = Set<ObjectIdentifier>()
        var watched = false
        for (id, client) in clients where client.connection.state == .ready {
            guard let report = reading.report(for: id, seen: client.inputsRead) else {
                client.lastPointer = nil
                continue
            }
            watched = true
            guard report != client.lastPointer else { continue }
            client.lastPointer = report
            let data = StreamMessage(kind: .macPointer, timestamp: now, isKeyframe: false, payload: Wire.encode(report)).serialized()
            client.connection.send(content: data, completion: .contentProcessed { _ in })   // not counted as inflight
            client.lastSentAt = now
            Stats.shared.bump("ptr.sent")
            sent.insert(id)
        }
        let every = PointerWatch.samplerInterval(moving: reading.moving, inside: reading.inside, watched: watched,
                                                 frameInterval: watch.frameInterval, tickInterval: Self.tickInterval)
        setPointerSampler(interval: every)
        return sent
    }

    /// On `queue`: runs the frame-rate sampler every `interval` seconds, or stops it (nil). A new
    /// interval (the stream restarted at another rate) restarts it.
    private func setPointerSampler(interval: Double?) {
        guard let interval else {
            pointerSampler?.cancel()
            pointerSampler = nil
            return
        }
        if pointerSampler != nil, pointerSamplerInterval == interval { return }
        pointerSampler?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, self.tickTimer != nil, !self.clients.isEmpty else { self?.setPointerSampler(interval: nil); return }
            self.samplePointer(now: Date().timeIntervalSince1970)
        }
        t.resume()
        pointerSampler = t
        pointerSamplerInterval = interval
    }

    // MARK: The listener, and Direct Wireless (peer-to-peer Wi-Fi)
    //
    // includePeerToPeer on the listener makes its Bonjour registration include AWDL, which is what
    // turns the Mac's AWDL on: the kernel counts that registration as an AWDL service ("Enabling AWDL
    // due to Mdns"); a peer-to-peer listener without a service counts as none. Off by default (Direct
    // Wireless Connection, HostConfig): AWDL takes the Mac's one radio off its Wi-Fi channel up to
    // ~97 ms every 524 ms, and on a shared network it carries none of Sill's data.
    //
    // NWListener fixes its parameters at creation, so a change replaces the listener. Measured
    // 2026-09-24: connections the old listener accepted are independent of it and keep streaming;
    // `.cancelled` follows `cancel()` within 2 ms, and a new listener binds the same port right after
    // it even while accepted connections hold the port (binding before it fails with EADDRINUSE);
    // re-registering the same name within milliseconds of dropping an AWDL registration orphaned the
    // awdl0 record for minutes (5 of 5), while 0.25 s and more removed it cleanly (6 of 6). So:
    // cancel, wait for `.cancelled`, bind the same port at once without a service (a device
    // connecting in those milliseconds is refused and retries), and advertise `advertiseDelay` later.
    // The only connections a change ends: once a replacement with it off is advertised, those of
    // the devices still on peer-to-peer Wi-Fi (`disconnectPeerToPeerClients`).
    //
    // From `start()` on, the listener's whole life is the network queue's: its creation, start,
    // handlers and replacement, and `readyPort`, which the main actor reads through `portLock`.

    /// How the home door speaks (docs/home-pairing-plan.md §4.5).
    enum HomeDoorMode {
        /// Plain TCP, byte for byte as before: the CLI without --pairing.
        case plain
        /// TLS 1.3, both keys pinned, admission by `Door(.home)`: Sill.app, SillHost --pairing.
        case tls(HomeTLS)
        /// No listener at all (the identity could not be loaded: fail closed); why, for the log.
        case closed(String)
    }
    /// What a TLS home door needs: the Mac's identity and the trust list's snapshot, both the
    /// remote door's (one identity, one trust list).
    struct HomeTLS {
        let identity: HostIdentity
        let trust: TrustBox
    }
    let homeMode: HomeDoorMode
    /// The TLS home door's admission; nil for a plain or closed one. RemoteAccess wires its outputs.
    let homeDoor: Door?
    /// The home door speaks TLS: its TXT record carries `p`, and kind 21 comes only from an
    /// unpaired session.
    var homeTLS: Bool { homeDoor != nil }

    private var listener: NWListener                 // replaced whole, never reconfigured
    /// The Mac's name and `_sill._tcp`, a test registration (SILL_TEST_SERVICE_TYPE), or nil (the
    /// synthetic hosts, which devices must never find).
    private let serviceNameAndType: (name: String, type: String)?
    /// The TXT record for each registration (a host with an identity: a fresh recognition tag each
    /// time, RecognitionTag); nil registers none, as before. Set before `start()`; called on the
    /// network queue.
    var txtRecord: (() -> NWTXTRecord?)?
    /// The service to attach: built anew at init, in `start()` and after a Direct Wireless
    /// replacement, so every registration carries a fresh tag. On `queue` (or before `start()`).
    private func makeService() -> NWListener.Service? {
        guard let s = serviceNameAndType else { return nil }
        if let txt = txtRecord?() { return NWListener.Service(name: s.name, type: s.type, domain: nil, txtRecord: txt) }
        return NWListener.Service(name: s.name, type: s.type)
    }
    /// A test registration is announced once in the log and never reaches `onServiceRegistered`.
    private let serviceIsTest: Bool
    /// A test host (DoorPolicy.isTestHost: it does not advertise and is not Sill.app's own
    /// executable): the only kind the TEST ONLY hooks touch.
    private let testHost: Bool
    private var peerToPeer = false                   // what `listener` was built with
    private var wantedPeerToPeer = false             // the newest request
    /// A replacement under way, numbered so a late callback or timer of an earlier one is a no-op:
    /// the old listener cancelling, then the new one bound and waiting to be advertised.
    private enum Swap: Equatable { case idle, cancelling(Int), settling(Int) }
    private var swap = Swap.idle
    private var swapCount = 0
    private var replacementPort: NWEndpoint.Port?    // the port the current replacement tried; nil = any port
    private var started = false
    private let portLock = NSLock()                  // `port` is read on the main actor
    private var readyPort: UInt16?
    /// 6× the shortest clean pause measured, and past the ~1 s the old record's removal takes to show.
    private static let advertiseDelay: TimeInterval = 1.5
    /// `.cancelled` came within 2 ms in every measurement; without it the replacement takes any port.
    private static let cancelTimeout: TimeInterval = 1.0

    /// `advertise: false` keeps the host off Bonjour (the synthetic test mode), unless a test asks
    /// for its test registration (SILL_TEST_SERVICE_TYPE, above). `home`: how the home door speaks.
    /// `testHooks`: false for Sill.app's own executable, which honours no TEST ONLY hook that bears
    /// on who gets in (docs/home-pairing-plan.md §4.3).
    init(serviceType: String = "_sill._tcp", advertise: Bool = true, home: HomeDoorMode = .plain, testHooks: Bool = true) throws {
        let queue = DispatchQueue(label: "sill.net", qos: .userInteractive)
        self.queue = queue
        let test = DoorPolicy.isTestHost(advertises: advertise, bundled: !testHooks)
        // The synthetic test host does not advertise: a device would otherwise find it, connect,
        // and show the test pattern (Noah saw "a white moving wall", 2026-09-23). Test clients
        // connect to it by port.
        if advertise {
            serviceNameAndType = (Host.current().localizedName ?? "Mac", serviceType)
            serviceIsTest = false
        } else if test, let type = Self.testServiceType {
            serviceNameAndType = ("Sill test \(getpid())", type)
            serviceIsTest = true
        } else {
            serviceNameAndType = nil
            serviceIsTest = false
        }
        testHost = test
        (deviceFloor, testGoodbye) = Self.gateSettings(testHost: test)
        homeMode = home
        var door: Door?
        if case .tls(let t) = home { door = Door(.home, queue: queue, identity: t.identity, trust: t.trust, testHost: test) }
        homeDoor = door
        // TEST ONLY: SILL_TEST_LOOPBACK, on a test host alone (anywhere else TestHooks says it is ignored).
        if test, Self.testLoopback { print("Test listener: loopback only (SILL_TEST_LOOPBACK); reach this host at 127.0.0.1.") }
        listener = try Self.makeListener(peerToPeer: false, port: nil, tls: door?.tlsOptions(), loopback: test && Self.testLoopback)
        listener.service = makeService()
        wire(listener)
        door?.server = self
    }

    /// TEST ONLY: SILL_TEST_SERVICE_TYPE (see the type's doc comment). Read once. Only a
    /// `_name._tcp` other than Sill's own is taken, so a device can never find a test host; anything
    /// else is ignored with one line.
    private static let testServiceType: String? = {
        guard let type = ProcessInfo.processInfo.environment["SILL_TEST_SERVICE_TYPE"], !type.isEmpty else { return nil }
        let name = type.hasPrefix("_") && type.hasSuffix("._tcp") ? type.dropFirst().dropLast(5) : ""
        let valid = (1...15).contains(name.count) && type != "_sill._tcp"
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        if !valid { print("SILL_TEST_SERVICE_TYPE=\(type) ignored: a test type is _name._tcp, and never _sill._tcp.") }
        return valid ? type : nil
    }()

    /// The device floor, and a test goodbye: DeviceGate's constant, except on a test host where
    /// SILL_TEST_MIN_DEVICE_VERSION replaces it and SILL_TEST_GOODBYE (a JSON Goodbye, sent as
    /// written) replaces the refusal's payload. A value that does not parse is ignored with one line.
    /// Neither is read on any other host (one that advertises, or Sill.app's own executable), which
    /// says so once (TestHooks).
    private static func gateSettings(testHost: Bool) -> (SillVersion, Data?) {
        guard testHost else { return (DeviceGate.floor, nil) }
        let env = ProcessInfo.processInfo.environment
        var floor = DeviceGate.floor
        if let raw = env["SILL_TEST_MIN_DEVICE_VERSION"], !raw.isEmpty {
            if let v = SillVersion(raw) { floor = v } else { print("SILL_TEST_MIN_DEVICE_VERSION=\(raw) ignored: not a version.") }
        }
        var goodbye: Data?
        if let raw = env["SILL_TEST_GOODBYE"], !raw.isEmpty {
            if Wire.decode(Goodbye.self, from: Data(raw.utf8)) != nil { goodbye = Data(raw.utf8) } else { print("SILL_TEST_GOODBYE ignored: not a Goodbye.") }
        }
        return (floor, goodbye)
    }

    /// TEST ONLY: SILL_TEST_LOOPBACK (see the type's doc comment). Read once; "1", anything else
    /// ignored with one line. Honoured only by a test host (`loopbackOnly`).
    static let testLoopback: Bool = {
        guard let value = ProcessInfo.processInfo.environment["SILL_TEST_LOOPBACK"], !value.isEmpty else { return false }
        guard value == "1" else {
            print("SILL_TEST_LOOPBACK=\(value) ignored: 1 turns it on.")
            return false
        }
        return true
    }()

    /// Both doors listen on 127.0.0.1 alone: a test host with SILL_TEST_LOOPBACK=1.
    var loopbackOnly: Bool { testHost && Self.testLoopback }

    /// TEST ONLY: SILL_TEST_SWAP_FAIL (see the type's doc comment). Read once; "port" or "all".
    private static let testSwapFail: String? = ProcessInfo.processInfo.environment["SILL_TEST_SWAP_FAIL"]

    /// TEST ONLY: SILL_TEST_PEER_TO_PEER_INTERFACE (see the type's doc comment). Read once, and only
    /// by a host that does not advertise; an interface name (a letter, then letters or digits),
    /// anything else ignored with one line.
    private static let testPeerToPeerInterface: String? = {
        guard let name = ProcessInfo.processInfo.environment["SILL_TEST_PEER_TO_PEER_INTERFACE"], !name.isEmpty else { return nil }
        let valid = name.count <= 15 && name.first!.isLetter && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if !valid { print("SILL_TEST_PEER_TO_PEER_INTERFACE=\(name) ignored: an interface name such as en0.") }
        return valid ? name : nil
    }()

    /// TEST ONLY: SILL_TEST_ORIGIN (see the type's doc comment). Read once, and only by a host that
    /// does not advertise; "vpn" or "internet", anything else ignored with one line.
    static let testOrigin: OriginPolicy.Origin? = {
        guard let value = ProcessInfo.processInfo.environment["SILL_TEST_ORIGIN"], !value.isEmpty else { return nil }
        guard value == "vpn" || value == "internet" else {
            print("SILL_TEST_ORIGIN=\(value) ignored: vpn or internet.")
            return nil
        }
        return OriginPolicy.Origin(rawValue: value)
    }()

    /// TEST ONLY: SILL_TEST_REMOTE_ORIGIN (see the type's doc comment), SILL_TEST_ORIGIN's twin for
    /// the remote door alone. Read once, and only by a host that does not advertise.
    static let testRemoteOrigin: OriginPolicy.Origin? = {
        guard let value = ProcessInfo.processInfo.environment["SILL_TEST_REMOTE_ORIGIN"], !value.isEmpty else { return nil }
        guard value == "vpn" || value == "internet" else {
            print("SILL_TEST_REMOTE_ORIGIN=\(value) ignored: vpn or internet.")
            return nil
        }
        return OriginPolicy.Origin(rawValue: value)
    }()

    /// Where `c` comes from: its endpoint's address (and the interface a link-local one is scoped
    /// to), the local address it arrived at (`currentPath.localEndpoint`, which names the
    /// interface through `InterfaceSnapshot`; `availableInterfaces` listed en0 and lo0 for one
    /// loopback connection, so it is not used), classified by OriginPolicy. On a test host,
    /// SILL_TEST_ORIGIN turns a loopback source into that origin (and SILL_TEST_REMOTE_ORIGIN, at the
    /// remote door: `remoteDoor`). On `queue`, at `.preparing` or later (the path exists from then on).
    func origin(of c: NWConnection) -> OriginPolicy.Origin { arrival(of: c).origin }

    /// `origin(of:)` with the interface it arrived on (the scope, else the owner of the local
    /// address), which names a VPN route ("through Tailscale").
    func arrival(of c: NWConnection, remoteDoor: Bool = false) -> (origin: OriginPolicy.Origin, interface: String?) {
        guard case .hostPort(let host, _) = c.endpoint else { return (.internet, nil) }
        let (remote, scope) = Self.addressText(host)
        return arrival(remote: remote, scope: scope ?? OriginPolicy.scope(ofEndpoint: "\(c.endpoint)"), local: Self.pathLocal(c),
                       remoteDoor: remoteDoor)
    }

    /// The same before `c` starts: the remote door's check, because a started TLS connection
    /// answers a ClientHello that is already waiting with the whole server flight, the Mac's
    /// certificate included, before any state callback runs (review, 2026-09-24: refused hellos
    /// got about 660 bytes back while the check waited for `.preparing`). An accepted connection
    /// has its path already in `newConnectionHandler` (measured on loopback the same day); should
    /// one not, the local address is the one the kernel's route back to the peer sends from. Nil
    /// when neither is known: `.preparing` judges it then, as before.
    func arrivalBeforeStart(of c: NWConnection, remoteDoor: Bool = false) -> (origin: OriginPolicy.Origin, interface: String?)? {
        guard case .hostPort(let host, _) = c.endpoint else { return (.internet, nil) }
        let (remote, endpointScope) = Self.addressText(host)
        let scope = endpointScope ?? OriginPolicy.scope(ofEndpoint: "\(c.endpoint)")
        var local = Self.pathLocal(c)
        if local == nil, scope == nil, let source = IPBytes.parse(remote), !IPBytes.isLoopback(source) {
            guard let routed = InterfaceSnapshot.routeSource(to: source) else { return nil }
            local = IPBytes.text(routed)
        }
        return arrival(remote: remote, scope: scope, local: local, remoteDoor: remoteDoor)
    }

    /// The local address of `c`'s path, where it arrived; nil while it has no path.
    private static func pathLocal(_ c: NWConnection) -> String? {
        guard case .hostPort(let host, _)? = c.currentPath?.localEndpoint else { return nil }
        return addressText(host).text
    }

    private func arrival(remote: String, scope: String?, local: String?, remoteDoor: Bool) -> (origin: OriginPolicy.Origin, interface: String?) {
        let interfaces = InterfaceSnapshot.shared.interfaces()
        var o = OriginPolicy.classify(remote: remote, localAddress: local, scope: scope, interfaces: interfaces)
        if testHost, o == .loopback, let t = (remoteDoor ? Self.testRemoteOrigin : nil) ?? Self.testOrigin { o = t }
        return (o, OriginPolicy.arrivalInterface(localAddress: local, scope: scope, interfaces: interfaces))
    }

    /// A test host (it does not advertise): the only kind that honours TEST ONLY variables.
    var isTestHost: Bool { testHost }

    /// An endpoint host as an address string without its zone, and the interface a scoped
    /// (link-local) IPv6 address names.
    static func addressText(_ host: NWEndpoint.Host) -> (text: String, scope: String?) {
        switch host {
        case .ipv4(let a): return (IPBytes.text([UInt8](a.rawValue)), a.interface?.name)
        case .ipv6(let a): return (IPBytes.text([UInt8](a.rawValue)), a.interface?.name)
        case .name(let n, let i): return (n, i?.name)
        @unknown default: return ("\(host)", nil)
        }
    }

    /// Home door refusals, reported at most once a minute.
    private lazy var homeRefusals = RefusalSummary(queue: queue, categories: ["vpn", "internet"]) { c in
        let n = c["vpn", default: 0] + c["internet", default: 0]
        return "Home listener refused \(n) connection\(n == 1 ? "" : "s") in the last minute (\(c["vpn", default: 0]) through a VPN, "
            + "\(c["internet", default: 0]) from the internet): only this Mac's own networks reach it."
    }

    /// A listener with Sill's TCP options and service class, peer-to-peer or not, on `port` when
    /// given (a replacement keeps the port that test clients and resolved devices know), speaking
    /// TLS when `tls` is given (a TLS home door: the Door's options with its verify block), plain
    /// TCP otherwise, exactly as before; on 127.0.0.1 alone with `loopback` (a test host's
    /// SILL_TEST_LOOPBACK).
    private static func makeListener(peerToPeer: Bool, port: NWEndpoint.Port?, tls: NWProtocolTLS.Options?,
                                     loopback: Bool) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // A client that vanishes without closing (app killed, Wi-Fi gone) would otherwise stay
        // "ready" until TCP gives up minutes later, eating a keyframe per drop. Probe it instead.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params: NWParameters
        if let tls {
            // The remote door's TLS over the home door's own TCP (no connectionDropTime: home
            // clients keep their 4 s drain rule), the same service class and peer-to-peer flag.
            params = RemoteTLS.parameters(tls: tls, tcp: tcp, peerToPeer: peerToPeer)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
            params.serviceClass = .interactiveVideo   // WMM video class on Wi-Fi: shorter queues, higher priority
            params.includePeerToPeer = peerToPeer     // Direct Wireless Connection only (see the MARK above)
        }
        if loopback { Self.bindToLoopback(params, port: port); return try NWListener(using: params) }
        if let port { return try NWListener(using: params, on: port) }
        return try NWListener(using: params)
    }

    /// The same, in this door's mode: a replacement speaks as the listener it replaces, on 127.0.0.1
    /// alone when that one was (SILL_TEST_LOOPBACK).
    private func makeListener(peerToPeer: Bool, port: NWEndpoint.Port?) throws -> NWListener {
        try Self.makeListener(peerToPeer: peerToPeer, port: port, tls: homeDoor?.tlsOptions(), loopback: loopbackOnly)
    }

    /// TEST ONLY (SILL_TEST_LOOPBACK): `params` accept only on the loopback interface, bound to
    /// 127.0.0.1 on `port` (any when nil). Both doors' listeners.
    static func bindToLoopback(_ params: NWParameters, port: NWEndpoint.Port?) {
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port ?? .any)
    }

    /// The listener's handlers. Each first checks that `l` is still the listener, so the callbacks
    /// of one that has been replaced change nothing.
    private func wire(_ l: NWListener) {
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, l === self.listener else { return }
            switch state {
            case .ready:
                portLock.lock(); readyPort = l.port?.rawValue; portLock.unlock()
            case .failed(let e):
                if case .settling(let n) = swap {
                    // A replacement failed after binding: its own fallback (another port, else the
                    // rule below), reported from there.
                    l.cancel()
                    replacementFailed(e, swap: n)
                    return
                }
                print("Listener failed: \(e)")
                guard let handler = onListenerFailed else { exit(1) }   // the CLI, as always
                handler(e)
            default:
                break
            }
            onListenerState?(state)
        }
        l.serviceRegistrationUpdateHandler = { [weak self, weak l] change in
            guard let self, let l, l === self.listener else { return }
            if serviceIsTest {
                // TEST ONLY: one line a test can read, from the listener's own parameters. Never
                // forwarded, so the app keeps its "Test Pattern Mode … port N" status.
                if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint {
                    let p2p = l.parameters.includePeerToPeer ? "on" : "off"
                    print("Test service registered as \"\(name)\" (\(serviceNameAndType?.type ?? "?"), peer-to-peer \(p2p)); no device browses this type.")
                }
                return
            }
            if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint {
                onServiceRegistered?(name)
            } else if case .remove = change {
                onServiceRegistered?(nil)
            }
        }
        // A connection no longer depends on the listener that accepted it, so it is served
        // whichever listener it came from.
        let acceptsPeerToPeer = l.parameters.includePeerToPeer
        l.newConnectionHandler = { [weak self] c in self?.accept(c, peerToPeer: acceptsPeerToPeer) }
    }

    /// Direct Wireless Connection, from the coordinator. Before `start()` the listener is built with
    /// it; after, the listener is replaced (see the MARK above). Thread-safe; returns at once.
    /// Requests during a replacement coalesce, and the newest wins.
    func setPeerToPeer(_ on: Bool) {
        queue.async { [self] in
            wantedPeerToPeer = on
            if started { beginSwap() }
        }
    }

    /// On `queue`. Starts replacing the listener when the wanted flag differs from the one it was
    /// built with, unless a replacement is under way: that one looks again when it settles.
    private func beginSwap() {
        guard started, swap == .idle, wantedPeerToPeer != peerToPeer else { return }
        swapCount += 1
        let n = swapCount
        swap = .cancelling(n)
        let old = listener
        let oldPort = old.port   // nil for a listener that failed or was never ready: any port then
        // Its registration ending is not the Mac leaving: the status keeps the name through the
        // replacement, whose own registration brings it back.
        old.serviceRegistrationUpdateHandler = nil
        old.stateUpdateHandler = { [weak self] state in
            guard let self, case .cancelled = state, swap == .cancelling(n) else { return }
            bindReplacement(on: oldPort, swap: n)
        }
        old.cancel()
        queue.asyncAfter(deadline: .now() + Self.cancelTimeout) { [weak self] in
            guard let self, swap == .cancelling(n) else { return }
            bindReplacement(on: nil, swap: n)   // no `.cancelled`: the old socket may still hold the port
        }
    }

    /// On `queue`, once the old listener is gone (or said nothing for `cancelTimeout`): binds the
    /// replacement at once, on `port` when given, with the newest wanted flag and no service. It is
    /// advertised `advertiseDelay` later (`settled`).
    private func bindReplacement(on port: NWEndpoint.Port?, swap n: Int) {
        swap = .settling(n)
        replacementPort = port
        // TEST ONLY: the fallbacks without a real port conflict (SILL_TEST_SWAP_FAIL).
        if testHost, Self.testSwapFail == "all" || (Self.testSwapFail == "port" && port != nil) {
            replacementFailed(.posix(.EADDRINUSE), swap: n)
            return
        }
        let l: NWListener
        do {
            l = try makeListener(peerToPeer: wantedPeerToPeer, port: port)
        } catch {
            replacementFailed(error as? NWError ?? .posix(.EINVAL), swap: n)
            return
        }
        wire(l)
        listener = l
        peerToPeer = wantedPeerToPeer
        l.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.advertiseDelay) { [weak self, weak l] in
            guard let self, let l else { return }
            settled(l, swap: n)
        }
    }

    /// On `queue`, `advertiseDelay` after the replacement was bound: advertise it, or, when the
    /// setting moved again meanwhile, replace it once more (it was never advertised, so the last
    /// registration dropped is already that old). A retry or a newer replacement makes it a no-op.
    /// Settled off, it disconnects the devices still on peer-to-peer Wi-Fi; a burst that ends on,
    /// where it started, never gets here with off and disconnects nobody.
    private func settled(_ l: NWListener, swap n: Int) {
        guard swap == .settling(n), l === listener else { return }
        swap = .idle
        if wantedPeerToPeer != peerToPeer { beginSwap(); return }
        l.service = makeService()
        let at = l.port.map { " on port \($0.rawValue)" } ?? ""
        print("Direct wireless \(peerToPeer ? "on" : "off"): listening\(at) again" + (serviceNameAndType == nil ? "." : ", advertised again."))
        if !peerToPeer { disconnectPeerToPeerClients() }
    }

    /// On `queue`, once the listener runs without peer-to-peer: disconnects every client that still
    /// reaches the Mac over peer-to-peer Wi-Fi, one line each. Such a connection outlives the
    /// listener that accepted it (see the MARK above), and while one is open the kernel keeps AWDL
    /// up: on 2026-09-24 the iPad stayed connected over awdl0 after Direct Wireless was turned off,
    /// twice, with the stream as slow as before and no "Disabling AWDL" from the kernel, so the
    /// setting changed nothing anyone could see. The replacement refuses peer-to-peer, so a device
    /// that shares a network with the Mac comes back over it (the kernel then drops AWDL about half
    /// a minute later, as it did when no socket held it); one that shares none cannot, which is
    /// what off means. Clients on any other interface are untouched, and so is every remote
    /// session: the remote door never listens on peer-to-peer Wi-Fi (RemoteTLS), and who reaches it
    /// is Remote Access's to say, not Direct Wireless's. A home connection the device gate still
    /// reads (the floor above "0") is not a client yet: it is judged the same way as the gate admits
    /// it (`droppedForDirectWireless`, from the plain door's `accept` or the TLS home door's Door).
    private func disconnectPeerToPeerClients() {
        // An ask or a proof in flight over peer-to-peer Wi-Fi goes too (a TLS home door).
        homeDoor?.cancelPending { runsPeerToPeer($0) }
        for client in clients.values where !client.route.isRemote && runsPeerToPeer(client.connection) {
            disconnectOverPeerToPeer(client.connection, device: client.device)
        }
    }

    /// One line, then the close: a client's state handler then prints "Client left" and forgets
    /// it; a connection the gate held was never registered and prints nothing more. On `queue`.
    private func disconnectOverPeerToPeer(_ c: NWConnection, device: String?) {
        let endpoint = "\(c.endpoint)"
        let who = device.map { "\($0) at \(endpoint)" } ?? endpoint
        print("Direct wireless off: disconnecting \(who), which was connected over peer-to-peer Wi-Fi; it can reconnect over the network.")
        c.cancel()
    }

    /// Direct Wireless turned off while the device gate read this home connection's hello (up to
    /// 2 s): the replacement, once advertised, disconnected the clients on peer-to-peer Wi-Fi without
    /// it, so it goes now, as it would have gone then (its line, the close), and true. False when it
    /// may be admitted. `acceptedPeerToPeer`: the listener that accepted it included peer-to-peer
    /// Wi-Fi. At either kind of home door (the plain one's `accept`, a TLS one's Door). On `queue`.
    func droppedForDirectWireless(_ c: NWConnection, acceptedPeerToPeer: Bool, hello: Hello) -> Bool {
        guard acceptedPeerToPeer, swap == .idle, !peerToPeer, runsPeerToPeer(c) else { return false }
        let name = SafeText.label(hello.device ?? "")
        disconnectOverPeerToPeer(c, device: name.isEmpty ? nil : name)
        return true
    }

    /// Whether a client reaches this Mac over peer-to-peer Wi-Fi (ClientLink), with the TEST ONLY
    /// stand-in interface counted as such on a host that does not advertise. On `queue`.
    private func runsPeerToPeer(_ c: NWConnection) -> Bool {
        ClientLink.runsPeerToPeer(endpoint: "\(c.endpoint)",
                                  pathInterfaces: c.currentPath?.availableInterfaces.map(\.name) ?? [],
                                  peerToPeer: peerToPeerRule)
    }

    /// A home client's link (ClientLink.route) over `path`: the interface its address is scoped to,
    /// as the address itself types it, then the path's interfaces. The same stand-in counts as
    /// peer-to-peer, so a test client this host would disconnect is shown as Direct. On `queue`.
    private func link(_ c: NWConnection, path: NWPath?) -> ClientLink.Route? {
        var interfaces: [NWInterface] = []
        if case .hostPort(let host, _) = c.endpoint, case .ipv6(let address) = host, let scoped = address.interface {
            interfaces.append(scoped)
        }
        interfaces += path?.availableInterfaces ?? []
        return ClientLink.route(endpoint: "\(c.endpoint)", interfaces: interfaces.map(Self.linkInterface),
                                peerToPeer: peerToPeerRule)
    }

    /// ClientLink's peer-to-peer rule, with the TEST ONLY stand-in interface on a host that does not
    /// advertise.
    private var peerToPeerRule: (String) -> Bool {
        let standIn = testHost ? Self.testPeerToPeerInterface : nil
        return { ClientLink.isPeerToPeer(interface: $0) || $0 == standIn }
    }

    /// An interface as ClientLink spells it, case for case.
    private static func linkInterface(_ interface: NWInterface) -> ClientLink.Interface {
        let type: ClientLink.Interface.Kind
        switch interface.type {
        case .wifi: type = .wifi
        case .wiredEthernet: type = .wiredEthernet
        case .cellular: type = .cellular
        case .loopback: type = .loopback
        case .other: type = .other
        @unknown default: type = .other   // a type newer than this code: no word rather than a wrong one
        }
        return ClientLink.Interface(name: interface.name, type: type)
    }

    /// On `queue`: a replacement could not be bound, or failed once bound. Refused on its old port,
    /// it takes any port. Refused there too, the listener has failed and the existing rule applies
    /// (the app shows it and keeps running; the CLI exits). It never goes back to the old flag: the
    /// listener runs what the setting says, or has visibly failed. `peerToPeer` takes the wanted
    /// value, so the next change either way replaces the dead listener: a toggle is also a retry.
    /// Failed while turning it off, the devices on peer-to-peer Wi-Fi are still disconnected (the
    /// app keeps running): off means no AWDL, listener or not.
    private func replacementFailed(_ e: NWError, swap n: Int) {
        guard swap == .settling(n) else { return }
        if let port = replacementPort {
            print("Direct wireless \(wantedPeerToPeer ? "on" : "off"): port \(port.rawValue) unavailable (\(e)); trying another port.")
            bindReplacement(on: nil, swap: n)
            return
        }
        swap = .idle
        peerToPeer = wantedPeerToPeer
        print("Listener failed: \(e)")
        guard let handler = onListenerFailed else { exit(1) }   // the CLI, as always
        handler(e)
        onListenerState?(.failed(e))
        if !peerToPeer { disconnectPeerToPeerClients() }
    }

    /// Starts listening and advertising. Thread-safe: from here on the listener lives on `queue`.
    /// A closed home door (no identity) never listens: one line, and the CLI exits as it does when
    /// its listener fails; the app keeps running and says why.
    func start() {
        queue.async { [self] in
            if case .closed(let why) = homeMode {
                print("Home door unavailable: \(why).")
                if onListenerFailed == nil { exit(1) }   // the CLI, as when its listener fails
                return
            }
            // Set before start (the setting at launch): build the listener with it, nothing to replace.
            if wantedPeerToPeer != peerToPeer {
                do {
                    let l = try makeListener(peerToPeer: wantedPeerToPeer, port: nil)
                    l.service = makeService()
                    wire(l)
                    listener = l
                    peerToPeer = wantedPeerToPeer
                } catch {
                    print("Direct wireless \(wantedPeerToPeer ? "on" : "off"): the listener could not be built (\(error)); listening with it \(peerToPeer ? "on" : "off").")
                }
            }
            started = true
            // The TXT record is set by now (the coordinator sets it before start): a fresh tag.
            if txtRecord != nil { listener.service = makeService() }
            listener.start(queue: queue)
        }
    }

    /// Require pairing changed: the TXT record's `p` again. Setting the running listener's service
    /// with the same name and type updates the record in place (H0's P1: no removal, no "(2)", and
    /// no registration callback, so the status keeps its name). During a Direct Wireless
    /// replacement it does nothing: the replacement's advertising step reads the current value.
    /// Thread-safe.
    func updateService() {
        queue.async { [self] in
            guard started, swap == .idle, serviceNameAndType != nil, txtRecord != nil else { return }
            listener.service = makeService()
        }
    }

    /// The port the listener got, once it is ready: how test clients reach the synthetic host.
    var port: UInt16? {
        portLock.lock(); defer { portLock.unlock() }
        return readyPort
    }

    /// The home door. A TLS door hands the connection to its Door, which admits it, runs the device
    /// gate and registers it through `serve`. A plain one registers it only once it is ready, its
    /// origin is one the home door admits and, with the device floor above "0", its first message is
    /// a hello the floor admits: until then it gets nothing, counts for nothing, and prints nothing.
    /// `peerToPeer`: the accepting listener included peer-to-peer Wi-Fi.
    private func accept(_ connection: NWConnection, peerToPeer: Bool) {
        if let homeDoor { homeDoor.accept(connection, peerToPeer: peerToPeer); return }
        let client = Client(connection)
        client.acceptedPeerToPeer = peerToPeer
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Once: a second .ready changes nothing, also while the gate reads the first message.
                guard self.clients[id] == nil, !client.judging else { return }
                let origin = self.origin(of: connection)
                guard OriginPolicy.homeAdmits(origin) else {
                    // Through a tunnel or from the internet: never registered, zero bytes sent.
                    connection.cancel()
                    self.homeRefusals.count(origin == .vpn ? "vpn" : "internet")
                    return
                }
                client.route = .home(origin, peer: nil)
                let admit = { (hello: Hello?) in
                    client.link = self.link(connection, path: connection.currentPath)
                    self.register(client)
                    print("Client connected: \(connection.endpoint)")
                    self.receiveLoop(client)
                    self.onClientConnected?(connection, client.route, client.link)
                    if let hello { self.took(hello, from: client) }
                }
                // The floor at "0": registered at once, as always. Above it: by the first message.
                client.judging = true
                self.gate(connection) { hello in
                    if let hello, self.droppedForDirectWireless(connection, acceptedPeerToPeer: client.acceptedPeerToPeer, hello: hello) { return }
                    admit(hello)
                }
            case .failed:
                // Cancelled at once: a failed connection that is only forgotten keeps its socket.
                connection.cancel()
                self.unregister(id)
            case .cancelled:
                self.unregister(id)
            default: break
            }
        }
        // The link follows the path: reported once the client is registered, then on every change.
        // An established connection keeps its interface (TCP does not move), so a change is rare; a
        // cable pulled mid-session ends the connection instead, and the device's reconnect is a new
        // client with its own link.
        connection.pathUpdateHandler = { [weak self] path in
            guard let self, self.clients[id] === client else { return }
            let link = self.link(connection, path: path)
            guard link != client.link else { return }
            client.link = link
            self.onClientRouteChanged?(connection, link)
        }
        connection.start(queue: queue)
    }

    /// On `queue`: from now on `client` gets broadcasts, ticks and the catalog.
    private func register(_ client: Client) {
        client.connectedAt = Date().timeIntervalSince1970
        client.lastHeardAt = client.connectedAt
        clients[ObjectIdentifier(client.connection)] = client
        onClientCountChanged?(clients.count)
        updateTicking()
        updateSweep()
    }

    /// A session a TLS door admitted, already `.ready` and pinned, once the device gate has let it
    /// in (its Door runs `gate` first, and judges again what changed meanwhile): registered like a
    /// plain home client, with its route, then `admitted` (the door's "Client connected" or "Remote
    /// client connected" line), then its hello, when the gate read one (`took`). A remote session has
    /// no link (its card names the route, "through Tailscale"); a home one's link is read at
    /// registration and then follows the path, as the plain door's does. On `queue`.
    func serve(_ connection: NWConnection, route: ClientRoute, hello: Hello?, admitted: () -> Void = {}) {
        let client = Client(connection)
        client.route = route
        // As its route says: every session a Door admits is TLS (a remote one, or a home one with its
        // peer's key); a home route without a peer is a plain connection and keeps the plain door's
        // tick rule (the pacing harness's home client, Scripts/pacing).
        client.encrypted = route.encrypted
        client.onCable = route.cableDevice != nil
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed:
                connection.cancel()
                self.unregister(id)
            case .cancelled:
                self.unregister(id)
            default: break
            }
        }
        if !route.isRemote {
            client.link = link(connection, path: connection.currentPath)
            connection.pathUpdateHandler = { [weak self] path in
                guard let self, self.clients[id] === client else { return }
                let link = self.link(connection, path: path)
                guard link != client.link else { return }
                client.link = link
                self.onClientRouteChanged?(connection, link)
            }
        }
        register(client)
        receiveLoop(client)
        onClientConnected?(connection, route, client.link)
        admitted()
        if let hello { took(hello, from: client) }
    }

    /// Admitted remote sessions: how many. On `queue`.
    var remoteSessionCount: Int { clients.values.filter { $0.route.isRemote }.count }

    /// Every admitted session, of either door, whose route matches gets goodbye `reason` and is
    /// closed; `line` names one (its paired name, else the device's own, and its endpoint) for the
    /// log, and `done` gets how many there were. Thread-safe.
    func closeSessions(_ reason: String, matching: @escaping @Sendable (ClientRoute) -> Bool,
                       line: (@Sendable (String, String) -> String)? = nil, done: (@Sendable (Int) -> Void)? = nil) {
        queue.async { [self] in
            let list = clients.values.filter { matching($0.route) }
            for client in list {
                if let line { print(line(client.route.pairedName ?? client.device ?? "a device", "\(client.connection.endpoint)")) }
                goodbye(Goodbye(reason: reason), to: client.connection)
            }
            done?(list.count)
        }
    }

    // MARK: Goodbye (kind 22)

    /// Tells one admitted client why it is about to be closed, then closes it once the message is
    /// handed to the network or `within` has passed, whichever comes first: a registered client,
    /// whose connection the stream and the catalog share. A connection that was never registered
    /// closes with `closeWithGoodbye`. On `queue`.
    func goodbye(_ goodbye: Goodbye, to connection: NWConnection, within: TimeInterval = 0.25) {
        Self.sayGoodbye(payload: Wire.encode(goodbye), on: connection, queue: queue, within: within)
    }

    /// A kind 22 with this payload, then the close. On `queue`.
    private static func sayGoodbye(payload: Data, on connection: NWConnection, queue: DispatchQueue, within: TimeInterval) {
        let data = StreamMessage(kind: .goodbye, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                 payload: payload).serialized()
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        queue.asyncAfter(deadline: .now() + within) { connection.cancel() }
    }

    /// Every admitted client, home and remote, gets `goodbye` (the app's Quit and the signal path:
    /// "quit"); returns once each message was handed to the network or after `within`. Call from
    /// any thread but the network queue.
    func goodbyeAll(_ goodbye: Goodbye, within: TimeInterval) {
        let group = DispatchGroup()
        group.enter()
        queue.async { [self] in
            let data = StreamMessage(kind: .goodbye, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                     payload: Wire.encode(goodbye)).serialized()
            for client in clients.values where client.connection.state == .ready {
                group.enter()
                client.connection.send(content: data, completion: .contentProcessed { _ in group.leave() })
            }
            group.leave()
        }
        _ = group.wait(timeout: .now() + within)
    }

    // MARK: The device gate (DeviceGate)
    //
    // With the floor above "0", a ready session is held unregistered (no broadcast, tick, catalog,
    // device row, "Client connected" line or count) while its first message is read: a hello the
    // floor admits is served (`admit`); anything else is refused with the update goodbye and
    // closed, never registered, so neither "Client connected" nor "Client left" is printed for it.
    // One gate for every door: a TLS door's Door runs it once the key is admitted (the hello is the
    // first message inside TLS, and never comes on a pairing connection), the plain home door at
    // `.ready`; the refusals, their lines and the loop slowdown are counted per source across both.

    /// Each source's refusals within the last `DeviceGate.loopWindow` (the loop slowdown), and the
    /// sources whose Refused line was printed within the last minute, with how many more came since.
    /// On `queue`.
    private var gateRefusals: [String: [CFAbsoluteTime]] = [:]
    private var gateLog: [String: Int] = [:]

    /// The floor at "0" (every build that ships so far): `admit(nil)` at once, as always, and nothing
    /// is read ahead. Above it: reads `c`'s first message, within `DeviceGate.firstMessageDeadline`
    /// of now (`.ready`, or a TLS door's admission): a hello the floor admits calls `admit` with it;
    /// a lower version, a hello that does not decode, any other kind first, the end of the
    /// connection or nothing in time is refused (`refuse`), and `admit` is never called. On `queue`.
    func gate(_ c: NWConnection, admit: @escaping (Hello?) -> Void) {
        guard deviceFloor != .zero else { admit(nil); return }
        var decided = false          // on `queue`, like every closure here
        let refuse = { [weak self] (hello: Hello?) in
            guard let self, !decided else { return }
            decided = true
            self.refuse(c, hello: hello)
        }
        let deadline = DispatchWorkItem { refuse(nil) }
        queue.asyncAfter(deadline: .now() + DeviceGate.firstMessageDeadline, execute: deadline)
        c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [weak self] data, _, _, _ in
            guard let self, !decided else { return }
            // An older device's viewport, pick or ping, a header no Sill sends, or the end: refused
            // at once, its payload unread.
            guard let data, let header = StreamMessage.parseHeader(data), header.kind == .hello,
                  header.payloadLength <= StreamMessage.maxClientPayload else {
                deadline.cancel()
                refuse(nil)
                return
            }
            let judge = { (payload: Data) in
                guard !decided else { return }
                deadline.cancel()
                let hello = Wire.decode(Hello.self, from: payload)
                if let hello, DeviceGate.admits(hello, floor: self.deviceFloor) {
                    decided = true
                    admit(hello)
                } else {
                    refuse(hello)
                }
            }
            if header.payloadLength == 0 { judge(Data()); return }
            c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { data, _, _, _ in
                guard let data, data.count == header.payloadLength else {
                    deadline.cancel()
                    refuse(nil)
                    return
                }
                judge(data)
            }
        }
    }

    /// A device the gate did not admit: the update goodbye (or SILL_TEST_GOODBYE's payload), then
    /// the close (`closeWithGoodbye`); one Refused line per source a minute, the rest counted. A
    /// source refused `DeviceGate.loopRefusals` times within the window hears it
    /// `DeviceGate.loopDelay` later. On `queue`.
    private func refuse(_ c: NWConnection, hello: Hello?) {
        let source: String
        if case .hostPort(let host, _) = c.endpoint { source = Self.addressText(host).text } else { source = "\(c.endpoint)" }
        let now = CFAbsoluteTimeGetCurrent()
        if gateRefusals.count > 256 { gateRefusals = gateRefusals.filter { $0.value.contains { now - $0 < DeviceGate.loopWindow } } }
        var times = (gateRefusals[source] ?? []).filter { now - $0 < DeviceGate.loopWindow }
        let slowed = DeviceGate.slows(refusedInWindow: times.count)
        times.append(now)
        gateRefusals[source] = times
        logRefusal(DeviceGate.refusedLine(hello, endpoint: "\(c.endpoint)", floor: deviceFloor), source: source)
        let payload = testGoodbye ?? Wire.encode(DeviceGate.refusal(hello, floor: deviceFloor, macName: macName))
        let queue = queue
        if slowed {
            queue.asyncAfter(deadline: .now() + DeviceGate.loopDelay) { Self.closeWithGoodbye(payload, on: c, queue: queue) }
        } else {
            Self.closeWithGoodbye(payload, on: c, queue: queue)
        }
    }

    /// The goodbye and close of a connection that was never registered, so nothing else sends to
    /// it: the gate's refusals, a session the gate held and its Door then refused (DoorPolicy's
    /// `afterGate`), and a TLS door's goodbyes at `.ready` (Remote Access off, the session limit).
    /// The message, then this side's end (FIN; over TLS its close_notify first), then whatever the
    /// device still sends read and dropped until it closes too (at most `DeviceGate.closeWait`),
    /// then the connection cancelled. Cancelling at once, with what the device sent still unread,
    /// makes TCP answer with a reset, which can reach the device before it has read the goodbye
    /// (sillclient, sending on after its hello, got the goodbye and then ECONNRESET), and a device
    /// from 2026-09-25 on sends its hello as soon as its connection is ready; a device that loses
    /// the goodbye reads the reset instead and redials. On `queue`.
    static func closeWithGoodbye(_ goodbye: Goodbye, on c: NWConnection, queue: DispatchQueue) {
        closeWithGoodbye(Wire.encode(goodbye), on: c, queue: queue)
    }

    /// The same with this kind 22 payload (the gate's refusal, or SILL_TEST_GOODBYE's). On `queue`.
    private static func closeWithGoodbye(_ payload: Data, on c: NWConnection, queue: DispatchQueue) {
        let data = StreamMessage(kind: .goodbye, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                 payload: payload).serialized()
        c.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        func drain() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, isComplete, error in
                if isComplete || error != nil { c.cancel(); return }
                drain()
            }
        }
        drain()
        queue.asyncAfter(deadline: .now() + DeviceGate.closeWait) { c.cancel() }
    }

    /// The first refusal of a source in a minute prints its line; the rest of that minute's are
    /// counted and printed in one line when it is up, and so on while they keep coming. On `queue`.
    private func logRefusal(_ line: String, source: String) {
        if let n = gateLog[source] {
            gateLog[source] = n + 1
            return
        }
        print(line)
        gateLog[source] = 0
        armRefusalLog(source)
    }

    private func armRefusalLog(_ source: String) {
        queue.asyncAfter(deadline: .now() + RefusalSummary.interval) { [weak self] in
            guard let self, let n = self.gateLog[source] else { return }
            guard n > 0 else { self.gateLog[source] = nil; return }
            print(DeviceGate.countLine(n, source: source, floor: self.deviceFloor))
            self.gateLog[source] = 0
            self.armRefusalLog(source)
        }
    }

    /// A device's hello, the first of its connection (after the gate, or in the receive loop): its
    /// name for the log until its stats name it, one line, and the callback. It never refuses: with
    /// the floor at "0" every device is served, and above it the gate has judged it already. On
    /// `queue`.
    private func took(_ hello: Hello, from client: Client) {
        client.helloSeen = true
        let c = client.connection
        let name = SafeText.label(hello.device ?? "")
        if client.device == nil, !name.isEmpty { client.device = name }
        print(DeviceGate.helloLine(hello, endpoint: "\(c.endpoint)"))
        onClientHello?(c, hello)
    }

    // MARK: The sweep: each device's link, and remote clients' silence and slow uplink
    //
    // Once a second while any client is registered, each client's second is closed into its link
    // judge (LinkJudge; every client, at home too: the home branch only counts), and a change is
    // reported (`onClientLinkChanged`).
    //
    // A home client that stops draining for 4 s is gone (8 s grace after connecting). A remote one
    // can legitimately take longer: on a 2 Mbps uplink a 1.5 MB keyframe needs 6 s to hand off. So a
    // remote client is dropped when it has sent nothing for 8 s (it pings every 0.25 s and reports
    // once a second, so silence means it is gone), once 8 s have passed since it was admitted, and
    // the drain backstop gives it 15 s after a 15 s grace. The same sweep asks for the keyframe a
    // remote client waits for once the window has gone still.
    private var sweepTimer: DispatchSourceTimer?
    /// When the sweep last closed the clients' seconds: a client heard since then was heard in it.
    private var lastSweepAt: TimeInterval = 0
    static let remoteSilence: TimeInterval = 8
    static let remoteDeadAfter: TimeInterval = 15
    static let remoteGrace: TimeInterval = 15

    /// On `queue`: a 1 s sweep while any client exists.
    private func updateSweep() {
        let wanted = !clients.isEmpty
        if wanted, sweepTimer == nil {
            lastSweepAt = Date().timeIntervalSince1970
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.sweep() }
            t.resume()
            sweepTimer = t
        } else if !wanted, let t = sweepTimer {
            t.cancel(); sweepTimer = nil
        }
    }

    private func sweep() {
        let now = Date().timeIntervalSince1970
        let since = lastSweepAt
        lastSweepAt = now
        var waiting: [Client] = []
        for client in clients.values {
            let second = LinkJudge.Second(sent: client.sentThisSecond, withheld: client.withheldThisSecond, taken: client.takenThisSecond,
                                          waiting: client.pendingBytes, heard: client.lastHeardAt > since)
            client.sentThisSecond = 0
            client.withheldThisSecond = 0
            client.takenThisSecond = 0
            if let verdict = client.judge.close(second) { onClientLinkChanged?(client.connection, verdict) }
            guard client.route.isRemote else { continue }
            let silent = now - client.lastHeardAt
            if now - client.connectedAt >= Self.remoteSilence, silent > Self.remoteSilence {
                print("Client silent for \(Int(silent)) s, dropping: \(client.connection.endpoint)")
                client.connection.cancel()   // its state handler forgets it
            } else if client.needsKeyframe, client.keyframeWanted, !client.awaitingFirstKeyframe,
                      client.pendingBytes <= Self.remoteIdleBytes, client.connection.state == .ready {
                waiting.append(client)
            }
        }
        // A client that lost a frame asks for its keyframe when a later frame comes (`paceRemote`).
        // Once the window has gone still, none comes, and it would keep the picture from before the
        // drop until the window next changes: the end of a scroll, the last letters typed. So the
        // sweep asks too, on the same terms (its queue idle, the request due); the encoder then
        // encodes the still window's last frame again (HEVCEncoder.requestKeyframe). While frames
        // come, whichever looks first asks, once.
        if !waiting.isEmpty, remoteKeyframeDue(now) {
            lastRemoteKeyframeRequest = now
            for client in waiting { client.keyframeWanted = false }
            onKeyframeNeeded?()
        }
    }

    /// On `queue`: forgets a registered client, once ("Client left" and the callbacks). A
    /// connection that was never registered (refused, or failed before it was ready) leaves no line.
    private func unregister(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        pointerWatch?.clientLeft(id)
        print("Client left: \(client.connection.endpoint)")
        onClientDisconnected?(client.connection)
        onClientCountChanged?(clients.count)
        updateTicking()
        updateSweep()
    }

    /// The source is changing: forget the old parameter sets and make every client wait for
    /// the next keyframe, so nobody decodes frames of the new window with the old format. Each
    /// client's link keeps its judgement (`resetLinks` is the coordinator's to call).
    func resetForNewStream() {
        queue.async { [self] in
            lastParameterSets = nil
            for client in clients.values {
                client.needsKeyframe = true
                client.awaitingFirstKeyframe = true
            }
        }
    }

    /// The stream runs at another quality, or stopped (LinkJudge.judgedAfresh): each client's link is
    /// judged afresh (LinkJudge.reset), and one that was not fine is reported fine, marked as a
    /// reset. A restart that keeps the quality never calls it. Thread-safe.
    func resetLinks() {
        queue.async { [self] in
            for client in clients.values {
                client.sentThisSecond = 0
                client.withheldThisSecond = 0
                if let verdict = client.judge.reset() { onClientLinkChanged?(client.connection, verdict) }
            }
        }
    }

    /// Each connection its own message (the devices' settings states, kind 16, one per connection):
    /// a registered, ready connection gets its own; any other is skipped without a word, as
    /// `broadcast` skips it, where `send(_:to:)` would print "send: no client for …" (a state can be
    /// built for a connection the server has just forgotten, before the coordinator hears it left).
    /// Thread-safe.
    func send(each messages: [(NWConnection, StreamMessage)]) {
        let items = messages.map { (ObjectIdentifier($0.0), $0.1.serialized()) }
        queue.async { [self] in
            for (id, data) in items {
                guard let client = clients[id], client.connection.state == .ready else { continue }
                send(data, to: client)
            }
        }
    }

    /// One message to one client (catalog on connect). Thread-safe.
    func send(_ message: StreamMessage, to connection: NWConnection) {
        let data = message.serialized()
        queue.async { [self] in
            guard let client = clients[ObjectIdentifier(connection)] else {
                print("send: no client for \(connection.endpoint) (\(clients.count) known)")
                return
            }
            send(data, to: client)
        }
    }

    /// Client → host messages share the same framing. Small and rare, so read them one at a time.
    private func receiveLoop(_ client: Client) {
        let c = client.connection
        c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, let header = StreamMessage.parseHeader(data) else {
                // EOF or a read error: the client closed (or was killed). Nothing else would notice
                // while no frames are being sent, so cancel here; the state handler prints and forgets it.
                if isComplete || error != nil { c.cancel() }
                return
            }
            client.lastHeardAt = Date().timeIntervalSince1970
            // A header can announce up to 4 GiB and the read below would wait for all of it. No
            // client message comes near a megabyte, so a bigger one is a broken or hostile peer.
            if header.payloadLength > StreamMessage.maxClientPayload {
                print("Closing \(c.endpoint): it announced a \(header.payloadLength)-byte message (the limit is 1 MB).")
                c.cancel()
                return
            }
            let deliver = { (payload: Data) in
                if header.kind == .input {
                    self.lastInputAt = Date().timeIntervalSince1970
                    if self.tickTimer == nil { self.updateTicking() }
                    // This device moves the Mac's pointer now. The count and the controller change
                    // in the same queue turn as every sample, so no kind 26 carries the new count
                    // with the old controller (docs/pointer-visibility-plan.md §3.3).
                    client.inputsRead += 1
                    self.pointerWatch?.inputArrived(from: ObjectIdentifier(c), movesPointer: PointerControl.movesPointer(payload: payload))
                }
                if header.kind == .ping {
                    // Echo straight back from the network queue: the round trip should measure the
                    // network and nothing else.
                    self.send(StreamMessage(kind: .pong, timestamp: header.timestamp, isKeyframe: false, payload: payload).serialized(), to: client)
                } else if header.kind == .clientStats {
                    // What the device sees, printed here so the latency number is in the Mac's log.
                    // The client reports every second; every other report (~2 s) is enough. The gate
                    // is 1.5 s, not 2, so arrival jitter on a 1 s cadence cannot stretch it to 3 s.
                    // A skipped report's maxima still reach the next line.
                    // Every report goes to `onClientStats` (the app's menu shows it live).
                    if let stats = Wire.decode(ClientStats.self, from: payload) {
                        // The device names itself: one clean line of at most 64 characters, never
                        // its raw text (a newline would forge a log line).
                        let name = SafeText.label(stats.device)
                        client.device = name.isEmpty ? nil : name
                        client.worstFrameAgeSincePrint = max(client.worstFrameAgeSincePrint, stats.frameAgeMaxMs ?? -1)
                        client.worstRttSincePrint = max(client.worstRttSincePrint, stats.rttMaxMs ?? -1)
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - client.lastStatsPrint >= 1.5 {
                            client.lastStatsPrint = now
                            let age = Self.medianAndWorst(stats.frameAgeMs, worst: stats.frameAgeMaxMs.map { _ in client.worstFrameAgeSincePrint })
                            let rtt = Self.medianAndWorst(stats.rttMs, worst: stats.rttMaxMs.map { _ in client.worstRttSincePrint })
                            print("client \(client.device ?? "\(c.endpoint)"): \(stats.fps) fps, frame age \(age), rtt \(rtt)")
                            client.worstFrameAgeSincePrint = -1
                            client.worstRttSincePrint = -1
                        }
                        self.onClientStats?(c, stats)
                    }
                } else if header.kind == .hello {
                    // The device's hello: the first of this connection counts, a second is skipped
                    // without a line. Never a refusal here (see `took`).
                    if !client.helloSeen {
                        client.helloSeen = true
                        if let hello = Wire.decode(Hello.self, from: payload) { self.took(hello, from: client) }
                    }
                } else if header.kind == .pairingWanted && client.route.isRemote {
                    // "Show your pairing code" comes only from a device near the Mac: ignored here.
                } else {
                    self.onMessage?(StreamMessage(kind: header.kind, timestamp: header.timestamp, isKeyframe: header.isKeyframe, payload: payload), c)
                }
                self.receiveLoop(client)
            }
            if header.payloadLength == 0 { deliver(Data()); return }
            c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { data, _, isComplete, error in
                guard let data else {
                    if isComplete || error != nil { c.cancel() }
                    return
                }
                deliver(data)
            }
        }
    }

    /// One number of a client stats line. A current client reports each second's median and max:
    /// "7/80 ms" is the last second's median over the worst since the previous line, "–" a second
    /// without a sample (no frame arrived, no pong came back), "–/80 ms" such a second after one
    /// that had samples. An older client sends one sample and no max (`worst` nil): "7 ms", as the
    /// line always read.
    private static func medianAndWorst(_ median: Int, worst: Int?) -> String {
        guard let worst else { return "\(median) ms" }
        if median < 0 { return worst < 0 ? "–" : "–/\(worst) ms" }
        return "\(median)/\(max(worst, median)) ms"
    }

    /// Thread-safe: hops onto the network queue.
    func broadcast(_ message: StreamMessage) {
        let data = message.serialized()
        queue.async { [self] in
            if message.kind == .parameterSets { lastParameterSets = data }
            if message.kind == .frame, message.isKeyframe { lastKeyframeAt = Date().timeIntervalSince1970 }
            var wantKeyframe = false
            defer { if wantKeyframe { onKeyframeNeeded?() } }
            for client in clients.values where client.connection.state == .ready {
                if message.kind == .frame, client.route.isRemote {
                    if paceRemote(client, message: message, data: data) { wantKeyframe = true }
                    continue
                }
                if message.kind == .frame {
                    // Its link only counts here (LinkJudge): what it sends and drops is as ever.
                    if client.needsKeyframe {
                        guard message.isKeyframe, let ps = lastParameterSets else {
                            Stats.shared.bump("net.waitKey")
                            if !client.awaitingFirstKeyframe { client.withheldThisSecond += 1 }
                            continue
                        }
                        send(ps, to: client)
                        client.needsKeyframe = false
                        client.awaitingFirstKeyframe = false
                    } else if client.inflight > 2 && !message.isKeyframe {
                        // Drop the delta. Every later delta references it, so this client now waits for
                        // a keyframe (sending deltas anyway is what showed up as flicker on the iPad).
                        Stats.shared.bump("net.dropped")
                        client.withheldThisSecond += 1
                        client.needsKeyframe = true
                        wantKeyframe = true
                        continue
                    }
                    Stats.shared.bump("net.sent")
                    client.sentThisSecond += 1
                }
                send(data, to: client, isFrame: message.kind == .frame)
            }
        }
    }

    /// Remote clients' frames (home clients keep the rule above byte for byte). What is queued is
    /// counted in bytes the connection has not taken yet (`pendingBytes`), never in messages
    /// (docs/remote-bundle-plan.md §3):
    /// - Behind a keyframe the connection is still taking, frames go out up to `remoteHoldCap`:
    ///   every delta references that keyframe, so dropping them for its sake wasted it and looped
    ///   (drop, a keyframe 2 s later, the next delta dropped behind it: 2026-09-25, 0–3 fps and
    ///   rtt up to 12 s at 150 Mbps on a phone's hotspot). What counts against the cap is what
    ///   waits beyond every keyframe still being taken: a restarted stream's first keyframe goes
    ///   out at once, behind the old stream's if that one is still crossing, and its deltas
    ///   reference it alone.
    /// - Otherwise a frame is dropped only when the backlog exceeds both `remoteBacklogBudget` and
    ///   what the last keyframe left behind it (`backlogFloor`, following the backlog down) plus
    ///   `remoteBacklogSlack`: a backlog that shrinks is a link catching up, one that grows is a
    ///   stream the link cannot carry.
    /// - A client that lost a frame asks for a keyframe only once the connection has taken
    ///   everything but control messages (`remoteIdleBytes`), so the keyframe leads the queue
    ///   instead of queueing behind the backlog that caused the drop; at most every
    ///   `remoteKeyframeSpacing` for all remote clients together (later beside a home client:
    ///   `remoteKeyframeDue`). It asks when a later frame comes, or, once the window has gone
    ///   still and none does, at the sweep (`sweep`).
    /// - The keyframe it waits for goes out when the backlog fits the budget, or at once when it
    ///   has had none since it was admitted or the stream changed (the first keyframe).
    /// Returns whether to ask for one now. On `queue`. No new Stats key: skipped frames count as
    /// net.waitKey, dropped ones as net.dropped, sent ones as net.sent.
    private func paceRemote(_ client: Client, message: StreamMessage, data: Data) -> Bool {
        var ask = false
        client.backlogFloor = min(client.backlogFloor, client.pendingBytes)
        if client.needsKeyframe {
            guard message.isKeyframe else {
                Stats.shared.bump("net.waitKey")
                if !client.awaitingFirstKeyframe { client.withheldThisSecond += 1 }
                let now = Date().timeIntervalSince1970
                if client.keyframeWanted, client.pendingBytes <= Self.remoteIdleBytes, remoteKeyframeDue(now) {
                    lastRemoteKeyframeRequest = now
                    client.keyframeWanted = false
                    ask = true
                }
                return ask
            }
            guard client.awaitingFirstKeyframe || client.pendingBytes <= Self.remoteBacklogBudget, let ps = lastParameterSets else {
                // Its queue is still full: this keyframe is lost to it too. Ask again once it has
                // drained (within the spacing) rather than wait for the encoder's own periodic one.
                Stats.shared.bump("net.waitKey")
                client.withheldThisSecond += 1
                client.keyframeWanted = true
                return false
            }
            send(ps, to: client)
            client.needsKeyframe = false
            client.awaitingFirstKeyframe = false
        } else {
            let tooMuch: Bool
            if !client.keyframesInFlight.isEmpty {
                tooMuch = client.pendingBytes - client.keyframeBytesInFlight > Self.remoteHoldCap
            } else {
                tooMuch = client.pendingBytes > max(Self.remoteBacklogBudget, client.backlogFloor + Self.remoteBacklogSlack)
            }
            if tooMuch {
                Stats.shared.bump("net.dropped")
                client.withheldThisSecond += 1
                client.needsKeyframe = true
                client.keyframeWanted = true
                return false
            }
        }
        Stats.shared.bump("net.sent")
        client.sentThisSecond += 1
        send(data, to: client, isFrame: true, isKeyframe: message.isKeyframe)
        return false
    }

    /// A remote client's backlog that never drops a frame: about a quarter second at 8 Mbps, 30
    /// frames of the Low preset.
    static let remoteBacklogBudget = 256 * 1024
    /// Growth over what a keyframe left behind that still counts as noise (a thumbnail pass is 11
    /// small JPEGs).
    static let remoteBacklogSlack = 128 * 1024
    /// How much may queue behind a keyframe the connection is still taking: about a second of the
    /// Low preset's deltas (60 × ~8 KB), what piles up while a large keyframe is taken on a hotspot;
    /// past it the stream is more than the link carries.
    static let remoteHoldCap = 512 * 1024
    /// A queue this short holds nothing but control messages (pongs, a settings reply): a
    /// keyframe asked for now leads it.
    static let remoteIdleBytes = 16 * 1024

    /// When a keyframe was last asked for on behalf of a remote client.
    private var lastRemoteKeyframeRequest: TimeInterval = 0
    /// When the last keyframe went out, of any kind (the encoder's own, or one asked for).
    private var lastKeyframeAt: TimeInterval = 0
    static let remoteKeyframeSpacing: TimeInterval = 2
    /// The encoder's own keyframe interval: HEVCEncoder's `fps * 4` frames.
    static let remoteKeyframeSpacingBesideHome: TimeInterval = 4

    /// Whether a keyframe may be asked for on a remote client's behalf now: alone, 2 s after the
    /// last such request. It is encoded once and goes to every client, though, so while a home
    /// client is connected the request also waits until 4 s have passed since the last keyframe of
    /// any kind. The encoder's own is due by then, so a slow remote link gives a device on the LAN
    /// no more keyframes than the encoder's interval would, where each one showed as a 50–100 ms
    /// hitch (the trackpad stutter's cause 2); it only brings one forward when frames come slower
    /// than the stream's rate. The remote device waits longer after a drop in exchange. On `queue`.
    private func remoteKeyframeDue(_ now: TimeInterval) -> Bool {
        guard clients.values.contains(where: { !$0.route.isRemote }) else {
            return now - lastRemoteKeyframeRequest >= Self.remoteKeyframeSpacing
        }
        return now - lastRemoteKeyframeRequest >= Self.remoteKeyframeSpacingBesideHome
            && now - lastKeyframeAt >= Self.remoteKeyframeSpacingBesideHome
    }

    /// A peer that has not drained a single video frame for this long stopped reading (app killed,
    /// device asleep). Time-based rather than a frame count: a slow decoder (the simulator at full
    /// Retina) or the connect burst can hold many frames unacked and still be alive.
    private static let deadAfter: TimeInterval = 4.0
    /// No eviction while the connect burst (catalog + first keyframe) is still draining.
    private static let graceAfterConnect: TimeInterval = 8.0

    private func send(_ data: Data, to client: Client, isFrame: Bool = false, isKeyframe: Bool = false) {
        let now = Date().timeIntervalSince1970
        let remote = client.route.isRemote
        if isFrame, let oldest = client.oldestUnackedFrameAt,
           now - oldest > (remote ? Self.remoteDeadAfter : Self.deadAfter),
           now - client.connectedAt > (remote ? Self.remoteGrace : Self.graceAfterConnect) {
            print("Client not draining for \(Int(now - oldest)) s, dropping: \(client.connection.endpoint)")
            client.connection.cancel()   // its state handler removes it from `clients`
            return
        }
        client.inflight += 1
        client.lastSentAt = now
        client.pendingBytes += data.count
        var keyframeSeq: Int?
        if remote {
            if isKeyframe {
                client.keyframeSeq += 1
                keyframeSeq = client.keyframeSeq
                client.keyframesInFlight.append((client.keyframeSeq, data.count))
                client.keyframeBytesInFlight += data.count
            }
        }
        if isFrame {
            client.inflightFrames += 1
            if client.oldestUnackedFrameAt == nil { client.oldestUnackedFrameAt = now }
        }
        client.connection.send(content: data, completion: .contentProcessed { [weak client] _ in
            guard let client else { return }
            client.inflight -= 1
            client.pendingBytes -= data.count
            client.takenThisSecond += data.count
            if remote {
                if let seq = keyframeSeq, let i = client.keyframesInFlight.firstIndex(where: { $0.seq == seq }) {
                    client.keyframeBytesInFlight -= client.keyframesInFlight.remove(at: i).bytes
                    // The last of them taken: what they left behind them.
                    if client.keyframesInFlight.isEmpty { client.backlogFloor = client.pendingBytes }
                }
            }
            if isFrame {
                client.inflightFrames -= 1
                if client.inflightFrames <= 0 {
                    client.inflightFrames = 0; client.oldestUnackedFrameAt = nil
                } else {
                    // Progress: a slow but live peer on a saturated link never drains to zero.
                    client.oldestUnackedFrameAt = Date().timeIntervalSince1970
                }
            }
        })
    }
}

/// Which door admitted a client and from where. The home door's origin is decided at `.ready`,
/// with the peer's key when the door speaks TLS; a remote session carries the paired device's
/// fingerprint and name and the route's label ("through Tailscale", "over the internet", "by
/// address").
enum ClientRoute: Equatable {
    /// A TLS home session's key: its fingerprint, its paired name (nil for an unpaired key while
    /// Require pairing is off), and the iPhone or iPad it runs over by the USB cable
    /// (CableLink.deviceID, never the serial; nil off the cable).
    struct Peer: Equatable {
        var fingerprint: Data
        var name: String?
        var cableDevice: String?
    }
    /// `peer` nil: the plain door, which sees no key.
    case home(OriginPolicy.Origin, peer: Peer?)
    case remote(origin: OriginPolicy.Origin, label: String, fingerprint: Data, name: String)

    var isRemote: Bool { if case .remote = self { return true }; return false }
    var origin: OriginPolicy.Origin {
        switch self {
        case .home(let o, _): return o
        case .remote(let o, _, _, _): return o
        }
    }
    /// The label a remote route shows on the Mac's card; nil at home.
    var label: String? { if case .remote(_, let l, _, _) = self { return l }; return nil }
    /// The peer's key, at either door; nil on the plain home door.
    var fingerprint: Data? {
        switch self {
        case .home(_, let peer): return peer?.fingerprint
        case .remote(_, _, let f, _): return f
        }
    }
    /// The paired name, at either door; nil on the plain home door and for an unpaired key.
    var pairedName: String? {
        switch self {
        case .home(_, let peer): return peer?.name
        case .remote(_, _, _, let n): return n
        }
    }
    /// A home session over the USB cable: the device's CableLink.deviceID.
    var cableDevice: String? { if case .home(_, let peer) = self { return peer?.cableDevice }; return nil }
    /// The session is TLS: every remote one, and every home one with a peer.
    var encrypted: Bool {
        switch self {
        case .home(_, let peer): return peer != nil
        case .remote: return true
        }
    }
}
