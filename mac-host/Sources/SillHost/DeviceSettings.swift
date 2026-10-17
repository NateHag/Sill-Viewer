import CoreGraphics
import StreamProtocol

// A device's view of the host's settings (kinds 16 and 17): the conversions between the host's
// `HostConfig` and the wire types, and what a device may set. The coordinator's `.changeSettings`
// handler and `settingsState` are the only users, plus the app's hook (`applying`, `applyingAway`).
// Pure (CoreGraphics, StreamProtocol and HostConfig): checked with swiftc (Tests/checks/away-quality).

extension HostConfig {
    /// As a device sees them: the quality its connection controls in `bitrate` and `captureScale`,
    /// the away pair for a connection the Mac counts as away (docs/remote-bundle-plan.md §4.2), the
    /// home pair for any other; the other four are shared.
    func streamSettings(away: Bool) -> StreamSettings {
        let pair = effective(away: away)
        return StreamSettings(maxFPS: maxFPS, bitrate: pair.bitrate, captureScale: Double(pair.captureScale),
                              prioritizeSpeed: prioritizeSpeed, virtualDisplay: virtualDisplay,
                              directWireless: directWireless)
    }

    /// This config with a device's change laid over it; nil fields keep their value. `package`:
    /// the app's hook lays a change over its own settings with it.
    package func applying(_ change: HostSettingsChange) -> HostConfig {
        var c = self
        if let v = change.maxFPS { c.maxFPS = v }
        if let v = change.bitrate { c.bitrate = v }
        if let v = change.captureScale { c.captureScale = CGFloat(v) }
        if let v = change.prioritizeSpeed { c.prioritizeSpeed = v }
        if let v = change.virtualDisplay { c.virtualDisplay = v }
        if let v = change.directWireless { c.directWireless = v }
        return c
    }

    /// A change from a device away from home (docs/remote-bundle-plan.md §5.3): its Quality and
    /// Resolution land on the away pair, never on the home one, and its other fields as `applying`
    /// lays them. `package`: the app's hook lays such a change over its own settings with it.
    package func applyingAway(_ change: HostSettingsChange) -> HostConfig {
        var c = self
        if let v = change.bitrate { c.awayBitrate = v }
        if let v = change.captureScale { c.awayCaptureScale = CGFloat(v) }
        var rest = change
        rest.bitrate = nil
        rest.captureScale = nil
        return c.applying(rest)
    }
}

/// What a device may change on this host. There is no generic "write a default": a device moves
/// these six knobs, to exactly the Mac menu's values, and nothing else. From a connection the Mac
/// counts as away, its bitrate and capture scale land on the away pair (`applyingAway`): the same
/// whitelist decides both routes. Remote access, its port and
/// internet access can never enter this whitelist: they widen who reaches the Mac, and only the
/// Mac's own user may do that.
enum DeviceSettings {
    /// The fields of `c` a device may set: exactly the Mac menu's choices (`SettingsChoices`), and
    /// the virtual display on only where this host can run it (off is always allowed), and Direct
    /// Wireless either way on every host (on the synthetic one it changes only which interfaces the
    /// listener accepts on, since that host registers nothing a device browses), except from a
    /// remote connection (`fromRemote`): a device away from home cannot change how devices near the
    /// Mac reach it. Refusal is per field: the rest of the same change still applies. The refused
    /// fields are named for the log; the token is not carried (the handler answers with the
    /// request's own). Each field is copied by name, so one added to `HostSettingsChange` but not
    /// here is dropped without a refusal or a log line (StreamProtocol's HostSettings.swift lists
    /// every place a new setting goes).
    static func accepted(_ c: HostSettingsChange, virtualDisplayAvailable: Bool, fromRemote: Bool = false) -> (HostSettingsChange, refused: [String]) {
        var ok = HostSettingsChange(prioritizeSpeed: c.prioritizeSpeed)
        var refused: [String] = []
        if let v = c.directWireless {
            if fromRemote { refused.append("direct wireless (not from a remote connection)") } else { ok.directWireless = v }
        }
        if let v = c.maxFPS {
            if SettingsChoices.maxFPS.contains(v) { ok.maxFPS = v } else { refused.append("frame rate limit \(v)") }
        }
        if let v = c.bitrate {
            if SettingsChoices.bitrate.contains(v) { ok.bitrate = v } else { refused.append("bitrate \(v)") }
        }
        if let v = c.captureScale {
            if SettingsChoices.captureScale.contains(v) { ok.captureScale = v } else { refused.append("capture scale \(v)") }
        }
        if let v = c.virtualDisplay {
            if !v || virtualDisplayAvailable { ok.virtualDisplay = v } else { refused.append("virtual display (needs SillHost --virtual-display)") }
        }
        return (ok, refused)
    }
}
