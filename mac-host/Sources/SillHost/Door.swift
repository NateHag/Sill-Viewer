import Foundation
import Network
import StreamProtocol

/// Admission at a TLS door (docs/home-pairing-plan.md §4.4), one class behind both listeners: the
/// remote door (RemoteServer's listener, port 7455) and the home door once it speaks TLS
/// (StreamServer's Bonjour listener in Sill.app and SillHost --pairing). Who gets in is
/// DoorPolicy's, so a rule changes in one place; this runs it. RemoteServer's admission, moved.
///
/// Before admission a connection is cheap to refuse: at most 8 pending in all and 2 per source, a
/// source the door refused 5 times in 60 s is refused for 300 s (an attempt the device itself
/// abandons is no refusal, nor is a plain Sill's try at the home door, and a paired key clears the
/// count), and 10 s from accept to admission (TLS, plus the one kind 19 of a pairing connection).
/// Sources the door does not admit are cancelled before the connection starts, so they get no
/// byte, and judged again at `.preparing`, `.ready` and at kind 19. The verify block decides trust
/// from the lock-protected TrustSnapshot and the negotiated ALPN (DoorPolicy.trusts). Refusals are
/// counted and reported at most once a minute, one line per door.
///
/// Admitted sessions pass the device gate here, one place for both doors (DeviceGate; with the
/// floor above "0" the hello, the first message inside TLS, is read before anything is registered,
/// and what changed while the gate read it is judged again, DoorPolicy.afterGate), then go to
/// `StreamServer.serve` with their route; a pairing connection carries exactly one PairRequest,
/// judged on the main actor (RemoteAccess), and one PairResult back, and never meets the gate. At
/// the home door an attempt also says where it came from, whether that is this Mac itself, and
/// which iPhone or iPad it came over by the USB cable, read afresh (CableLink).
///
/// Threading: everything here runs on StreamServer's network queue, which the listeners, the
/// connections, their verify blocks and the timers share. Callbacks out are on that queue.
///
/// TEST ONLY, on a test host only (DoorPolicy.isTestHost): SILL_TEST_BACKOFF_SECONDS=<s> replaces
/// the 300 s backoff; SILL_TEST_CABLE_INTERFACE=<if> counts a client scoped to that interface as
/// one on the cable to an "iPad" (CableLink.testInterface).
final class Door {
    /// One pairing attempt, for RemoteAccess to judge on the main actor.
    struct PairAttempt: Sendable {
        let door: DoorPolicy.Door
        let request: PairRequest
        /// From the TLS session, never from the message.
        let deviceFingerprint: Data
        /// The connection's address without its zone: the per-source rules' key.
        let source: String
        /// The address as the log names it: with its scope at the home door ("fe80::1%en0"), as
        /// `source` at the remote door (its lines are unchanged).
        let display: String
        let origin: OriginPolicy.Origin
        /// The interface it arrived on (the scope, else the owner of the local address).
        let interface: String?
        /// Loopback, or one of this Mac's own addresses (DoorPolicy.isFromThisMac), read afresh.
        let fromThisMac: Bool
        /// Home door only: the iPhone or iPad this connection came over by the USB cable, by the
        /// Mac's own rule (CableLink.device over the arrival interface, read afresh); nil otherwise.
        let cable: CableLink.Ancestry?
    }

    static let maxPending = 8
    static let maxPendingPerSource = 2
    static let admissionDeadline: TimeInterval = 10
    static let failureWindow: TimeInterval = 60
    static let failuresForBackoff = 5

    let kind: DoorPolicy.Door
    private let queue: DispatchQueue
    private let identity: HostIdentity
    private let trust: TrustBox
    private let testHost: Bool
    private let backoff: TimeInterval
    /// TEST ONLY: the interface that stands in for the USB cable (home door, test host).
    private let cableStandIn: String?
    /// Set right after the server's own init (the home door is made inside it); every connection
    /// comes after that.
    weak var server: StreamServer?

    /// A pairing attempt; the reply may be called from any thread.
    var onPairAttempt: ((PairAttempt, @escaping @Sendable (PairResult) -> Void) -> Void)?
    /// Home door: plain Sill messages at the TLS door (an older Sill, -9836), for the menu: once one
    /// source has tried so `DoorPolicy.olderSillTries` times within a minute (a TLS 1.2 client, which
    /// fails the same way, usually tries once).
    var onOlderSill: (() -> Void)?

    private struct Pending {
        let connection: NWConnection
        let source: String
        var origin: OriginPolicy.Origin?
        var interface: String?
        /// Home door: the listener that accepted it included peer-to-peer Wi-Fi (Direct Wireless on).
        var peerToPeer = false
        /// The door refused it (counted in the minute's summary already), so its end counts one
        /// failure for its source.
        var refused = false
        var deadline: DispatchWorkItem?
    }
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var failures: [String: [CFAbsoluteTime]] = [:]
    private var backoffUntil: [String: CFAbsoluteTime] = [:]
    /// Home door: each source's plain tries within the last minute (DoorPolicy.olderSillTry).
    private var olderTries: [String: [CFAbsoluteTime]] = [:]

    private lazy var refusals: RefusalSummary = {
        switch kind {
        case .remote:
            // Byte for byte as before this door was shared.
            return RefusalSummary(queue: queue, categories: ["unpaired", "internet", "limit"]) { c in
                let n = c.values.reduce(0, +)
                return "Remote access refused \(n) connection\(n == 1 ? "" : "s") in the last minute: \(c["unpaired", default: 0]) unpaired, "
                    + "\(c["internet", default: 0]) from the internet (internet access off), \(c["limit", default: 0]) over the limit."
            }
        case .home:
            return RefusalSummary(queue: queue, categories: ["unpaired", "vpn", "internet", "older", "limit"]) { c in
                let n = c.values.reduce(0, +)
                return "Home door refused \(n) connection\(n == 1 ? "" : "s") in the last minute: \(c["unpaired", default: 0]) unpaired, "
                    + "\(c["vpn", default: 0]) through a VPN, \(c["internet", default: 0]) from the internet, "
                    + "\(c["older", default: 0]) from an older Sill (not TLS), \(c["limit", default: 0]) over the limit."
            }
        }
    }()

    init(_ kind: DoorPolicy.Door, queue: DispatchQueue, identity: HostIdentity, trust: TrustBox, testHost: Bool) {
        self.kind = kind
        self.queue = queue
        self.identity = identity
        self.trust = trust
        self.testHost = testHost
        let environment = ProcessInfo.processInfo.environment
        var b: TimeInterval = 300
        if testHost, let v = environment["SILL_TEST_BACKOFF_SECONDS"], let s = Double(v), s > 0 { b = s }
        backoff = b
        cableStandIn = kind == .home ? CableLink.testInterface(testHost: testHost, environment: environment) : nil
    }

    /// The server's TLS options for this door's listener: the identity, both application
    /// protocols, a client certificate required, and the verify block (DoorPolicy.trusts). A new
    /// value for every listener (a Direct Wireless replacement builds its own).
    func tlsOptions() -> NWProtocolTLS.Options {
        RemoteTLS.options(identity: identity.remote.tls, role: .server, queue: queue) { [weak self] fp, alpn in
            self?.verify(fp, alpn) ?? false
        }
    }

    // MARK: Admission

    /// What DoorPolicy knows about a key, from the snapshot as it is now.
    private func trustFor(_ fp: Data?, _ t: TrustSnapshot) -> DoorPolicy.Trust {
        DoorPolicy.Trust(hasKey: fp != nil, paired: fp.map { t.paired[$0] != nil } ?? false, requirePairing: t.requirePairing,
                         remoteAccess: t.remoteAccess, internetAccess: t.internetAccess, pairingOpen: t.pairingOpen,
                         remotePairingOpen: t.remotePairingOpen)
    }

    /// On `queue`, in the TLS handshake: trust is the pin and the protocol, nothing else.
    private func verify(_ fp: Data?, _ alpn: String?) -> Bool {
        DoorPolicy.trusts(kind, alpn: alpn, trustFor(fp, trust.snapshot))
    }

    private func sourceText(_ c: NWConnection) -> String {
        guard case .hostPort(let host, _) = c.endpoint else { return "\(c.endpoint)" }
        return StreamServer.addressText(host).text
    }

    /// On `queue`: a new connection from the listener. `peerToPeer`: that listener included
    /// peer-to-peer Wi-Fi (the home door with Direct Wireless on; never the remote door).
    func accept(_ c: NWConnection, peerToPeer: Bool = false) {
        guard let server else { c.cancel(); return }
        let now = CFAbsoluteTimeGetCurrent()
        let source = sourceText(c)
        prune(now)
        if let until = backoffUntil[source], now < until {
            c.cancel()
            refusals.count("limit")
            return
        }
        // The origin before the connection starts: once started, TLS answers a ClientHello that is
        // already waiting with the whole server flight, the Mac's certificate included, before any
        // state callback could refuse it. A source this door does not admit gets no byte.
        if let a = server.arrivalBeforeStart(of: c, remoteDoor: kind == .remote),
           let word = DoorPolicy.refusalBeforeStart(kind, origin: a.origin, internetAccess: trust.snapshot.internetAccess) {
            c.cancel()
            refusals.count(word)
            countFailure(source, now)
            return
        }
        let fromSource = pending.values.filter { $0.source == source }.count
        guard pending.count < Self.maxPending, fromSource < Self.maxPendingPerSource else {
            c.cancel()
            refusals.count("limit")
            return
        }
        let id = ObjectIdentifier(c)
        let deadline = DispatchWorkItem { [weak self] in self?.deadlinePassed(id) }
        pending[id] = Pending(connection: c, source: source, peerToPeer: peerToPeer, deadline: deadline)
        queue.asyncAfter(deadline: .now() + Self.admissionDeadline, execute: deadline)
        c.stateUpdateHandler = { [weak self] state in self?.stateChanged(id, c, state) }
        c.start(queue: queue)
    }

    /// On `queue`: cancels every connection still waiting for admission that `match` names (Direct
    /// Wireless turned off: an ask or a proof in flight over peer-to-peer Wi-Fi). Its end is no
    /// refusal: nothing is counted.
    func cancelPending(where match: (NWConnection) -> Bool) {
        for p in pending.values where match(p.connection) { p.connection.cancel() }
    }

    private func stateChanged(_ id: ObjectIdentifier, _ c: NWConnection, _ state: NWConnection.State) {
        switch state {
        case .preparing:
            _ = checkOrigin(id, c)
        case .ready:
            readyArrived(id, c)
        case .failed(let e):
            c.cancel()
            endedBeforeAdmission(id, error: e)
        case .cancelled:
            endedBeforeAdmission(id, error: nil)
        default:
            break
        }
    }

    /// The origin, classified once from the connection's own path, judged as the switches are now:
    /// at `.preparing` (behind the check before start), again at `.ready` and at a pairing's kind
    /// 19, so the remote door's internet switch turned off during the handshake refuses a
    /// connection not yet admitted. Admitted ones are `closeSessions`' (RemoteAccess changes the
    /// snapshot before it queues that), so none slips between the two; one the device gate holds
    /// (the floor above "0") is neither pending nor a client yet, and `afterGate` judges it again as
    /// the gate admits it, from the same snapshot: admitted before the change, it is a client when
    /// `closeSessions` runs; after it, it is refused. False when refused, or no longer pending.
    private func checkOrigin(_ id: ObjectIdentifier, _ c: NWConnection) -> Bool {
        guard var p = pending[id], let server else { return false }
        if p.origin == nil {
            let (origin, interface) = server.arrival(of: c, remoteDoor: kind == .remote)
            p.origin = origin
            p.interface = interface
            pending[id] = p
        }
        let origin = p.origin ?? .internet
        if let word = DoorPolicy.refusalBeforeStart(kind, origin: origin, internetAccess: trust.snapshot.internetAccess) {
            refuse(id, word)
            c.cancel()
            return false
        }
        return true
    }

    private func readyArrived(_ id: ObjectIdentifier, _ c: NWConnection) {
        guard pending[id] != nil, checkOrigin(id, c), let server else { return }
        let fp = RemoteTLS.peerFingerprint(c)
        let t = trust.snapshot
        switch DoorPolicy.atReady(kind, alpn: RemoteTLS.negotiatedALPN(c), trustFor(fp, t), remoteSessions: server.remoteSessionCount) {
        case .session:
            guard let fp else { refuse(id, "unpaired"); c.cancel(); return }
            admitSession(id, c, fp, t)
        case .pairing:
            guard let fp else { refuse(id, "unpaired"); c.cancel(); return }
            readPairRequest(id, c, fp)
        case .goodbye(let reason):
            // A paired key the door does not serve now: it proved itself, so its source starts clean.
            // Closed with a FIN and a drain (`closeWithGoodbye`): the device has sent its hello by
            // now, and a cancel with it unread answered with a reset that could beat the goodbye.
            guard let p = pending.removeValue(forKey: id) else { return }
            p.deadline?.cancel()
            forgive(p.source)
            if reason == Goodbye.busy { refusals.count("limit") }
            StreamServer.closeWithGoodbye(Goodbye(reason: reason), on: c, queue: queue)
        case .refuse(let word):
            refuse(id, word)
            c.cancel()
        }
    }

    /// `sill/1`, judged again at `.ready`: the remote door's paired session (Remote Access on,
    /// fewer than 8 sessions), or the home door's session with its key (paired, or any key while
    /// Require pairing is off). A paired key clears its source. Then the device gate, here for both
    /// doors (StreamServer's `gate`): with the floor at "0" (every build so far) nothing waits; above
    /// it the session's first message inside TLS must be a hello the floor admits, and any other
    /// device gets the update goodbye and is never registered. While the gate reads (up to 2 s) the
    /// session is neither pending nor a client, so a change that closes sessions cannot see it: as
    /// the gate admits it, it is judged again from the snapshot as it is then (`afterGate`).
    /// Registered with its route (`serve`), then its line.
    private func admitSession(_ id: ObjectIdentifier, _ c: NWConnection, _ fp: Data, _ t: TrustSnapshot) {
        guard let server, let p = pending.removeValue(forKey: id) else { return }
        p.deadline?.cancel()
        let name = t.paired[fp]
        if name != nil { forgive(p.source) }
        if kind == .remote, name == nil { c.cancel(); return }    // atReady admits only a paired key here
        let origin = p.origin ?? .loopback
        // Home: the iPhone or iPad behind the cable, read once, as the session is admitted.
        let cable = kind == .home ? cableDevice(of: c).flatMap { $0.serial }.map(CableLink.deviceID) : nil
        server.gate(c) { [weak self] hello in
            guard let self, let server = self.server else { c.cancel(); return }
            var snapshot = t
            if let hello {
                // Held by the gate: judged again as it is now.
                snapshot = self.trust.snapshot
                if let reason = DoorPolicy.afterGate(self.kind, wasPaired: name != nil, origin: origin, self.trustFor(fp, snapshot),
                                                     remoteSessions: server.remoteSessionCount) {
                    self.closeAfterGate(c, reason, name: name ?? SafeText.label(hello.device ?? ""))
                    return
                }
                if self.kind == .home, server.droppedForDirectWireless(c, acceptedPeerToPeer: p.peerToPeer, hello: hello) { return }
            }
            let endpoint = "\(c.endpoint)"
            switch self.kind {
            case .remote:
                guard let paired = snapshot.paired[fp] else { c.cancel(); return }
                let label = OriginPolicy.label(origin, interface: p.interface, serviceName: p.interface.flatMap { snapshot.serviceNames[$0] }) ?? "by address"
                server.serve(c, route: .remote(origin: origin, label: label, fingerprint: fp, name: paired), hello: hello,
                             admitted: { print("Remote client connected: \(paired) \(label) (\(endpoint))") })
            case .home:
                let peer = ClientRoute.Peer(fingerprint: fp, name: snapshot.paired[fp], cableDevice: cable)
                server.serve(c, route: .home(origin, peer: peer), hello: hello, admitted: { print("Client connected: \(endpoint)") })
            }
        }
    }

    /// A session the gate held that `afterGate` refused: the line the change's own `closeSessions`
    /// prints (Remove, Require pairing, Remote Access, internet access; the limit is counted, as at
    /// `.ready`), then the goodbye and the close (`closeWithGoodbye`), never registered. `name`: its
    /// paired name, else the hello's device name. On `queue`.
    private func closeAfterGate(_ c: NWConnection, _ reason: String, name: String) {
        let who = name.isEmpty ? "a device" : name
        let endpoint = "\(c.endpoint)"
        switch reason {
        case Goodbye.removed: print("Removed \(who): disconnecting it at \(endpoint).")
        case Goodbye.remoteOff: print("Remote access off: disconnecting \(who) at \(endpoint).")
        case Goodbye.internetOff: print("Internet access off: disconnecting \(who) at \(endpoint).")
        case Goodbye.pairingRequired: print("Require pairing: disconnecting \(who) at \(endpoint), which isn’t paired.")
        case Goodbye.busy: refusals.count("limit")
        default: break
        }
        StreamServer.closeWithGoodbye(Goodbye(reason: reason), on: c, queue: queue)
    }

    /// `sill-pair/1`: exactly one kind 19 of at most 4 KB within the admission deadline, then
    /// DoorPolicy.pairing says how it is treated: judged on the main actor (an ask at home, or a
    /// proof for the pairing window), or, for an ask at the remote door and for a request of a
    /// later generation (`v` not 1) at either, answered `closed` here with no try counted. One
    /// kind 20 back, then closed once that is sent (or after 250 ms). A
    /// device that goes away before its kind 19 is not refused, only closed. Pairing is never
    /// refused for the device's age (DeviceGate judges sessions only): a device too old for this
    /// Mac's sessions can still pair, and hears the update notice when it connects.
    private func readPairRequest(_ id: ObjectIdentifier, _ c: NWConnection, _ fp: Data) {
        c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data else { c.cancel(); return }
            guard let h = StreamMessage.parseHeader(data), h.kind == .pairRequest,
                  h.payloadLength > 0, h.payloadLength <= StreamMessage.maxPairingPayload else {
                self.refuse(id, "unpaired")
                c.cancel()
                return
            }
            c.receive(minimumIncompleteLength: h.payloadLength, maximumLength: h.payloadLength) { [weak self] data, _, _, _ in
                guard let self else { return }
                guard let data else { c.cancel(); return }
                guard let request = Wire.decode(PairRequest.self, from: data) else {
                    self.refuse(id, "unpaired")
                    c.cancel()
                    return
                }
                // The switches as they are now (the internet switch may have gone off since
                // `.ready`). Gone from `pending`: the deadline passed while the payload came in.
                guard self.checkOrigin(id, c), let p = self.pending.removeValue(forKey: id) else { c.cancel(); return }
                p.deadline?.cancel()
                let queue = self.queue
                let reply: @Sendable (PairResult) -> Void = { result in
                    queue.async {
                        let message = StreamMessage(kind: .pairResult, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                                    payload: Wire.encode(result)).serialized()
                        c.send(content: message, completion: .contentProcessed { _ in c.cancel() })
                        queue.asyncAfter(deadline: .now() + 0.25) { c.cancel() }
                    }
                }
                if DoorPolicy.pairing(self.kind, method: request.method, version: request.v) == .closed {
                    reply(PairResult(ok: false, reason: PairResult.closed))
                    return
                }
                guard let judge = self.onPairAttempt else { c.cancel(); return }
                judge(self.attempt(request, fp, c, p), reply)
            }
        }
    }

    /// The attempt as RemoteAccess judges it. At home: the address with its scope, whether it is
    /// this Mac itself, and the cable, each read afresh for this connection.
    private func attempt(_ request: PairRequest, _ fp: Data, _ c: NWConnection, _ p: Pending) -> PairAttempt {
        let origin = p.origin ?? .internet
        guard kind == .home, let s = Self.source(of: c) else {
            return PairAttempt(door: kind, request: request, deviceFingerprint: fp, source: p.source, display: p.source, origin: origin,
                               interface: p.interface, fromThisMac: false, cable: nil)
        }
        let own = InterfaceSnapshot.ownAddresses()
        return PairAttempt(door: kind, request: request, deviceFingerprint: fp, source: p.source,
                           display: s.display, origin: origin, interface: p.interface,
                           fromThisMac: DoorPolicy.isFromThisMac(source: s.bytes, ownAddresses: own),
                           cable: cableDevice(s, ownAddresses: own))
    }

    /// The iPhone or iPad a home connection came over by the USB cable, by the Mac's rule
    /// (CableLink.device), its arrival interface's ancestry read afresh: a device swapped for
    /// another keeps the interface's name.
    func cableDevice(of c: NWConnection) -> CableLink.Ancestry? {
        guard kind == .home, let s = Self.source(of: c) else { return nil }
        return cableDevice(s, ownAddresses: InterfaceSnapshot.ownAddresses())
    }

    private func cableDevice(_ s: (bytes: [UInt8], scope: String?, display: String), ownAddresses: Set<[UInt8]>) -> CableLink.Ancestry? {
        guard let scope = s.scope else { return nil }
        let reading = InterfaceSnapshot.readCable(scope)
        var cables: [String: CableLink.Ancestry] = [:]
        if let a = reading.ancestry { cables[scope] = a }
        return CableLink.device(source: s.bytes, scope: scope, ownAddresses: ownAddresses, cables: cables, standIn: cableStandIn)
    }

    /// A connection's source: its bytes (4 or 16), the interface a link-local IPv6 address is
    /// scoped to, and the address as the log names it ("fe80::1%en0", "10.0.0.5").
    static func source(of c: NWConnection) -> (bytes: [UInt8], scope: String?, display: String)? {
        guard case .hostPort(let host, _) = c.endpoint else { return nil }
        let bytes: [UInt8]
        let interface: String?
        switch host {
        case .ipv4(let a): bytes = [UInt8](a.rawValue); interface = a.interface?.name
        case .ipv6(let a): bytes = [UInt8](a.rawValue); interface = a.interface?.name
        default: return nil
        }
        let scope = bytes.count == 16 && IPBytes.isLinkLocal(bytes) ? (interface ?? OriginPolicy.scope(ofEndpoint: "\(c.endpoint)")) : nil
        let text = IPBytes.text(IPBytes.unmapped(bytes))
        return (bytes, scope, text + (scope.map { "%\($0)" } ?? ""))
    }

    /// The door refuses a pending connection: one count for the minute's summary (once per
    /// connection), and its end then counts one failure for its source.
    private func refuse(_ id: ObjectIdentifier, _ category: String) {
        guard var p = pending[id], !p.refused else { return }
        p.refused = true
        pending[id] = p
        refusals.count(category)
    }

    private func deadlinePassed(_ id: ObjectIdentifier) {
        guard let p = pending[id] else { return }
        refuse(id, "unpaired")
        p.connection.cancel()        // `.cancelled` then counts the failure
    }

    /// A connection that ended before it was admitted counts one failure for its source (5 in 60 s
    /// → a backoff) only when the door refused it: marked by `refuse`, or a handshake the door
    /// failed (DoorPolicy.handshakeRefusal, counted for the summary here). A peer that went away by
    /// itself counts for nothing, so a device cancelling the losers of its own staggered dial, or
    /// giving up on a Mac whose key it no longer pins, never locks its address out; nor does an
    /// older Sill's plain try at the home door (-9836), which is counted and shown instead, so an
    /// iPad updated after a few plain retries is not refused for 5 minutes.
    private func endedBeforeAdmission(_ id: ObjectIdentifier, error: NWError?) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.deadline?.cancel()
        var refused = p.refused
        if !refused, let error, let status = RemoteTLS.status(of: error) {
            switch DoorPolicy.handshakeRefusal(kind, status: status) {
            case .refused(let word)?:
                refused = true
                refusals.count(word)
            case .olderSill?:
                refusals.count("older")
                let seen = DoorPolicy.olderSillTry(olderTries[p.source] ?? [], now: CFAbsoluteTimeGetCurrent())
                olderTries[p.source] = seen.tries
                if seen.shown { onOlderSill?() }
            case nil:
                break
            }
        }
        if refused { countFailure(p.source, CFAbsoluteTimeGetCurrent()) }
    }

    /// One failure for `source`; the fifth within a minute starts its backoff.
    private func countFailure(_ source: String, _ now: CFAbsoluteTime) {
        var list = (failures[source] ?? []).filter { now - $0 < Self.failureWindow }
        list.append(now)
        if list.count >= Self.failuresForBackoff {
            backoffUntil[source] = now + backoff
            list = []
        }
        failures[source] = list
    }

    /// A source that proved itself (a paired key at `.ready`) starts clean: what its earlier
    /// attempts cost is not held against it.
    private func forgive(_ source: String) {
        failures[source] = nil
        backoffUntil[source] = nil
    }

    /// Forgets stale per-source records, so a scan from many addresses cannot grow them for ever.
    private func prune(_ now: CFAbsoluteTime) {
        if failures.count > 256 { failures = failures.filter { $0.value.contains { now - $0 < Self.failureWindow } } }
        if backoffUntil.count > 256 { backoffUntil = backoffUntil.filter { $0.value > now } }
        if olderTries.count > 256 { olderTries = olderTries.filter { $0.value.contains { now - $0 < DoorPolicy.olderSillSpan } } }
    }
}

extension InterfaceSnapshot.CableReading {
    /// As CableLink judges it: the first USB host device above the interface; nil when none is.
    var ancestry: CableLink.Ancestry? {
        guard usbDevice else { return nil }
        return CableLink.Ancestry(ncm: ncm, vendor: vendor, productName: productName, serial: serial, session: session)
    }
}
