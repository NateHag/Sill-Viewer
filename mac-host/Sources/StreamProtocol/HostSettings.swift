import Foundation

// The Mac's settings as a device sees and changes them (kinds 16 and 17, see StreamMessage.swift):
// five for the stream, and one (Direct Wireless) for how devices reach the Mac. Rules for every
// later change, because older builds of either side must keep decoding what newer ones send:
//
// • A device knows the host supports settings when a `.hostSettings` arrives on this connection,
//   never by a version: `WindowList.hostVersion` is nil from SillHost, and it and `protocol`
//   (Switcher.swift) are nil from hosts before 2026-09-25.
// • Kind numbers are never reused: a new kind takes the next free number, and an older reader maps
//   a kind it does not know to `.unknown` and skips it (StreamMessage.swift).
// • Fields added later must be optional: a missing required key fails the whole decode, and the
//   device would then treat the Mac as an older one.
// • Never remove, rename or retype a field (Swift property names are the JSON keys).
// • No enums in these payloads: an unknown case would fail an older reader's whole decode, while
//   JSONDecoder ignores unknown keys, so either side can add fields.
// • A field a host did not report (nil in its state: an older host) is never sent to it. The
//   device's ledger enforces it (its rule 9), so an older host is never asked for what it cannot
//   show.
//
// Compatibility.swift adds three rules for every session: the device's hello (kind 23) first, a
// `Goodbye.reason` always sent, and a refusal as kind 22 "update" with `"reconnect":false`.
//
// A new setting has to be added everywhere the others are listed by hand, and the compiler points
// at few of those places. Missing the host's whitelist is silent: a device's change is dropped with
// no refusal and no log line, the answer shows the old value, and the device takes that for a
// refusal. The places:
// • here: `StreamSettings` (optional), `HostSettingsChange` with `isEmpty` and `applied(to:)`, and
//   `SettingsChoices` when the setting takes a fixed set of values;
// • the host: `HostConfig` (`validated()`, `changes(to:)`), `streamSettings`, `applying` and
//   `DeviceSettings.accepted` in DeviceSettings.swift, and `StreamCoordinator.restartNeeded` when
//   the running pipeline depends on it;
// • Sill.app: `HostSettings` (its key, registered default, load and `save(changedFrom:)`),
//   `DebugHooks.apply` (`-SillSetAfter`), and the status menu and Settings panes when the Mac
//   shows it;
// • the device: `SettingsField` and `HostSettingsChange.fields`, `only` and `adding`
//   (HostSettingsLedger.swift), rule 9 in the ledger's `pick` for an optional field, the panel's
//   row, and the DEBUG mock's cases (MockCatalog.swift);
// • Scripts/sillclient.py: the keys `--set` accepts, and `describe`.
//
// Away from home (docs/remote-bundle-plan.md §5) splits Quality and Resolution in two: the home
// quality and the away quality. An away variant of a setting goes in HostConfig's away knobs
// (`validated()`, `changes(to:)`, `effective(away:)`), `applyingAway` and `streamSettings(away:)` in
// DeviceSettings.swift, `AwayQuality` below, and the app's away keys (HostSettings, DebugHooks, the
// Streaming pane), and never in `HostSettingsChange`: where a pick lands is the host's decision, by
// the connection's route, so every device, old or new, sets what its connection controls.
//
// A Mac-only listener knob (remote access, its port, internet access) goes in the host's
// HostConfig, the app's HostSettings, DebugHooks, the Remote Access pane and the menu, and never in
// StreamSettings, HostSettingsChange or DeviceSettings.accepted: only the Mac's own user widens
// who can reach the Mac. Require pairing (docs/home-pairing-plan.md §4.1, §6.5) is one too, and
// stricter still: it lives in the identity store beside the trust list, never in the app's
// HostSettings (UserDefaults) or a launch argument, since any process of this user can write those.

/// The settings a device sees and changes, as the Mac's menu and Settings show them: five for the
/// stream, and one (Direct Wireless) for how devices reach the Mac. Plain values, never enums: an
/// unknown case would fail an older reader's whole decode.
public struct StreamSettings: Codable, Hashable, Sendable {
    /// Frame rate limit: a ceiling; each device still gets its own panel's rate below it.
    public var maxFPS: Int
    /// Bits per second per 60 fps (a 120 fps stream gets twice as much).
    public var bitrate: Int
    /// 2 = Retina, 1 = Standard.
    public var captureScale: Double
    public var prioritizeSpeed: Bool
    public var virtualDisplay: Bool
    /// Direct Wireless Connection: the host's listener and its Bonjour registration include
    /// peer-to-peer Wi-Fi (AWDL), so devices with no network in common can find and reach it.
    /// Optional because it came sixth: nil is a host without the setting (the device shows no row
    /// and never sends it).
    public var directWireless: Bool?

    /// `directWireless` has no default: every host must say, so the compiler finds one that forgets.
    public init(maxFPS: Int, bitrate: Int, captureScale: Double, prioritizeSpeed: Bool, virtualDisplay: Bool,
                directWireless: Bool?) {
        self.maxFPS = maxFPS; self.bitrate = bitrate; self.captureScale = captureScale
        self.prioritizeSpeed = prioritizeSpeed; self.virtualDisplay = virtualDisplay
        self.directWireless = directWireless
    }
}

/// The pipeline as it was last started: what actually runs after the devices' rates and the
/// software encoder's caps. Read-only on the device; it confirms that a change took effect.
public struct RunningStream: Codable, Hashable, Sendable {
    /// Encoded pixels.
    public var width: Int
    public var height: Int
    public var fps: Int
    /// The encoder's target (per-60 bitrate × fps / 60), whole Mbps.
    public var mbps: Int
    public var onVirtualDisplay: Bool

    public init(width: Int, height: Int, fps: Int, mbps: Int, onVirtualDisplay: Bool) {
        self.width = width; self.height = height; self.fps = fps; self.mbps = mbps
        self.onVirtualDisplay = onVirtualDisplay
    }
}

/// Away from home (docs/remote-bundle-plan.md §5): the Mac's two qualities, which one runs, and
/// which one this connection's controls set. From a host with an identity (Sill.app; SillHost
/// --remote or --pairing); nil from any other host, which has one quality for every device. One
/// without a remote door (SillHost --pairing alone) sends it too, and no connection there is ever
/// away (`thisConnectionAway` and `awayRunning` false). Every field is required: a host that sends
/// it sends all of it.
public struct AwayQuality: Codable, Hashable, Sendable {
    /// What runs while any connected device is at home: the Mac menu's Quality and Resolution.
    public var homeBitrate: Int
    public var homeCaptureScale: Double
    /// What runs while every connected device is away (through a VPN or over the internet): Low ·
    /// Standard until a device away, or the Mac's Settings, chooses another.
    public var awayBitrate: Int
    public var awayCaptureScale: Double
    /// The Mac counts this connection as away: its Quality and Resolution picks set the away
    /// quality, and `settings.bitrate` and `settings.captureScale` show it.
    public var thisConnectionAway: Bool
    /// Every connected device is away, so the away quality is the target: the host's wish, never its
    /// pipeline's (a restart may still be taking it, as `settings` can be ahead of `stream`).
    public var awayRunning: Bool

    public init(homeBitrate: Int, homeCaptureScale: Double, awayBitrate: Int, awayCaptureScale: Double,
                thisConnectionAway: Bool, awayRunning: Bool) {
        self.homeBitrate = homeBitrate; self.homeCaptureScale = homeCaptureScale
        self.awayBitrate = awayBitrate; self.awayCaptureScale = awayCaptureScale
        self.thisConnectionAway = thisConnectionAway; self.awayRunning = awayRunning
    }
}

/// How the link to this device keeps up, as the Mac sees from what it withholds
/// (docs/remote-bundle-plan.md §6). Sent only while it does not keep up.
public struct LinkReport: Codable, Hashable, Sendable {
    /// `state`'s values. A string, never an enum: a device reads any other value as keeping up.
    public static let behind = "behind"
    public static let stalled = "stalled"

    /// "behind": the link cannot carry this quality (frames withheld in 3 of the last 5 seconds).
    /// "stalled": for 3 s nothing taken while bytes waited, and nothing heard from the device; the
    /// Mac's card shows it, a device never does (it can only arrive once the path is back).
    public var state: String
    /// Frames withheld from this device in the second the state was judged (dropped, or skipped
    /// while it waited for a keyframe).
    public var withheldPerSecond: Int
    /// The quality the link could not carry: the running bitrate, per 60 fps.
    public var bitrate: Int
    /// What the link carried in the seconds it was the limit, kilobits per second; nil until three
    /// such seconds were measured.
    public var carriedKbps: Int?
    /// What would fit: a lower preset's bitrate, with 1 (Standard) when that is Low and the stream
    /// runs at Retina; or the same bitrate at Standard. Nil bitrate: nothing lower to offer. A nil
    /// capture scale keeps the resolution.
    public var suggestedBitrate: Int?
    public var suggestedCaptureScale: Double?

    public init(state: String, withheldPerSecond: Int, bitrate: Int, carriedKbps: Int? = nil,
                suggestedBitrate: Int? = nil, suggestedCaptureScale: Double? = nil) {
        self.state = state; self.withheldPerSecond = withheldPerSecond; self.bitrate = bitrate
        self.carriedKbps = carriedKbps
        self.suggestedBitrate = suggestedBitrate; self.suggestedCaptureScale = suggestedCaptureScale
    }

    /// The link cannot carry the quality: the one state a device shows.
    public var isBehind: Bool { state == Self.behind }
}

/// Host → device (`.hostSettings`): on connect (right after the window list), whenever it changes,
/// and, with `answering` set, as the reply to one device's `HostSettingsChange`. Each connection gets
/// its own (`away` and `link` are the connection's, and so are `settings.bitrate` and
/// `settings.captureScale` on a host that sends `away`).
public struct HostSettingsState: Codable, Hashable, Sendable {
    /// The target: a change still waiting for its restart is already reported, because the Mac's
    /// menu checks it too. `bitrate` and `captureScale` are the quality this connection's controls
    /// set: the away quality for a connection the Mac counts as away (`away.thisConnectionAway`),
    /// the home quality for any other, so a pick is answered in the field it asked about, from an
    /// older device too.
    public var settings: StreamSettings
    /// Sill.app saves changes; SillHost keeps them until it quits.
    public var persistent: Bool
    /// False: this host cannot run the virtual display at all (SillHost without --virtual-display).
    public var virtualDisplayAvailable: Bool
    /// Why the virtual display is unavailable or not working; nil when nothing is wrong.
    public var virtualDisplayNote: String?
    /// The hardware encoder did not answer (busy or stuck): streams run on the software encoder at
    /// up to 60 fps at Standard until the host finds it keeping up with the stream again (it
    /// checks every 30 s while a device is connected, backing off to 300 s; hosts before
    /// 2026-09-25 kept it until they restarted), and a new state then says false. `settings` can
    /// meanwhile say 120 fps and Retina while `stream` says what runs.
    public var softwareEncoder: Bool
    /// Nil while nothing streams.
    public var stream: RunningStream?
    /// Only in the reply to one device: the token of the change it answers.
    public var answering: Int?
    /// Away from home: nil from a host without an identity (SillHost without --remote or
    /// --pairing), and from older hosts.
    public var away: AwayQuality?
    /// This connection's link while it cannot keep up; nil while it does, and from older hosts.
    public var link: LinkReport?

    public init(settings: StreamSettings, persistent: Bool, virtualDisplayAvailable: Bool,
                virtualDisplayNote: String? = nil, softwareEncoder: Bool, stream: RunningStream? = nil,
                answering: Int? = nil, away: AwayQuality? = nil, link: LinkReport? = nil) {
        self.settings = settings; self.persistent = persistent
        self.virtualDisplayAvailable = virtualDisplayAvailable; self.virtualDisplayNote = virtualDisplayNote
        self.softwareEncoder = softwareEncoder; self.stream = stream; self.answering = answering
        self.away = away; self.link = link
    }
}

/// Device → host (`.changeSettings`): only the fields one control changed, as absolute values
/// ("set the frame rate limit to 60", never "toggle"), so sending the same change twice gives the
/// same result. A nil field is left as it is. The host answers every decodable change with one
/// `HostSettingsState` to that device alone, carrying `token` as `answering`.
public struct HostSettingsChange: Codable, Hashable, Sendable {
    /// Chosen by the device: strictly increasing for its process, never reset. Nil (a test
    /// client) is still applied, and answered without `answering`.
    public var token: Int?
    public var maxFPS: Int?
    public var bitrate: Int?
    public var captureScale: Double?
    public var prioritizeSpeed: Bool?
    public var virtualDisplay: Bool?
    public var directWireless: Bool?

    public init(token: Int? = nil, maxFPS: Int? = nil, bitrate: Int? = nil, captureScale: Double? = nil,
                prioritizeSpeed: Bool? = nil, virtualDisplay: Bool? = nil, directWireless: Bool? = nil) {
        self.token = token; self.maxFPS = maxFPS; self.bitrate = bitrate; self.captureScale = captureScale
        self.prioritizeSpeed = prioritizeSpeed; self.virtualDisplay = virtualDisplay
        self.directWireless = directWireless
    }

    /// All setting fields nil (the token does not count).
    public var isEmpty: Bool {
        maxFPS == nil && bitrate == nil && captureScale == nil && prioritizeSpeed == nil && virtualDisplay == nil
            && directWireless == nil
    }

    /// `s` with this change laid over it: the device's merge (its ledger, and the DEBUG mock's
    /// answer). The host never calls it: it keeps only what `DeviceSettings.accepted` whitelists
    /// and merges with `HostConfig.applying`, so a new field goes into all three (see the list at
    /// the top of this file).
    public func applied(to s: StreamSettings) -> StreamSettings {
        var r = s
        if let v = maxFPS { r.maxFPS = v }
        if let v = bitrate { r.bitrate = v }
        if let v = captureScale { r.captureScale = v }
        if let v = prioritizeSpeed { r.prioritizeSpeed = v }
        if let v = virtualDisplay { r.virtualDisplay = v }
        if let v = directWireless { r.directWireless = v }
        return r
    }
}

/// What a device may pick: exactly the Mac menu's choices. The host checks every change against
/// these. The Mac itself can hold other values (a `defaults write`, a launch argument); a device
/// shows those read-only and can replace them with one of these, never set one itself.
public enum SettingsChoices {
    public static let maxFPS = [60, 120]
    public static let captureScale: [Double] = [2, 1]
    public static var bitrate: [Int] { QualityPreset.allCases.map(\.rawValue) }
}

/// Bitrate presets, per 60 fps (a 120 fps stream gets twice as much). Balanced is the CLI's value.
/// Here rather than in the app so the Mac and the device name the presets the same way. Ascending:
/// every menu and picker on both ends lists `allCases` in this order. The raw values are what the
/// defaults and kinds 16/17 carry, so a rename (Maximum became Pro) changes nothing stored or sent.
/// A new raw value is new to `SettingsChoices` too: an older host refuses it and an older device
/// shows it as "Custom — N Mbps". All stay within `HostConfig.validated()`'s 200 Mbps. Low is for a
/// slow link away from home (docs/remote-access-plan.md §7.11), so it comes first.
public enum QualityPreset: Int, CaseIterable, Identifiable, Sendable {
    case low = 4_000_000, efficient = 8_000_000, balanced = 15_000_000, high = 25_000_000, pro = 40_000_000
    /// For the USB cable or very fast Wi-Fi (`fastLinkNote`).
    case ultra = 80_000_000, extreme = 150_000_000

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .low: "Low"
        case .efficient: "Efficient"
        case .balanced: "Balanced"
        case .high: "High"
        case .pro: "Pro"
        case .ultra: "Ultra"
        case .extreme: "Extreme"
        }
    }

    /// "Balanced — 15 Mbps".
    public var title: String { "\(name) — \(rawValue / 1_000_000) Mbps" }

    /// The one sentence, in the Mac's Settings › Streaming footer and the device's Quality footer,
    /// on what the top presets need.
    public static var fastLinkNote: String {
        "\(ultra.name) and \(extreme.name) need the USB cable or very fast Wi\u{2011}Fi; if the picture lags, step down."
    }

    /// The label for any stored bitrate: a preset's title, or "Custom — 12 Mbps" for one set by
    /// hand (`defaults write`, a launch argument).
    public static func title(forBitrate bitrate: Int) -> String {
        QualityPreset(rawValue: bitrate)?.title ?? "Custom — \(mbps(bitrate)) Mbps"
    }

    /// A quality in a sentence: a preset's name ("Pro"), or "12 Mbps" for a bitrate set by hand
    /// (docs/remote-bundle-plan.md §4.1: the host's log, the Mac's card and the device's callouts).
    public static func name(forBitrate bitrate: Int) -> String {
        QualityPreset(rawValue: bitrate)?.name ?? "\(mbps(bitrate)) Mbps"
    }

    /// A quality with its resolution: "Low · Standard", "Pro · Retina", "12 Mbps · Retina". Plain
    /// spaces: a view that must keep it whole on one line spells them no-break itself.
    public static func shortTitle(bitrate: Int, captureScale: Double) -> String {
        "\(name(forBitrate: bitrate)) · \(captureScale >= 1.5 ? "Retina" : "Standard")"
    }

    /// "15", or "8.5" for a bitrate that is not whole megabits. The same text as `HostConfig.mbps`
    /// in the host, which this module cannot see.
    public static func mbps(_ bitsPerSecond: Int) -> String {
        bitsPerSecond % 1_000_000 == 0 ? "\(bitsPerSecond / 1_000_000)"
                                       : String(format: "%.1f", Double(bitsPerSecond) / 1_000_000)
    }
}
