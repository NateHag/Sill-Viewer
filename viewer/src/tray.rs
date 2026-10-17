//! The tray icon (Windows notification area, Mac menu bar, Linux top bar): connect, disconnect,
//! the stream's quality, full screen, show the window, quit. Built and updated on the UI thread.

use eframe::egui;
use std::sync::mpsc::{channel, Receiver};
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};

pub const PRESETS: [(i64, &str); 7] = [(4_000_000, "Low"), (8_000_000, "Efficient"), (15_000_000, "Balanced"),
    (25_000_000, "High"), (40_000_000, "Pro"), (80_000_000, "Ultra"), (150_000_000, "Extreme")];

/// What the menu shows. Equal states change nothing.
#[derive(Clone, PartialEq, Default)]
pub struct State {
    pub status: String,
    pub connected: bool,
    pub bitrate: Option<i64>,
    pub sharp: Option<bool>,
    pub fps120: bool,
    pub fit: Option<bool>,
    pub fullscreen: bool,
    /// None: the host has no virtual screens.
    pub match_screen: Option<bool>,
    /// (id, name) of the computers to connect to.
    pub hosts: Vec<(String, String)>,
}

pub struct Tray {
    _icon: TrayIcon,
    status: MenuItem,
    disconnect: MenuItem,
    connect: Submenu,
    connect_items: Vec<MenuItem>,
    quality: Submenu,
    presets: Vec<(i64, CheckMenuItem)>,
    sharp: CheckMenuItem,
    fps120: CheckMenuItem,
    fit: CheckMenuItem,
    fullscreen: CheckMenuItem,
    match_screen: CheckMenuItem,
    rx: Receiver<String>,
    shown: Option<State>,
}

/// A 32×32 icon: a white screen on a stand.
fn icon() -> Icon {
    let n = 32usize;
    let mut px = vec![0u8; n * n * 4];
    let mut put = |x: usize, y: usize, a: u8| {
        let i = (y * n + x) * 4;
        px[i..i + 4].copy_from_slice(&[255, 255, 255, a]);
    };
    for y in 4..22 {
        for x in 2..30 {
            let edge = y < 6 || y > 19 || x < 4 || x > 27;
            put(x, y, if edge { 255 } else { 70 });
        }
    }
    for y in 22..26 {
        for x in 14..18 {
            put(x, y, 255);
        }
    }
    for y in 26..28 {
        for x in 9..23 {
            put(x, y, 255);
        }
    }
    Icon::from_rgba(px, n as u32, n as u32).expect("icon")
}

pub fn show_window(ctx: &egui::Context) {
    #[cfg(target_os = "macos")]
    crate::macos::show_window();
    #[cfg(windows)]
    crate::win::show_window();
    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
    ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
    ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
    ctx.request_repaint();
}

impl Tray {
    pub fn new(ctx: &egui::Context) -> Result<Tray, String> {
        let status = MenuItem::with_id("status", "Sill Viewer", false, None);
        let show = MenuItem::with_id("show", "Show Sill Viewer", true, None);
        let connect = Submenu::with_id("connect", "Connect to", true);
        let disconnect = MenuItem::with_id("disconnect", "Disconnect", false, None);
        let quality = Submenu::with_id("quality", "Quality", false);
        let mut presets = Vec::new();
        for (b, name) in PRESETS {
            let it = CheckMenuItem::with_id(format!("bitrate:{b}"), format!("{name} — {} Mbps", b / 1_000_000), true, false, None);
            quality.append(&it).map_err(|e| e.to_string())?;
            presets.push((b, it));
        }
        let sharp = CheckMenuItem::with_id("sharp", "Sharp (full resolution)", false, true, None);
        let fps120 = CheckMenuItem::with_id("fps120", "120 fps", false, false, None);
        let fit = CheckMenuItem::with_id("fit", "Fit screen to this window", false, false, None);
        let fullscreen = CheckMenuItem::with_id("fullscreen", "Full screen", false, false, None);
        let match_screen = CheckMenuItem::with_id("match", "Match this screen's resolution", false, false, None);
        let quit = MenuItem::with_id("quit", "Quit Sill Viewer", true, None);
        let menu = Menu::new();
        let sep = || PredefinedMenuItem::separator();
        menu.append_items(&[&status, &sep(), &show, &connect, &disconnect, &sep(), &quality, &sharp, &fps120,
                            &fit, &match_screen, &fullscreen, &sep(), &quit]).map_err(|e| e.to_string())?;
        let icon = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_icon(icon())
            .with_tooltip("Sill Viewer (unofficial)")
            .with_menu_on_left_click(false)
            .build()
            .map_err(|e| e.to_string())?;

        let (tx, rx) = channel();
        let c = ctx.clone();
        MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
            if e.id.0 == "show" {
                show_window(&c);
            }
            // Quit right here, not through the window: a hidden window may never run the frame
            // that would close it (Windows), and then the app could only be ended in Task Manager.
            // The host notices the connection close and frees its stream.
            if e.id.0 == "quit" {
                std::process::exit(0);
            }
            let _ = tx.send(e.id.0.clone());
            c.request_repaint();
        }));
        let c = ctx.clone();
        TrayIconEvent::set_event_handler(Some(move |e: TrayIconEvent| {
            let clicked = matches!(e, TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. }
                                    | TrayIconEvent::DoubleClick { .. });
            if clicked {
                show_window(&c);
            }
        }));
        Ok(Tray { _icon: icon, status, disconnect, connect, connect_items: Vec::new(), quality, presets, sharp, fps120,
                  fit, fullscreen, match_screen, rx, shown: None })
    }

    /// The menu's commands since the last call: "disconnect", "connect:<id>", "bitrate:<n>", "sharp",
    /// "fps120", "fit", "match", "fullscreen", "quit" ("show" is handled already).
    pub fn commands(&self) -> Vec<String> {
        self.rx.try_iter().collect()
    }

    pub fn update(&mut self, st: State) {
        if self.shown.as_ref() == Some(&st) {
            return;
        }
        self.status.set_text(&st.status);
        self.disconnect.set_enabled(st.connected);
        self.quality.set_enabled(st.connected && st.bitrate.is_some());
        for (b, it) in &self.presets {
            it.set_checked(st.bitrate == Some(*b));
        }
        self.sharp.set_enabled(st.connected && st.sharp.is_some());
        self.sharp.set_checked(st.sharp.unwrap_or(false));
        self.fps120.set_enabled(st.connected);
        self.fps120.set_checked(st.fps120);
        self.fit.set_enabled(st.connected && st.fit.is_some());
        self.fit.set_checked(st.fit.unwrap_or(false));
        self.fullscreen.set_enabled(st.connected);
        self.fullscreen.set_checked(st.fullscreen);
        self.match_screen.set_enabled(st.connected && st.match_screen.is_some());
        self.match_screen.set_checked(st.match_screen.unwrap_or(false));
        if self.shown.as_ref().map(|s| &s.hosts) != Some(&st.hosts) {
            for it in self.connect_items.drain(..) {
                let _ = self.connect.remove(&it);
            }
            for (id, name) in &st.hosts {
                let it = MenuItem::with_id(format!("connect:{id}"), name, true, None);
                let _ = self.connect.append(&it);
                self.connect_items.push(it);
            }
            if st.hosts.is_empty() {
                let it = MenuItem::with_id("none", "No computers found yet", false, None);
                let _ = self.connect.append(&it);
                self.connect_items.push(it);
            }
        }
        self.shown = Some(st);
    }
}
