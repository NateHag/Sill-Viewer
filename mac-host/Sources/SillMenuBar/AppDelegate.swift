import AppKit
import SillHostCore

/// Sill.app: the Mac host as a menu bar app. The same StreamCoordinator as the CLI, under the
/// AppKit loop the virtual display needs, with a status item for what it is doing, Settings for
/// the knobs, and a Log window for what the CLI would have printed.
///
/// THE MODAL-LOOP RULE. Never start a nested modal loop from `Task { @MainActor }`, an async
/// continuation or a `DispatchQueue.main` block: NSMenu.popUp, NSAlert.runModal, NSApp.runModal,
/// NSSavePanel.runModal, and NSApp.terminate whenever it can answer .terminateLater. The main
/// queue is serial, so while that loop runs every host hop waits behind it (input, client
/// messages, source switches, the stats line), and a terminate issued from a Task never gets its
/// reply. Both were measured (design workflow, 2026-09-23). Start them only from AppKit
/// target/action, SwiftUI Button actions or a run-loop Timer, and show errors inline, never in an
/// alert.
///
/// App code may call `MainActor.assumeIsolated` in main-queue callbacks, because the app always
/// runs NSApplication and its main queue is the main thread. The host core may not: the CLI's
/// dispatchMain drains the main queue on a worker thread, where that call traps.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var logWindow: LogWindowController?
    private var pairingWindow: PairDeviceWindowController?
    private var cableNotice: CableNoticeWindowController?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugHooks.renderPreviewsIfAsked(model: model)      // exits when asked
        // A menu bar app with no windows open is exactly what automatic termination would end.
        ProcessInfo.processInfo.disableAutomaticTermination("Sill serves devices from the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
        let item = StatusItemController(model: model)        // "Starting…" until the host is up
        statusItem = item
        model.onPresentation = { [weak item] p in item?.show(p) }
        model.showSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        model.settingsWindowForTests = { [weak self] in self?.settingsWindow }
        model.showLog = { [weak self] in self?.showLog() }
        // An offer can come from a device's request (its ask at the home door, or kind 21), and the
        // cable notice from a device pairing over the cable, each on a main-actor hop: showing a
        // window there is fine, it runs no modal loop.
        model.showPairing = { [weak self] offer in self?.showPairing(offer) }
        model.bringPairingForward = { [weak self] in
            guard let window = self?.pairingWindow, window.isShowing else { return false }
            window.bringForward()
            return true
        }
        model.closePairingWindow = { [weak self] in
            guard let window = self?.pairingWindow, window.isShowing else { return false }
            window.close()          // windowWillClose cancels the pairing, as Cancel does
            return true
        }
        model.showCableNotice = { [weak self] notice in self?.showCableNotice(notice) }
        // Always, not only with the virtual display on: Settings can turn it on at any time, and a
        // kill must then still put the streamed window back.
        HostShutdown.install { [model] in model.coordinator }
        model.start()
        DebugHooks.schedule(model: model)
    }

    /// Opening Sill.app again (Finder, Spotlight, `open`) shows Settings: the way back when the
    /// menu bar has no room for the status item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(tab: nil)
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quit ⌘Q, logout and Screen Recording's "Quit & Reopen" all arrive here from the event loop.
    /// The streamed window goes home and the virtual display goes away before AppKit exits. A
    /// window in a full-screen Space on the virtual display cannot be moved, so it is taken out of
    /// full screen first, waiting up to 2 s on a run-loop timer; a 4 s watchdog exits regardless,
    /// and the atexit restore still runs then. No confirmation. Signals do not come through here:
    /// HostShutdown handles them synchronously, with exit code 128 + the signal.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        let coordinator = model.coordinator
        guard let c = coordinator, c.stagedWindowIsFullScreen else {
            HostShutdown.releaseForQuit(coordinator: coordinator)
            return .terminateNow
        }
        print("Quit: taking the streamed window out of full screen first.")
        c.beginLeavingFullScreenForQuit()
        let deadline = Date().addingTimeInterval(2)
        let poll = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard c.stagedWindowSettled || Date() >= deadline else { return }
                timer.invalidate()
                HostShutdown.releaseForQuit(coordinator: c)
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            print("Quit timed out; exiting anyway.")
            exit(0)
        }
        return .terminateLater
    }

    // MARK: Windows

    /// Settings… (⌘,) from the main menu, which only exists for key equivalents (MainMenu).
    @objc func showSettings(_ sender: Any?) {
        showSettings(tab: nil)
    }

    func showSettings(tab: SettingsTab?) {
        let controller = settingsWindow ?? SettingsWindowController(model: model)
        settingsWindow = controller
        controller.show(tab: tab)
    }

    func showLog() {
        let controller = logWindow ?? LogWindowController(settings: model.settings)
        logWindow = controller
        controller.show()
    }

    /// The one pairing window: made once, shown with each offer (the same code while it is open).
    func showPairing(_ offer: RemoteAccess.PairingOffer) {
        let controller = pairingWindow ?? PairDeviceWindowController(model: model)
        pairingWindow = controller
        controller.show(offer)
    }

    /// The one cable notice window, beside the pairing window: made once, shown for each pairing.
    func showCableNotice(_ notice: CableNotice) {
        let controller = cableNotice ?? CableNoticeWindowController(model: model)
        cableNotice = controller
        controller.show(notice)
    }
}
