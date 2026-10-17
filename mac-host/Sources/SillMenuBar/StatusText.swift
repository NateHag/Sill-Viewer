import Foundation
import SillHostCore
import StreamProtocol

/// Everything the status item, its card and its menu say, as plain values. Made by
/// `StatusText.present` from the host's snapshot, so the same words appear in the menu, the
/// tooltip, the log's "Status:" lines and the previews.
struct StatusPresentation: Equatable {
    /// A line with a symbol: the stream's source, or one device.
    struct Row: Equatable, Identifiable {
        var id: String
        var symbol: String
        var title: String
        var detail: String?
    }

    /// Something that needs the user, shown in the menu with an orange warning.
    struct Attention: Equatable, Identifiable {
        enum Action: Equatable {
            case allowScreenRecording, allowAccessibility, showRemoteAccess, showDevices
            /// "‹device› Wants to Pair": its window forward while it shows the code (`showing`), else
            /// a window opened on the Mac, asked by that device (its paired-style name).
            case pairingRequest(name: String, showing: Bool)
            case none
        }
        var title: String
        var subtitle: String
        var action: Action
        var id: String { title }
    }

    var glyph: StatusGlyph.State
    var header: String
    var subtitle: String?
    var source: Row?
    var devices: [Row]
    var attention: [Attention]
    /// Under the menu's Virtual Display item.
    var virtualDisplayNote: String
    var tooltip: String
    var accessibilityLabel: String
    /// The name devices see this Mac as, once Bonjour has registered it.
    var advertisedName: String?
    /// Under the menu's Remote Access… item: "Off", "On · Tailscale"… Nil on a host without
    /// remote access (no item then).
    var remoteAccessNote: String?
    /// Pair iPhone or iPad… can open a pairing window (the Mac has an identity).
    var canPair = false
    /// Every connected device is away from home, so the away quality is the target: the menu's
    /// Quality subtitle says so (docs/remote-bundle-plan.md §5.7).
    var away = false
}

/// Whether Sill holds its two permissions, as last read.
struct PermissionState: Equatable {
    var screenRecording: Bool
    var accessibility: Bool
}

/// The status copy. Title case in menus, sentence case in explanations, typographic quotes.
enum StatusText {
    /// How long the menu says an iPhone or iPad needs Sill updated after the home door refused one
    /// of its plain connections (docs/home-pairing-plan.md §6.4).
    static let olderDeviceShownFor: TimeInterval = 600

    /// `now`: the clock the menu's items that last a while are judged by (fixed in the previews).
    static func present(snapshot s: HostStatusSnapshot, permissions: PermissionState,
                        startupError: String?, hasCoordinator: Bool, now: Date = Date()) -> StatusPresentation {
        let (header, subtitle) = headline(s, permissions, startupError, hasCoordinator)

        var attention: [StatusPresentation.Attention] = []
        if !permissions.screenRecording {
            attention.append(.init(title: "Allow Screen Recording…", subtitle: "Needed to show your windows on your devices.",
                                   action: .allowScreenRecording))
        }
        if !permissions.accessibility {
            attention.append(.init(title: "Allow Accessibility…", subtitle: "Devices can watch but not click or type.",
                                   action: .allowAccessibility))
        }
        // Kept to one line no wider than the rest of the menu: a menu item's subtitle does not wrap.
        if s.softwareEncoder, s.hardwareEncoderStuck {
            attention.append(.init(title: "Hardware Encoder Stuck",
                                   subtitle: "Streaming with the software encoder, up to 60 fps. Restarting the Mac fixes this.",
                                   action: .none))
        } else if s.softwareEncoder {
            attention.append(.init(title: "Hardware Encoder Busy",
                                   subtitle: "Streaming with the software encoder, up to 60 fps, until it is free again.",
                                   action: .none))
        }
        let remotePortTaken = remotePortInUse(s.remote)
        if let port = remotePortTaken {
            attention.append(.init(title: "Remote Access Can’t Start", subtitle: "Port \(port) is in use by another app.",
                                   action: .showRemoteAccess))
        }
        // Pairing at home (docs/home-pairing-plan.md §6.4).
        let request = pairingRequest(s.remote, now: now)
        if let request { attention.append(request) }
        if let at = s.remote?.olderDeviceAt, now.timeIntervalSince(at) < olderDeviceShownFor {
            attention.append(.init(title: "An iPhone or iPad Needs Sill Updated", subtitle: "It tried to connect with an older Sill.",
                                   action: .none))
        }
        let homeDoorClosed = homeDoorUnavailable(s.remote)
        if homeDoorClosed {
            attention.append(.init(title: "Devices Can’t Connect", subtitle: "Sill couldn’t use its key in your keychain.",
                                   action: .showDevices))
        }

        // The attention glyph means "Sill needs you". The test pattern needs no permission. A device
        // waiting to pair and a closed home door need the user too; an older device is only news.
        let glyph: StatusGlyph.State
        if startupError != nil || isFailed(s.network) || remotePortTaken != nil || request != nil || homeDoorClosed
            || (!s.synthetic && !(permissions.screenRecording && permissions.accessibility)) {
            glyph = .attention
        } else if s.stream != nil {
            glyph = .streaming
        } else if !s.devices.isEmpty {
            glyph = .connected
        } else {
            glyph = .idle
        }

        var name: String?
        if case .advertising(let n) = s.network { name = n }

        return StatusPresentation(glyph: glyph, header: header, subtitle: subtitle,
                                  source: sourceRow(s), devices: s.devices.map(deviceRow), attention: attention,
                                  virtualDisplayNote: virtualDisplayNote(s),
                                  tooltip: "Sill — \(header)", accessibilityLabel: "Sill, \(header)",
                                  advertisedName: name, remoteAccessNote: remoteAccessNote(s.remote),
                                  canPair: s.remote.map { $0.identityProblem == nil } ?? false, away: s.away)
    }

    /// "iPad Wants to Pair", for 5 minutes after a device's ask (the host ends it sooner: when the
    /// window showing its code closes, and when that device pairs): "A code is showing." while that
    /// window is up, "Click to show a code." when the ask limits kept one from opening, the unlock
    /// line when this Mac was locked. Sentences with a full stop, as every attention subtitle is.
    /// Never for an ask from this Mac itself (the host sets none).
    private static func pairingRequest(_ r: RemoteStatus?, now: Date) -> StatusPresentation.Attention? {
        guard let request = r?.pairingRequest, now.timeIntervalSince(request.at) < RemoteStatus.PairingRequest.shownFor else { return nil }
        let short = shortName(request.name)
        let subtitle: String
        switch request.reason {
        case "showing": subtitle = "A code is showing."
        case "locked": subtitle = "Unlock this Mac, then tap it on the \(short) again."
        default: subtitle = "Click to show a code."
        }
        return .init(title: "\(short) Wants to Pair", subtitle: subtitle,
                     action: .pairingRequest(name: request.name, showing: request.reason == "showing"))
    }

    /// The home door has no listener: the identity (its key, the trust list) could not be used.
    private static func homeDoorUnavailable(_ r: RemoteStatus?) -> Bool {
        if case .unavailable? = r?.homeDoor { return true }
        return false
    }

    /// The remote door's port while Remote Access is on and another app holds that port.
    private static func remotePortInUse(_ r: RemoteStatus?) -> Int? {
        guard let r, r.remoteAccess, r.identityProblem == nil, case .portInUse(let port) = r.listener else { return nil }
        return port
    }

    /// The Remote Access… item's subtitle: "Off", "On · Tailscale", "On · Tailscale and the
    /// internet", "On · no VPN on this Mac", "Port 7455 is in use" or "Unavailable: the keychain
    /// couldn’t be used".
    static func remoteAccessNote(_ r: RemoteStatus?) -> String? {
        guard let r else { return nil }
        if r.identityProblem != nil { return "Unavailable: the keychain couldn’t be used" }
        guard r.remoteAccess else { return "Off" }
        switch r.listener {
        case .portInUse(let port): return "Port \(port) is in use"
        case .failed: return "Couldn’t start; trying again"
        case .off, .listening: break
        }
        var ways: [String] = []
        for a in r.addresses where a.kind == MacAddress.vpn && !ways.contains(a.via) { ways.append(a.via) }
        if r.internetAccess { ways.append("the internet") }
        guard let last = ways.last else { return "On · no VPN on this Mac" }
        return "On · " + (ways.count == 1 ? last : ways.dropLast().joined(separator: ", ") + " and " + last)
    }

    /// The header and its explanation; the first match wins.
    private static func headline(_ s: HostStatusSnapshot, _ permissions: PermissionState, _ startupError: String?,
                                 _ hasCoordinator: Bool) -> (String, String?) {
        if let startupError { return ("Sill Couldn’t Start", startupError) }
        if !hasCoordinator { return ("Starting…", nil) }
        // No listener at all (fail closed): no device can find or reach this Mac.
        if homeDoorUnavailable(s.remote) {
            return ("Not Visible on the Network",
                    "Sill couldn’t use its key in your keychain. Quit Sill and open it again, and choose Always Allow if the keychain asks.")
        }
        switch s.network {
        case .starting:
            return ("Starting…", nil)
        case .failed(let error):
            return ("Not Visible on the Network", "\(error). Quit and reopen Sill to try again.")
        case .waiting:
            return ("Waiting for the Network",
                    "Sill appears on your iPhone and iPad once this Mac is on Wi-Fi or Ethernet and Local Network access is allowed.")
        case .notAdvertised(let port):
            return ("Test Pattern Mode", "Not advertised; test clients connect to port \(port).")
        case .registering, .advertising:
            break
        }
        if !permissions.screenRecording {
            return ("Screen Recording Is Off", "Devices can connect but can’t see any windows.")
        }
        let count = s.devices.count
        if count > 0 {
            let who = count == 1 ? (s.devices[0].name.map(shortName) ?? "a Device") : "\(count) Devices"
            if s.stream != nil { return ("Streaming to \(who)", nil) }
            let connected = count == 1 ? (s.devices[0].name.map(shortName) ?? "Device") : "\(count) Devices"
            return ("\(connected) Connected", "Pick a window on the device to start streaming.")
        }
        if case .advertising(let name) = s.network {
            return ("Waiting for a Device", "Open Sill on your iPhone or iPad. This Mac appears as “\(name)”.")
        }
        return ("Waiting for a Device", "Registering on the local network…")
    }

    private static func isFailed(_ n: HostStatusSnapshot.Network) -> Bool {
        if case .failed = n { return true }
        return false
    }

    /// "iPad" from "iPad (iPad14,1)".
    static func shortName(_ device: String) -> String {
        let name = device.components(separatedBy: " (").first ?? device
        return name.isEmpty ? device : name
    }

    /// What streams: "Safari — Apple Developer" over "3024×1898 · 118 of 120 fps · 30 Mbps" (a still
    /// picture: "120 fps, still"), and with one device, how it is connected: "… · 30 Mbps · Wi-Fi".
    /// With two or more, each device's own row says it.
    private static func sourceRow(_ s: HostStatusSnapshot) -> StatusPresentation.Row? {
        guard let stream = s.stream else { return nil }
        let title: String, symbol: String
        switch stream.kind {
        case .window: title = middleTruncated(stream.title, to: 44); symbol = "macwindow"
        case .desktop: title = "Whole Desktop"; symbol = "menubar.dock.rectangle"
        case .testPattern: title = "Test Pattern"; symbol = "checkerboard.rectangle"
        }
        // The encoder only produces a frame when the picture changed (ScreenCaptureKit delivers
        // frames on repaint), so 0 means a still window, not a stalled stream. "120 fps, still" is
        // about as wide as a one-digit count ("5 of 120 fps"), so a row wraps the same still as
        // changing, unless the count's own digits tip it: the open menu resizes the card on every
        // change, and "nothing changing" with the route word made it jump a line each time a
        // window stopped or started changing.
        let rate = s.encodedFPS > 0 ? "\(min(s.encodedFPS, stream.fps)) of \(stream.fps) fps" : "\(stream.fps) fps, still"
        var detail = "\(stream.width)×\(stream.height) · \(rate) · \(stream.mbps) Mbps"
        if s.devices.count == 1, let route = routeWord(s.devices[0]) { detail += " · \(route)" }
        if stream.onVirtualDisplay {
            detail += " · virtual display"
        } else if s.virtualDisplayOn, stream.kind == .window {
            detail += " · real window (virtual display: \(s.lastStageFailure ?? s.virtualDisplayProblem ?? "unavailable"))"
        }
        if stream.softwareEncoder { detail += " · software encoder" }
        return StatusPresentation.Row(id: "source", symbol: symbol, title: title, detail: detail)
    }

    /// "iPad (iPad14,1)" over "118 fps · frame age 9 ms · RTT 7 ms · Wi-Fi" (from away: "… · through
    /// Tailscale"); the address until the device's first report (within a second; a remote device
    /// shows its paired name), and until then the route alone. A second without a sample reads
    /// "–", as in the host's log line and the device's HUD: a still window sends no frames
    /// (ScreenCaptureKit delivers only repaints), and a second can pass without a pong. While its
    /// link does not keep up (docs/remote-bundle-plan.md §6.6) the numbers give way to it, the frame
    /// age dropping out to keep the row short: "3 fps, the link can’t carry Pro · RTT 531 ms ·
    /// through Tailscale", or "Nothing is getting through · through Tailscale".
    private static func deviceRow(_ d: HostStatusSnapshot.Device) -> StatusPresentation.Row {
        let name = d.name ?? d.endpoint
        let symbol = name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "ipad"
        var parts: [String] = []
        if let link = d.link {
            parts.append(linkWords(link, fps: d.fps, rttMs: d.rttMs))
        } else if let fps = d.fps, let age = d.frameAgeMs, let rtt = d.rttMs {
            parts.append("\(fps) fps · frame age \(ms(age)) · RTT \(ms(rtt))")
        }
        if let route = routeWord(d) { parts.append(route) }
        return StatusPresentation.Row(id: String(describing: d.id), symbol: symbol, title: name,
                                      detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    /// A device's link that does not keep up, as its row says it: behind, "3 fps, the link can’t carry
    /// Pro · RTT 531 ms" (the fps and the round trip when its stats have come); stalled, "Nothing is
    /// getting through".
    static func linkWords(_ link: HostStatusSnapshot.LinkStatus, fps: Int?, rttMs: Int?) -> String {
        switch link.state {
        case .stalled:
            return "Nothing is getting through"
        case .behind:
            let quality = QualityPreset.name(forBitrate: link.bitrate).replacingOccurrences(of: " ", with: "\u{00A0}")
            var words = (fps.map { "\($0) fps, " } ?? "") + "the link can’t carry \(quality)"
            if let rtt = rttMs { words += " · RTT \(ms(rtt))" }
            return fps == nil ? words.prefix(1).uppercased() + words.dropFirst() : words
        }
    }

    /// How a device reaches this Mac, the one place the card decides it (the device's row, and the
    /// source row while it is the only device). A remote session says how it came ("through
    /// Tailscale", "over the internet"; RemoteServer's label), which always wins: its link from
    /// this Mac's side would read "Wi-Fi" for a session over the internet. A home device gets its
    /// link from this Mac's side of its connection (ClientLink.route), in the words the device's
    /// connect screen and Settings panel use; nil when neither says (loopback, an interface of no
    /// known kind). Either is kept whole when a detail wraps: a remote label's spaces are no-break
    /// ones (the source row wrapped "through" and "Tailscale" onto two lines), as Wi-Fi's hyphen is.
    private static func routeWord(_ d: HostStatusSnapshot.Device) -> String? {
        if let remote = d.remoteRoute { return remote.replacingOccurrences(of: " ", with: "\u{00A0}") }
        return d.route.map(word)
    }

    /// A home device's link as the card words it. "Wi-Fi" has a non-breaking hyphen, so a wrapped
    /// detail never splits it.
    private static func word(_ route: ClientLink.Route) -> String {
        switch route {
        case .wired: return "Wired"
        case .wifi: return "Wi\u{2011}Fi"
        case .direct: return "Direct"
        }
    }

    /// One of a device's reported times. Negative is the client's "no sample this second" (-1),
    /// never a time.
    private static func ms(_ v: Int) -> String { v < 0 ? "–" : "\(v) ms" }

    private static func virtualDisplayNote(_ s: HostStatusSnapshot) -> String {
        if let problem = s.virtualDisplayProblem { return "Unavailable: \(problem)" }
        if s.virtualDisplayOn, s.stream?.onVirtualDisplay == true { return "The streamed window is on the virtual display" }
        return "Picked windows leave this screen while they stream"
    }

    /// "Safari — A very long window title that goes on" → "Safari — A very long…that goes on".
    static func middleTruncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let keep = limit - 1
        return String(text.prefix((keep + 1) / 2)) + "…" + String(text.suffix(keep / 2))
    }
}
