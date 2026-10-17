import Foundation
import Darwin

/// Orderly exit for `--virtual-display` mode: a Ctrl-C, `kill` or hangup must put the streamed
/// window back on its real display before the process dies. Without this the window server dumps
/// the window somewhere on a real display when the virtual one vanishes with the process, which
/// is "not lost" but not where the user left it either.
///
/// The CLI installs it only under the flag; its default path installs `installKeyRelease` instead,
/// which lets go of a device's keys and puts back a window Sill sized for a device, then dies of the
/// signal exactly as it did. Under the flag, and in the app, `shutdownForExit` puts such a window
/// back too (WindowRestore, issue #57). The menu bar app
/// always installs it, because Settings can turn the virtual display on while it runs; its Quit
/// (NSApp.terminate: the menu, logout, "Quit & Reopen") comes through `releaseForQuit` instead, and
/// AppKit does the exit.
///
/// Threading: the signal sources fire on the main queue, i.e. on the main thread at a point where
/// no main-actor code is mid-statement (an in-flight `select` is parked at an await), so the
/// coordinator's state is consistent and `shutdownForExit()` can run synchronously. A watchdog on
/// a global queue exits anyway if an Accessibility call into a wedged app never returns.
package enum HostShutdown {
    /// Kept for the life of the process: a released DispatchSourceSignal stops delivering.
    static var sources: [DispatchSourceSignal] = []
    static var began = false

    /// `coordinator` is read at signal time, not now: the coordinator is created asynchronously
    /// after `install` runs.
    package static func install(coordinator: @escaping () -> StreamCoordinator?) {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            // The default disposition would kill the process before the source fires.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { begin(code: 128 + sig, coordinator: coordinator) }
            source.resume()
            sources.append(source)
        }
        // Covers `exit(1)` from a failed listener or startup: nothing is staged at either in
        // practice, but the snapshot restore costs nothing and needs no main-actor state.
        atexit { VirtualStage.emergencyRestore() }
    }

    /// The app's Quit: the same window-home and display-gone as a signal, once, with the same
    /// watchdog, but no exit: the caller returns to AppKit, which ends the process (exit code 0).
    @MainActor
    package static func releaseForQuit(coordinator: StreamCoordinator?) {
        guard !began else { return }
        began = true
        print("Shutting down: putting the window back and removing the virtual display.")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            print("Shutdown timed out; exiting anyway.")
            exit(0)
        }
        coordinator?.shutdownForExit()
    }

    static func begin(code: Int32, coordinator: () -> StreamCoordinator?) {
        if began { exit(code) }   // a second Ctrl-C leaves at once
        began = true
        print("Shutting down: putting the window back and removing the virtual display.")
        // Off the main queue, so a stuck AX call cannot hold the exit hostage; atexit then
        // restores from the snapshot instead.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            print("Shutdown timed out; exiting anyway.")
            exit(code)
        }
        MainActor.assumeIsolated { coordinator()?.shutdownForExit() }
        exit(code)
    }

    /// The CLI's default path (no --virtual-display): a Ctrl-C, `kill` or hangup still ends the
    /// process by that signal as it always did, with the same exit status, but first every key and
    /// button a device holds down on the Mac goes up
    /// (StreamCoordinator.releaseKeysForExit), so a modifier held there (a ⌘-drag on the trackpad, a
    /// hardware ⌘) does not outlive the host and make the Mac's next click a ⌘-click, and a window Sill
    /// sized for a device goes back to its own frame, with a line each (only when a window was
    /// sized). No goodbye and no virtual display: those are the flag's (`install`). A
    /// signal the process was started ignoring (nohup's hangup) stays ignored.
    ///
    /// Under dispatchMain the main queue runs on a worker thread, where MainActor.assumeIsolated
    /// traps: the keys go from a main-actor Task. A second signal ends the process at once, and so
    /// does a watchdog a second after the first (a main actor held by an Accessibility call into a
    /// wedged app).
    package static func installKeyRelease(coordinator: @escaping () -> StreamCoordinator?) {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            // The default disposition would kill the process before the source fires.
            if isIgnore(signal(sig, SIG_IGN)) { continue }
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if began { die(of: sig) }
                began = true
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { die(of: sig) }
                Task { @MainActor in
                    coordinator()?.releaseKeysForExit()
                    die(of: sig)
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Whether a disposition signal() returned is SIG_IGN (Swift compares no C function pointers).
    private static func isIgnore(_ handler: sig_t?) -> Bool {
        unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }

    /// Ends the process of `sig`, as its default disposition always did: the same status for the
    /// shell and for a parent's wait, and no exit handlers. Sent to the process, not raised on this
    /// thread (a dispatch worker may block it), which ends while this waits; only if nothing takes
    /// it, an exit with the shell's status for it.
    private static func die(of sig: Int32) -> Never {
        signal(sig, SIG_DFL)
        kill(getpid(), sig)
        usleep(500_000)
        _exit(128 + sig)
    }
}
