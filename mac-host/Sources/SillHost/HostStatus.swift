import Foundation
import Observation
import StreamProtocol

/// What the host is doing, as plain values for the menu bar app: the menu, the status item and
/// Settings read it; nothing in the host reads it back. The coordinator pushes a change at the
/// moment it happens (listener state, a device in or out, its once-a-second stats, a pipeline
/// started or stopped, an encoder or virtual display fallback), so nothing polls and an idle host
/// stays idle.
///
/// Not Sendable on purpose: it lives on the main actor with `HostStatus`, and marking these
/// structs Sendable only produced warnings.
package struct HostStatusSnapshot: Equatable {
    /// The listener and its Bonjour registration.
    package enum Network: Equatable {
        case starting
        /// Listening; Bonjour has not confirmed a name yet.
        case registering
        /// The name devices see. Bonjour renames on a clash ("Noah’s MacBook Pro (2)").
        case advertising(String)
        /// --synthetic: listening but deliberately off Bonjour; test clients use this port.
        case notAdvertised(port: Int)
        /// The listener waits for a usable network (no Wi-Fi or Ethernet, Local Network denied).
        case waiting(String)
        /// The listener failed; devices cannot reach this host until Sill restarts.
        case failed(String)
    }

    /// One connected device. The name and numbers come from its ClientStats, about once a second;
    /// nil until the first report.
    package struct Device: Equatable, Identifiable {
        package let id: ObjectIdentifier
        package var endpoint: String
        /// The device's own description, such as "iPad (iPad14,1)".
        package var name: String?
        package var fps: Int?
        /// What the device measured over its last second (a current client sends the medians);
        /// -1 when that second had no sample (no frame arrived, no pong came back).
        package var frameAgeMs: Int?
        package var rttMs: Int?
        /// How it reaches this Mac, as this Mac's side of its connection says (ClientLink.route): at
        /// connect, then whenever the connection's path changes. Nil when the connection does not
        /// say (loopback, a VPN, an interface of no known kind), and always on the remote door.
        /// Shown, never acted on.
        package var route: ClientLink.Route?
        /// Nil on the home door; "through Tailscale", "through your VPN", "over the internet" or "by
        /// address" on the remote door. The card shows it instead of `route` (StatusText).
        package var remoteRoute: String?
        /// Its link while it does not keep up (LinkJudge, docs/remote-bundle-plan.md §6); nil while it
        /// does. The card names it.
        package var link: LinkStatus?

        package init(id: ObjectIdentifier, endpoint: String, name: String? = nil, fps: Int? = nil,
                     frameAgeMs: Int? = nil, rttMs: Int? = nil, route: ClientLink.Route? = nil, remoteRoute: String? = nil,
                     link: LinkStatus? = nil) {
            self.id = id; self.endpoint = endpoint; self.name = name
            self.fps = fps; self.frameAgeMs = frameAgeMs; self.rttMs = rttMs
            self.route = route; self.remoteRoute = remoteRoute; self.link = link
        }
    }

    /// A device's link that does not keep up, as the card shows it: behind (the link cannot carry
    /// the running quality) or stalled (nothing gets through either way), what was withheld, the
    /// quality, what the link carried, and what would fit.
    package struct LinkStatus: Equatable {
        package enum State: Equatable { case behind, stalled }
        package var state: State
        package var withheld: Int
        /// The running quality's bitrate, per 60 fps.
        package var bitrate: Int
        package var carriedKbps: Int?
        package var suggestedBitrate: Int?
        package var suggestedCaptureScale: Double?

        package init(state: State, withheld: Int, bitrate: Int, carriedKbps: Int? = nil,
                     suggestedBitrate: Int? = nil, suggestedCaptureScale: Double? = nil) {
            self.state = state; self.withheld = withheld; self.bitrate = bitrate; self.carriedKbps = carriedKbps
            self.suggestedBitrate = suggestedBitrate; self.suggestedCaptureScale = suggestedCaptureScale
        }
    }

    /// The running pipeline, as it was last started.
    package struct Stream: Equatable {
        package enum Kind: Equatable { case window, desktop, testPattern }
        package var kind: Kind
        /// "Safari — Apple Developer", "Whole Desktop" or "Test Pattern".
        package var title: String
        package var width: Int
        package var height: Int
        package var fps: Int
        package var mbps: Int
        /// Captured from the virtual display (the window was staged there).
        package var onVirtualDisplay: Bool
        package var softwareEncoder: Bool

        package init(kind: Kind, title: String, width: Int, height: Int, fps: Int, mbps: Int,
                     onVirtualDisplay: Bool, softwareEncoder: Bool) {
            self.kind = kind; self.title = title; self.width = width; self.height = height
            self.fps = fps; self.mbps = mbps; self.onVirtualDisplay = onVirtualDisplay
            self.softwareEncoder = softwareEncoder
        }
    }

    package var network: Network = .starting
    package var devices: [Device] = []
    package var stream: Stream?
    /// Frames the encoder put out in the last stats second (the stats line's `enc.out`).
    package var encodedFPS = 0
    /// The hardware encoder did not answer (launch probe or a hang): the software encoder carries
    /// every stream until a re-check finds the hardware keeping up with the stream (every 30 s
    /// while a device is connected, backing off to 300 s), which clears it.
    package var softwareEncoder = false
    /// With `softwareEncoder`: so many checks have not got their frame back that the encoder is
    /// stuck, not busy, and the re-check has stopped probing it (a restart of the Mac fixes that).
    /// Cleared as soon as one of those frames comes back.
    package var hardwareEncoderStuck = false
    /// The virtual display setting as the host runs it.
    package var virtualDisplayOn = false
    /// Why the virtual display is off for this run: the private API is missing, or the system took
    /// the display away too often. Nil when it is available.
    package var virtualDisplayProblem: String?
    /// `virtualDisplayProblem` is the private API check (nothing to retry until macOS changes).
    package var virtualDisplayAPIMissing = false
    /// Why the last pick streamed the real window instead of the virtual display; cleared by the
    /// next successful stage.
    package var lastStageFailure: String?
    /// --synthetic: the Desktop is a test pattern and the host is not advertised.
    package var synthetic = false
    /// Remote access, on a host with an identity (Sill.app, SillHost --remote); nil otherwise.
    package var remote: RemoteStatus?
    /// Away from home (docs/remote-bundle-plan.md §5): at least one device is connected and every
    /// connected device is away, so the away quality is the target. The menu's Quality subtitle
    /// and the Streaming pane say so.
    package var away = false

    /// Devices connected through the remote door: while any is, the app keeps the Mac from idle
    /// sleep (it could not be woken from away).
    package var remoteDeviceCount: Int { devices.filter { $0.remoteRoute != nil }.count }

    package init() {}
}

extension HostStatusSnapshot.Stream {
    /// The running pipeline as a device sees it (kind 16's `stream`).
    var wire: RunningStream {
        RunningStream(width: width, height: height, fps: fps, mbps: mbps, onVirtualDisplay: onVirtualDisplay)
    }
}

/// Both doors' pairing and the remote door as the Mac's panes and menu show them. Never a pairing
/// code or secret: those reach the app and the CLI only through `RemoteAccess.onPairingOffer`.
package struct RemoteStatus: Equatable {
    /// The home door (docs/home-pairing-plan.md §4.10): plain (the CLI without --pairing), TLS with
    /// pairing required or open to any device, or unavailable, with why (no identity: the keychain
    /// failed, so there is no home listener at all).
    package enum HomeDoor: Equatable {
        case plain, pairingRequired, open
        case unavailable(String)
    }
    /// A device asked to pair and no window shows its code by itself (the Mac locked, or the ask
    /// limits), or a window shows its code (one its ask opened, or one the Mac's user opened from
    /// this request): the menu's "‹device› Wants to Pair", for 5 minutes after the ask, less once
    /// that device pairs or, for "showing", once the window closes. Never for an ask from this Mac.
    package struct PairingRequest: Equatable {
        /// The device's own name, cleaned: "iPad (iPad14,1)".
        package var name: String
        package var at: Date
        /// "showing" (a window it opened is up), "locked" or "limit" (quiet, or too many windows).
        package var reason: String
        package init(name: String, at: Date, reason: String) { self.name = name; self.at = at; self.reason = reason }
        /// How long the menu shows it.
        package static let shownFor: TimeInterval = 300
    }

    package enum Listener: Equatable {
        case off
        case listening(Int)
        /// EADDRINUSE: another app has the port; retried every 30 s and on network changes.
        case portInUse(Int)
        case failed(String)
    }
    /// The router's own internet address, asked read-only while the internet switch is on.
    package enum Router: Equatable {
        case off, asking
        case address(String)
        /// The router's address is itself in 100.64/10: the provider shares it among many homes.
        case carrierNAT(String)
        /// The router sits behind another router (a private address, or kDNSServiceErr_DoubleNAT).
        case doubleNAT
        case noAnswer
    }
    package enum Pairing: Equatable {
        case closed
        /// `byDevice`: a device opened it by asking (shown in front without the keyboard).
        case open(requestedBy: String?, expiresAt: Date, triesLeft: Int, lastWrongFrom: String?, byDevice: Bool)
        /// The last window paired this device (its name).
        case paired(String)
        /// Five wrong codes.
        case stopped
        case expired
    }

    package var remoteAccess: Bool
    package var internetAccess: Bool
    package var listener: Listener
    /// In dial order, as kind 18 carries them.
    package var addresses: [MacAddress]
    /// Named VPN services with no address: "Tailscale" shows as "Tailscale — Not connected".
    package var vpnDown: [String]
    /// This network's address, for the port-forward instruction and the typed pairing path.
    package var lanAddress: String?
    package var router: Router
    /// The address name setting, as shown.
    package var addressName: String
    package var pairing: Pairing
    package var paired: [PairedDeviceSummary]
    /// "The keychain couldn’t be used: …" when the identity could not be loaded.
    package var identityProblem: String?
    package var homeDoor: HomeDoor
    package var pairingRequest: PairingRequest?
    /// When the home door last refused a source's third plain try within a minute (an older Sill,
    /// DoorPolicy.olderSillTry: a TLS 1.2 client fails the same way, but once), for the menu's
    /// "An iPhone or iPad Needs Sill Updated" (10 minutes from it).
    package var olderDeviceAt: Date?

    package init(remoteAccess: Bool = false, internetAccess: Bool = false, listener: Listener = .off, addresses: [MacAddress] = [],
                 vpnDown: [String] = [], lanAddress: String? = nil, router: Router = .off, addressName: String = "",
                 pairing: Pairing = .closed, paired: [PairedDeviceSummary] = [], identityProblem: String? = nil,
                 homeDoor: HomeDoor = .plain, pairingRequest: PairingRequest? = nil, olderDeviceAt: Date? = nil) {
        self.remoteAccess = remoteAccess; self.internetAccess = internetAccess; self.listener = listener
        self.addresses = addresses; self.vpnDown = vpnDown; self.lanAddress = lanAddress; self.router = router
        self.addressName = addressName; self.pairing = pairing; self.paired = paired; self.identityProblem = identityProblem
        self.homeDoor = homeDoor; self.pairingRequest = pairingRequest; self.olderDeviceAt = olderDeviceAt
    }
}

/// One paired device as the pane lists it.
package struct PairedDeviceSummary: Equatable, Identifiable {
    /// The device's full fingerprint (base64url): what Remove and Rename name.
    package var id: String
    /// "5KD2Q7": the first characters of the fingerprint in Crockford form, for display.
    package var keyPrefix: String
    package var name: String
    package var model: String?
    package var pairedAt: Date
    /// "qr", "code" or "cable".
    package var method: String
    /// "with the QR code", "with a code", "over the USB cable"; nil for a method this build does
    /// not know (PairedDevice.displayMethod).
    package var displayMethod: String? { PairedDevice.displayMethod(method) }
    /// When it last connected, and how: from away ("through Tailscale") or at home ("over the USB
    /// cable", "over Wi‑Fi", "directly"…); nil when it never has (the app keeps these across
    /// launches).
    package var lastSeen: Date?
    package var lastRoute: String?

    package init(id: String, keyPrefix: String, name: String, model: String?, pairedAt: Date, method: String,
                 lastSeen: Date? = nil, lastRoute: String? = nil) {
        self.id = id; self.keyPrefix = keyPrefix; self.name = name; self.model = model; self.pairedAt = pairedAt
        self.method = method; self.lastSeen = lastSeen; self.lastRoute = lastRoute
    }
}

/// The observable holder of the snapshot. The coordinator writes it (main actor, only when a value
/// actually changes); SwiftUI and the app's observation loop read it.
@MainActor @Observable
package final class HostStatus {
    package internal(set) var snapshot = HostStatusSnapshot()
    /// Called right after `snapshot` really changed, never for an update that changed nothing. The
    /// coordinator re-publishes the devices' settings state from here, which is how a stream
    /// starting, an encoder fallback or a virtual display problem reaches them. It must never call
    /// `update` itself.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init() {}

    /// Applies `change` to a copy and stores it only if something differs, so observers wake for
    /// real changes and not for every once-a-second stats report that says the same thing.
    func update(_ change: (inout HostStatusSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        if next != snapshot { snapshot = next; onChange?() }
    }
}
