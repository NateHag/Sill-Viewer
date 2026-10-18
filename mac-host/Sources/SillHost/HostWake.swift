import AppKit
import Foundation
import IOKit.pwr_mgt

/// Sill Desktop Host addition: wake the Mac's screens for a viewer, and keep them awake while one
/// is connected.
///
/// A sleeping display gives ScreenCaptureKit no frames, so a viewer waits for a picture forever.
/// A device arriving, and its input, count as user activity (the same as a local key press: the
/// screens wake, and the idle timer starts again). While a device is connected, display sleep is
/// held off. When the screens wake, the coordinator restarts the stream, since a capture started
/// on a sleeping display may never deliver.
///
/// Needs the Mac itself awake (or woken by the network: System Settings › Battery or Energy ›
/// "Wake for network access"). A locked Mac wakes to its lock screen.
@MainActor
final class HostWake {
    private var hold: IOPMAssertionID = 0
    private var activityID: IOPMAssertionID = 0
    private var lastActivity: TimeInterval = 0
    private var observer: NSObjectProtocol?
    /// The screens woke up (from display sleep or system sleep).
    var onScreensWoke: (() -> Void)?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                print("Wake: the screens woke up")
                self?.onScreensWoke?()
            }
        }
    }

    /// Devices connected (true) or none left (false).
    func devicesPresent(_ any: Bool) {
        if any {
            activity(force: true)
            if hold == 0 {
                let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "Sill Desktop Host: a viewer is connected" as CFString, &hold)
                if r != kIOReturnSuccess { hold = 0; print("Wake: could not hold off display sleep (\(r))") }
            }
        } else if hold != 0 {
            IOPMAssertionRelease(hold)
            hold = 0
        }
    }

    /// Input from a device: user activity, at most every 2 s.
    func activity(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastActivity < 2 { return }
        lastActivity = now
        let r = IOPMAssertionDeclareUserActivity("Sill Desktop Host: viewer input" as CFString,
                                                 kIOPMUserActiveLocal, &activityID)
        if r != kIOReturnSuccess { print("Wake: could not declare user activity (\(r))") }
    }
}
