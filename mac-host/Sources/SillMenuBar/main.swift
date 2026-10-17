import AppKit
import SillHostCore

// Sill.app's executable (Scripts/make-app.sh wraps it into the signed bundle). The AppKit
// lifecycle, like the CLI's --virtual-display branch: NSApplication.run() is what lets this
// process see its virtual display's modes (VirtualDisplay.swift, "Event loop").

// Line-buffered stdout, so a run from Terminal reads live, as the CLI's does.
setvbuf(stdout, nil, _IOLBF, 0)
// A write to a closed pipe (stdout of a Terminal that went away) must not end the host.
signal(SIGPIPE, SIG_IGN)

// Before anything prints: the host's lines go to the Log window's ring and the log file too.
HostLog.shared.configure(keepLines: 5_000, fileURL: DebugHooks.logFileURL)

// The CLI's self-tests work here too, so the app's own identity (its TCC grants, its hardened
// runtime) can be checked: `Sill.app/Contents/MacOS/Sill --virtual-display-selftest`.
if CommandLine.arguments.contains("--encoder-selftest") {
    EncoderSelfTest.run()
}
if let menuApp = MenuSelfTest.requested(in: CommandLine.arguments) {
    MenuSelfTest.run(app: menuApp)   // `Sill --menu-selftest[=APP]`: read-only, as the CLI's
}
// CoreGraphics must be initialized on the main thread before ScreenCaptureKit touches it.
_ = CGMainDisplayID()
if CommandLine.arguments.contains("--virtual-display-selftest") {
    VirtualDisplaySelfTest.run()
}

let app = NSApplication.shared
// The bundle says LSUIElement; the bare .build/release/SillMenuBar has no Info.plist to say it.
app.setActivationPolicy(.accessory)
// NSApplication.delegate is weak: a global keeps the delegate alive for the process.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
MainActor.assumeIsolated { app.mainMenu = MainMenu.make() }
app.run()
