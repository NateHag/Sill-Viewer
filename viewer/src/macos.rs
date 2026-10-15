//! Mac only: bring the window back with AppKit directly. A minimized or hidden window may get no
//! frames from the app's own loop, so a request made through that loop can wait forever.

use objc2_app_kit::NSApplication;
use objc2_foundation::MainThreadMarker;

/// Restores and fronts the app's window, and makes the app active. Main thread only (the tray's
/// events arrive there); elsewhere it does nothing.
pub fn show_window() {
    let Some(mtm) = MainThreadMarker::new() else { return };
    let app = NSApplication::sharedApplication(mtm);
    for w in app.windows().iter() {
        // The menu bar icon has a window too; it cannot become the main window.
        if !unsafe { w.canBecomeMainWindow() } {
            continue;
        }
        if w.isMiniaturized() {
            unsafe { w.deminiaturize(None) };
        }
        w.makeKeyAndOrderFront(None);
    }
    #[allow(deprecated)]
    app.activateIgnoringOtherApps(true);
}
