import Foundation

/// Device → host (kind 28): a three- or four-finger gesture the device recognized on its glass,
/// which the Mac turns into its own keyboard shortcut for that action: Mission Control, App Exposé,
/// a Space to either side, Apps, Show Desktop (docs/trackpad-gestures-plan.md §4, §7). The device
/// sends it only to a host whose window list says `gestures` 1 or more (`WindowList.gestures`), so
/// a host from before never gets one; one that does anyway maps kind 28 to `.unknown` and skips it.
///
/// HostSettings.swift's rules apply: JSON; strings, not enums, on the wire, so a later gesture name
/// reaches an older host as a string it skips (the host logs it and posts nothing); fields added
/// later are optional. A later generation of gestures (tracking ones, Tier 2 in the plan) adds
/// optional fields here and says so with `gestures` 2, and goes only to a host that said it.
public struct TrackpadGesture: Codable, Equatable, Sendable {
    /// One of the six names below.
    public var gesture: String
    /// 3 or 4, as the device counted the fingers. Logged only.
    public var fingers: Int?

    public init(gesture: String, fingers: Int? = nil) {
        self.gesture = gesture
        self.fingers = fingers
    }

    /// The fingers move up: Mission Control.
    public static let swipeUp = "swipeUp"
    /// Down: App Exposé, the front app's windows.
    public static let swipeDown = "swipeDown"
    /// Left: the next Space, the one on the right (natural direction: the content follows the fingers).
    public static let swipeLeft = "swipeLeft"
    /// Right: the previous Space, the one on the left.
    public static let swipeRight = "swipeRight"
    /// In: Apps (Launchpad before macOS 26).
    public static let pinch = "pinch"
    /// Out: Show Desktop.
    public static let spread = "spread"
    /// Every name this build sends and takes, in that order.
    public static let names = [swipeUp, swipeDown, swipeLeft, swipeRight, pinch, spread]

    /// `WindowList.gestures` from a host that takes kind 28's six gestures.
    public static let generation = 1
}
