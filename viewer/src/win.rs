//! Windows only: bring the window back with Win32 directly. A hidden window gets no frames from
//! the app's own loop, so a request made through that loop (Visible(true)) waits forever.

use std::sync::atomic::{AtomicIsize, Ordering};

use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    IsIconic, SetForegroundWindow, ShowWindow, ShowWindowAsync, SW_RESTORE, SW_SHOW,
};

static HWND_VALUE: AtomicIsize = AtomicIsize::new(0);

/// Remembers the main window, from eframe's creation context.
pub fn remember(cc: &eframe::CreationContext<'_>) {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    if let Ok(h) = cc.window_handle() {
        if let RawWindowHandle::Win32(w) = h.as_raw() {
            HWND_VALUE.store(w.hwnd.get(), Ordering::Relaxed);
        }
    }
}

/// Shows, restores and fronts the main window. Safe from any thread.
pub fn show_window() {
    let v = HWND_VALUE.load(Ordering::Relaxed);
    if v == 0 {
        return;
    }
    let hwnd = v as HWND;
    unsafe {
        ShowWindowAsync(hwnd, SW_SHOW);
        if IsIconic(hwnd) != 0 {
            ShowWindow(hwnd, SW_RESTORE);
        }
        SetForegroundWindow(hwnd);
    }
}
