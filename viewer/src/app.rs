//! The window: computers on the network, pairing, and the stream with mouse and keyboard.

use crate::decode::{self, Shared};
use crate::discovery::{Browser, Found};
use crate::identity::{self, Identity, SavedHost};
use crate::input;
use crate::pairing;
use crate::render::{self, VideoCallback};
use crate::tray::{self, Tray};
use crate::session::{Event, Session};
use crate::wire;
use eframe::egui::{self, Color32, Modifiers, Pos2, Rect, RichText, Vec2};
use eframe::egui_wgpu;
use serde_json::{json, Value};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::tray::PRESETS;

#[derive(Clone)]
struct Target {
    name: String,
    addr: String,
    saved: Option<SavedHost>,
    pairing_required: bool,
}

enum Task {
    Asked(Result<(String, [u8; 32]), String>),
    Paired(Result<SavedHost, String>),
    Connected(Result<Box<Live>, String>, Target),
}

struct Live {
    session: Session,
    events: Receiver<Event>,
    shared: Arc<Mutex<Shared>>,
    windows: Vec<Value>,
    active: Value,
    mac_name: String,
    /// The paired computers, for the switcher: (id, name, on the network now, this one).
    machines: Vec<(String, String, bool, bool)>,
    /// A tray-style command the switcher asked for ("connect:<id>").
    switch_to: Option<String>,
    /// The last file transfer note, and when it came.
    note: Option<(String, Instant)>,
    settings: Option<Value>,
    rtt: f64,
    sent_viewport: (f32, f32, u32, u32, u32),
    match_screen: bool,
    sent_mods: Modifiers,
    buttons_down: Vec<&'static str>,
    scroll_open: Option<Instant>,
    last_pos: (f64, f64),
    token: i64,
    fps: u32,
    cursor_in_video: bool,
    fullscreen: bool,
    /// The window's real full screen state, as last seen: the OS can change it (the Mac's green
    /// button, Ctrl+Cmd+F, F11 on Linux), and then the app follows.
    os_fullscreen: Option<bool>,
}

enum Screen {
    Home { status: String },
    Pairing { target: Target, pin: Option<[u8; 32]>, code: String, status: String, busy: bool },
    Connecting(Target),
    Stream(Box<Live>, Target),
}

pub struct App {
    id: Arc<Identity>,
    hosts: Vec<SavedHost>,
    browser: Browser,
    screen: Screen,
    tasks: (Sender<Task>, Receiver<Task>),
    wake: Arc<dyn Fn() + Send + Sync>,
    manual: String,
    tray: Option<Tray>,
    quitting: bool,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>, id: Identity) -> App {
        if let Some(rs) = cc.wgpu_render_state.as_ref() {
            render::init(rs);
        }
        cc.egui_ctx.options_mut(|o| o.zoom_with_keyboard = false);
        let ctx = cc.egui_ctx.clone();
        let wake: Arc<dyn Fn() + Send + Sync> = Arc::new(move || ctx.request_repaint());
        let tray = match Tray::new(&cc.egui_ctx) {
            Ok(t) => Some(t),
            Err(e) => {
                log::warn!("no tray icon: {e}");
                None
            }
        };
        App {
            id: Arc::new(id),
            hosts: identity::load_hosts(),
            browser: Browser::start(wake.clone()),
            screen: Screen::Home { status: String::new() },
            tasks: channel(),
            wake,
            manual: String::new(),
            tray,
            quitting: false,
        }
    }

    /// The tray's state, from what the window shows now.
    fn tray_state(&self, ctx: &egui::Context) -> tray::State {
        let mut hosts: Vec<(String, String)> = self.hosts.iter().map(|h| (h.mac_id.clone(), h.name.clone())).collect();
        for f in self.browser.found.lock().unwrap().iter() {
            if self.saved_for(f).is_none() {
                hosts.push((format!("found:{}", f.fullname), format!("{} (pair)", f.name)));
            }
        }
        let mut st = tray::State { hosts, ..Default::default() };
        match &self.screen {
            Screen::Stream(live, _) => {
                let s = live.settings.as_ref().map(|v| &v["settings"]);
                st.status = format!("Connected to {}", live.mac_name);
                st.connected = true;
                st.bitrate = s.and_then(|s| s["bitrate"].as_i64());
                st.sharp = s.and_then(|s| s["captureScale"].as_f64()).map(|c| c >= 1.5);
                st.fps120 = live.fps == 120;
                st.fit = live.settings.as_ref().filter(|v| v["virtualDisplayAvailable"] == true)
                    .map(|v| v["settings"]["virtualDisplay"] == true);
                st.fullscreen = live.fullscreen;
                st.match_screen = live.settings.as_ref().filter(|v| v["virtualDisplayAvailable"] == true)
                    .map(|_| live.match_screen);
            }
            Screen::Connecting(t) => st.status = format!("Connecting to {}…", t.name),
            Screen::Pairing { target, .. } => st.status = format!("Pairing with {}", target.name),
            Screen::Home { .. } => st.status = "Not connected".into(),
        }
        let _ = ctx;
        st
    }

    /// What the tray asked for.
    fn tray_command(&mut self, ctx: &egui::Context, cmd: &str) {
        if cmd == "quit" {
            self.quitting = true;
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            return;
        }
        if let Some(id) = cmd.strip_prefix("connect:") {
            tray::show_window(ctx);
            let target = if let Some(full) = id.strip_prefix("found:") {
                self.browser.found.lock().unwrap().iter().find(|f| f.fullname == full).and_then(|f| {
                    f.address().map(|addr| Target { name: f.name.clone(), addr, saved: None,
                                                    pairing_required: f.pairing_required() })
                })
            } else {
                let saved = self.hosts.iter().find(|h| h.mac_id == id).cloned();
                saved.and_then(|h| {
                    let found = self.browser.found.lock().unwrap().iter()
                        .find(|f| self.saved_for(f).is_some_and(|s| s.mac_id == h.mac_id)).and_then(|f| f.address());
                    found.or(h.last_address.clone()).map(|addr| Target { name: h.name.clone(), addr, saved: Some(h),
                                                                          pairing_required: true })
                })
            };
            if let Some(t) = target {
                if let Screen::Stream(live, _) = &self.screen {
                    live.session.stop();
                }
                self.connect(t);
            }
            return;
        }
        let Screen::Stream(live, _) = &mut self.screen else { return };
        match cmd {
            "disconnect" => {
                live.session.stop();
                if live.fullscreen {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(false));
                }
                self.screen = Screen::Home { status: String::new() };
            }
            "match" => {
                toggle_match(ctx, live);
                tray::show_window(ctx);
            }
            "fullscreen" => {
                if live.match_screen {
                    toggle_match(ctx, live);
                    return;
                }
                live.fullscreen = !live.fullscreen;
                ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(live.fullscreen));
                tray::show_window(ctx);
            }
            "fps120" => {
                live.fps = if live.fps == 120 { 60 } else { 120 };
                let max = live.settings.as_ref().and_then(|v| v["settings"]["maxFPS"].as_i64()).unwrap_or(60);
                if live.fps == 120 && max < 120 {
                    setting(live, "maxFPS", json!(120));
                }
                live.sent_viewport = (0.0, 0.0, 0, 0, 0);     // sends the new rate with the next frame
            }
            "sharp" => {
                let sharp = live.settings.as_ref().and_then(|v| v["settings"]["captureScale"].as_f64()).unwrap_or(2.0) >= 1.5;
                setting(live, "captureScale", json!(if sharp { 1.0 } else { 2.0 }));
            }
            "fit" => {
                let on = live.settings.as_ref().map(|v| v["settings"]["virtualDisplay"] == true).unwrap_or(false);
                setting(live, "virtualDisplay", json!(!on));
            }
            other => {
                if let Some(b) = other.strip_prefix("bitrate:").and_then(|b| b.parse::<i64>().ok()) {
                    setting(live, "bitrate", json!(b));
                }
            }
        }
    }

    /// The paired computers: (id, name, on the network now, key).
    fn machines(&self) -> Vec<(String, String, bool, Option<[u8; 32]>)> {
        let found = self.browser.found.lock().unwrap().clone();
        let online: Vec<String> = found.iter().filter_map(|f| self.saved_for(f)).map(|h| h.mac_id).collect();
        let mut v: Vec<_> = self.hosts.iter()
            .map(|h| (h.mac_id.clone(), h.name.clone(), online.contains(&h.mac_id), h.fp())).collect();
        v.sort_by(|a, b| a.1.to_lowercase().cmp(&b.1.to_lowercase()));
        v
    }

    fn saved_for(&self, f: &Found) -> Option<SavedHost> {
        self.hosts.iter()
            .find(|h| f.tag.as_deref().is_some_and(|t| h.matches_tag(t)))
            .or_else(|| self.hosts.iter().find(|h| h.name == f.name))
            .cloned()
    }

    fn connect(&mut self, target: Target) {
        if target.saved.is_none() && target.pairing_required {
            self.start_pairing(target);
            return;
        }
        let pin = target.saved.as_ref().and_then(|s| s.fp());
        let (id, tx, wake) = (self.id.clone(), self.tasks.0.clone(), self.wake.clone());
        let t = target.clone();
        std::thread::spawn(move || {
            let (ev_tx, ev_rx) = channel();
            let (v_tx, v_rx) = channel();
            let shared = Arc::new(Mutex::new(Shared::default()));
            let r = Session::start(&t.addr, &id, pin, ev_tx, v_tx, wake.clone()).map(|session| {
                decode::spawn(v_rx, shared.clone(), wake.clone());
                Box::new(Live {
                    session, events: ev_rx, shared, windows: vec![], active: json!({"none": {}}), mac_name: t.name.clone(), machines: vec![], switch_to: None, note: None,
                    settings: None, rtt: 0.0, sent_viewport: (0.0, 0.0, 0, 0, 0), match_screen: false, sent_mods: Modifiers::NONE,
                    buttons_down: vec![], scroll_open: None, last_pos: (0.5, 0.5), token: 0, fps: 60,
                    cursor_in_video: false, fullscreen: false, os_fullscreen: None,
                })
            });
            let _ = tx.send(Task::Connected(r, t));
            wake();
        });
        self.screen = Screen::Connecting(target);
    }

    fn start_pairing(&mut self, target: Target) {
        let (id, tx, wake, addr) = (self.id.clone(), self.tasks.0.clone(), self.wake.clone(), target.addr.clone());
        std::thread::spawn(move || {
            let _ = tx.send(Task::Asked(pairing::ask(&addr, &id)));
            wake();
        });
        self.screen = Screen::Pairing { target, pin: None, code: String::new(),
                                        status: "Asking the computer to show its code…".into(), busy: true };
    }

    fn submit_code(&mut self) {
        if let Screen::Pairing { target, pin, code, status, busy } = &mut self.screen {
            if let Err(e) = pairing::check_code(code) {
                *status = e;
                return;
            }
            *busy = true;
            *status = "Checking the code…".into();
            let (id, tx, wake) = (self.id.clone(), self.tasks.0.clone(), self.wake.clone());
            let (addr, code, pin) = (target.addr.clone(), code.clone(), *pin);
            std::thread::spawn(move || {
                let _ = tx.send(Task::Paired(pairing::pair_with_code(&addr, &id, &code, pin)));
                wake();
            });
        }
    }

    fn handle_tasks(&mut self) {
        while let Ok(t) = self.tasks.1.try_recv() {
            match t {
                Task::Asked(r) => if let Screen::Pairing { pin, status, busy, target, .. } = &mut self.screen {
                    *busy = false;
                    *status = match r {
                        Ok((reason, fp)) => {
                            *pin = Some(fp);
                            match reason.as_str() {
                                "shown" => format!("{} shows a code now. Type it here.", target.name),
                                "openOnMac" => format!("On {}, open the pairing code yourself \
                                    (Mac: Sill menu › Pair iPhone or iPad…; Linux: run  sill-linux pair), then type it here.", target.name),
                                "locked" => format!("Unlock {}, then try again.", target.name),
                                other => format!("The computer said \"{other}\". If it shows a code, type it here."),
                            }
                        }
                        Err(e) => format!("Could not reach the computer: {e}"),
                    };
                },
                Task::Paired(r) => match r {
                    Ok(host) => {
                        let target = if let Screen::Pairing { target, .. } = &self.screen { target.clone() } else { continue };
                        self.hosts.retain(|h| h.mac_id != host.mac_id);
                        self.hosts.push(host.clone());
                        identity::save_hosts(&self.hosts);
                        self.connect(Target { saved: Some(host), ..target });
                    }
                    Err(e) => if let Screen::Pairing { status, busy, .. } = &mut self.screen {
                        *busy = false;
                        *status = e;
                    },
                },
                Task::Connected(r, target) => match r {
                    Ok(live) => {
                        if let Some(saved) = &target.saved {
                            if let Some(h) = self.hosts.iter_mut().find(|h| h.mac_id == saved.mac_id) {
                                h.last_address = Some(target.addr.clone());
                                identity::save_hosts(&self.hosts);
                            }
                        }
                        self.screen = Screen::Stream(live, target);
                    }
                    Err(e) => {
                        if e.contains("pair again") {
                            self.start_pairing(Target { saved: None, ..target });
                        } else {
                            self.screen = Screen::Home { status: format!("{}: {e}", target.name) };
                        }
                    }
                },
            }
        }
    }

    fn home(&mut self, ui: &mut egui::Ui, status: &str) -> Option<Target> {
        let mut pick = None;
        ui.add_space(16.0);
        ui.heading("Sill Viewer");
        ui.label(RichText::new("An unofficial companion to Sill (getsill.app). Not made by the Sill team.").weak().small());
        ui.label("Computers that run a Sill host on this network:");
        ui.add_space(8.0);
        let found = self.browser.found.lock().unwrap().clone();
        let mut shown = Vec::new();
        egui::Grid::new("hosts").num_columns(3).spacing([16.0, 10.0]).striped(true).show(ui, |ui| {
            for f in &found {
                let saved = self.saved_for(f);
                if let Some(s) = &saved {
                    shown.push(s.mac_id.clone());
                }
                ui.label(RichText::new(&f.name).strong());
                ui.label(match (&saved, f.door.as_deref()) {
                    (Some(_), _) => "Paired",
                    (None, None) => "Needs a newer Sill",
                    (None, Some("0")) => "Open",
                    _ => "Not paired",
                });
                let enabled = f.door.is_some() && f.address().is_some();
                if ui.add_enabled(enabled, egui::Button::new(if saved.is_some() { "Connect" } else { "Pair…" })).clicked() {
                    pick = Some(Target { name: f.name.clone(), addr: f.address().unwrap(), saved,
                                         pairing_required: f.pairing_required() });
                }
                ui.end_row();
            }
            for h in self.hosts.iter().filter(|h| !shown.contains(&h.mac_id)) {
                ui.label(RichText::new(&h.name).strong());
                ui.label("Paired, not seen now");
                if let Some(addr) = &h.last_address {
                    if ui.button("Connect").clicked() {
                        pick = Some(Target { name: h.name.clone(), addr: addr.clone(), saved: Some(h.clone()),
                                             pairing_required: true });
                    }
                } else {
                    ui.label("");
                }
                ui.end_row();
            }
        });
        if found.is_empty() && self.hosts.is_empty() {
            ui.label(RichText::new("Looking… (on Linux, the host runs as `sill-linux`)").weak());
        }
        ui.add_space(16.0);
        ui.separator();
        ui.horizontal(|ui| {
            ui.label("Or an address:");
            ui.add(egui::TextEdit::singleline(&mut self.manual).hint_text("192.168.1.20:7456").desired_width(220.0));
            if ui.button("Connect").clicked() && !self.manual.trim().is_empty() {
                let addr = self.manual.trim().to_string();
                let addr = if addr.contains(':') && !addr.starts_with('[') && addr.matches(':').count() == 1 || addr.contains("]:") {
                    addr
                } else {
                    format!("{addr}:7456")
                };
                let saved = self.hosts.iter().find(|h| h.last_address.as_deref() == Some(addr.as_str())).cloned();
                pick = Some(Target { name: addr.clone(), addr, saved, pairing_required: true });
            }
        });
        if !status.is_empty() {
            ui.add_space(8.0);
            ui.colored_label(Color32::LIGHT_RED, status);
        }
        pick
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.handle_tasks();
        // With a tray icon, closing the window hides it; Quit is in the tray's menu.
        if self.tray.is_some() && !self.quitting && ctx.input(|i| i.viewport().close_requested()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            if cfg!(target_os = "macos") {
                // On a Mac, minimize: a click on the Dock icon brings a minimized window back,
                // but not a hidden one.
                ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(true));
            } else {
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            }
        }
        let commands = self.tray.as_ref().map(|t| t.commands()).unwrap_or_default();
        for c in commands {
            self.tray_command(ctx, &c);
        }
        let machines = self.machines();
        if let Screen::Stream(live, _) = &mut self.screen {
            let fp = live.session.host_fp;
            live.machines = machines.into_iter()
                .map(|(id, name, online, hfp)| (id, name, online, hfp == Some(fp))).collect();
        }
        let screen = std::mem::replace(&mut self.screen, Screen::Home { status: String::new() });
        self.screen = match screen {
            Screen::Home { status } => {
                let mut pick = None;
                egui::CentralPanel::default().show(ctx, |ui| pick = self.home(ui, &status));
                ctx.request_repaint_after(Duration::from_secs(1));
                match pick {
                    Some(t) => {
                        self.connect(t);
                        std::mem::replace(&mut self.screen, Screen::Home { status: String::new() })
                    }
                    None => Screen::Home { status },
                }
            }
            Screen::Connecting(t) => {
                egui::CentralPanel::default().show(ctx, |ui| {
                    ui.centered_and_justified(|ui| ui.label(format!("Connecting to {}…", t.name)));
                });
                Screen::Connecting(t)
            }
            Screen::Pairing { target, pin, mut code, status, busy } => {
                let mut submit = false;
                let mut cancel = false;
                egui::CentralPanel::default().show(ctx, |ui| {
                    ui.add_space(24.0);
                    ui.heading(format!("Pair with {}", target.name));
                    ui.add_space(8.0);
                    ui.label(&status);
                    ui.add_space(8.0);
                    let r = ui.add_enabled(!busy, egui::TextEdit::singleline(&mut code).hint_text("1234 5678 9012")
                        .font(egui::TextStyle::Monospace).desired_width(200.0));
                    if r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                        submit = true;
                    }
                    ui.horizontal(|ui| {
                        if ui.add_enabled(!busy, egui::Button::new("Pair")).clicked() { submit = true; }
                        if ui.button("Cancel").clicked() { cancel = true; }
                    });
                });
                if cancel {
                    Screen::Home { status: String::new() }
                } else {
                    self.screen = Screen::Pairing { target, pin, code, status, busy };
                    if submit && !busy {
                        self.submit_code();
                    }
                    std::mem::replace(&mut self.screen, Screen::Home { status: String::new() })
                }
            }
            Screen::Stream(mut live, target) => match stream(ctx, &mut live, &target) {
                None => Screen::Stream(live, target),
                Some(why) => {
                    live.session.stop();
                    if live.fullscreen {
                        ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(false));
                    }
                    Screen::Home { status: why }
                }
            },
        };
        let switch = if let Screen::Stream(live, _) = &mut self.screen { live.switch_to.take() } else { None };
        if let Some(cmd) = switch {
            if let Screen::Stream(live, _) = &mut self.screen {
                if live.match_screen {
                    toggle_match(ctx, live);
                } else if live.fullscreen {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(false));
                }
            }
            self.tray_command(ctx, &cmd);
        }
        if self.tray.is_some() {
            let st = self.tray_state(ctx);
            if let Some(t) = self.tray.as_mut() {
                t.update(st);
            }
        }
    }
}

/// "Match this screen": on, the host shows its desktop on a virtual screen with exactly this
/// monitor's pixels, and this window goes full screen, so one remote pixel is one screen pixel.
fn toggle_match(ctx: &egui::Context, live: &mut Live) {
    live.match_screen = !live.match_screen;
    let vd = live.settings.as_ref().map(|v| v["settings"]["virtualDisplay"] == true).unwrap_or(false);
    if live.match_screen != vd {
        setting(live, "virtualDisplay", json!(live.match_screen));
    }
    if live.fullscreen != live.match_screen {
        live.fullscreen = live.match_screen;
        ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(live.fullscreen));
    }
    live.sent_viewport = (0.0, 0.0, 0, 0, 0);
}

fn setting(live: &mut Live, field: &str, value: Value) {
    live.token += 1;
    let mut m = serde_json::Map::new();
    m.insert("token".into(), json!(live.token));
    m.insert(field.into(), value);
    live.session.send(wire::CHANGE_SETTINGS, &Value::Object(m));
}

/// The stream screen. Returns Some(reason) when the session should end.
fn stream(ctx: &egui::Context, live: &mut Live, target: &Target) -> Option<String> {
    while let Ok(ev) = live.events.try_recv() {
        match ev {
            Event::WindowList(v) => {
                live.windows = v["windows"].as_array().cloned().unwrap_or_default();
                // The host draws its cursor into the video only when it says so; otherwise this
                // window's own cursor is the one to see, and it is exactly where the input goes.
                live.cursor_in_video = v["cursorInVideo"] == true;
                live.mac_name = v["macName"].as_str().unwrap_or(&target.name).to_string();
                live.active = v["active"].clone();
                if live.active.get("none").is_some() {
                    live.session.select(json!({"desktop": {}}));
                }
            }
            Event::HostSettings(v) => live.settings = Some(v),
            Event::Note(t) => live.note = Some((t, Instant::now())),
            Event::Rtt(ms) => live.rtt = if live.rtt == 0.0 { ms } else { live.rtt * 0.8 + ms * 0.2 },
            Event::Goodbye(v) => {
                return Some(v["message"].as_str().map(String::from)
                    .unwrap_or_else(|| format!("{} ended the session ({}).", live.mac_name, v["reason"].as_str().unwrap_or("?"))));
            }
            Event::Ended(why) => return Some(format!("{}: {why}", live.mac_name)),
        }
    }
    let mut leave = None;

    // Files dropped on the window go to the host's Downloads folder.
    let (dropped, hovering) = ctx.input(|i| (i.raw.dropped_files.iter().filter_map(|f| f.path.clone()).collect::<Vec<_>>(),
                                             !i.raw.hovered_files.is_empty()));
    if !dropped.is_empty() {
        live.session.send_files(dropped);
    }
    let note = if hovering {
        Some(format!("Drop to send to {}'s Downloads folder", live.mac_name))
    } else {
        live.note.as_ref().filter(|(_, at)| at.elapsed() < Duration::from_secs(6)).map(|(t, _)| t.clone())
    };
    if let Some(text) = note {
        egui::Area::new(egui::Id::new("note")).anchor(egui::Align2::CENTER_BOTTOM, [0.0, -24.0]).show(ctx, |ui| {
            egui::Frame::popup(ui.style()).show(ui, |ui| ui.label(RichText::new(text).strong()));
        });
        ctx.request_repaint_after(Duration::from_millis(500));
    }

    live.session.focused.store(ctx.input(|i| i.focused), std::sync::atomic::Ordering::Relaxed);

    // Follow a full screen change made outside the app (the green button on a Mac).
    if let Some(now) = ctx.input(|i| i.viewport().fullscreen) {
        if live.os_fullscreen != Some(now) {
            live.os_fullscreen = Some(now);
            if now != live.fullscreen {
                live.fullscreen = now;
                if !now && live.match_screen {
                    toggle_match(ctx, live);   // leaving full screen also leaves Match this screen
                }
            }
        }
    }

    if !live.fullscreen {
        egui::TopBottomPanel::top("bar").show(ctx, |ui| {
            ui.horizontal(|ui| {
                // The computer: a menu of the paired ones, to switch quickly.
                egui::ComboBox::from_id_salt("machine")
                    .selected_text(RichText::new(&live.mac_name).strong())
                    .show_ui(ui, |ui| {
                        for (id, name, online, this) in live.machines.clone() {
                            let label = if this || online { RichText::new(&name) } else { RichText::new(format!("{name} (not found)")).weak() };
                            if ui.selectable_label(this, label).clicked() && !this {
                                live.switch_to = Some(format!("connect:{id}"));
                            }
                        }
                    });
                let cur = if live.active.get("desktop").is_some() { "Desktop".to_string() } else {
                    let id = live.active["window"]["_0"].as_u64();
                    live.windows.iter().find(|w| w["id"].as_u64() == id)
                        .map(|w| w["title"].as_str().unwrap_or("Window").to_string()).unwrap_or("—".into())
                };
                egui::ComboBox::from_id_salt("source").selected_text(cur).width(200.0).show_ui(ui, |ui| {
                    if ui.selectable_label(live.active.get("desktop").is_some(), "Desktop").clicked() {
                        live.session.select(json!({"desktop": {}}));
                    }
                    for w in live.windows.clone() {
                        let id = w["id"].as_u64().unwrap_or(0);
                        let label = format!("{} — {}", w["appName"].as_str().unwrap_or(""), w["title"].as_str().unwrap_or(""));
                        if ui.selectable_label(live.active["window"]["_0"].as_u64() == Some(id), label).clicked() {
                            live.session.select(json!({"window": {"_0": id}}));
                        }
                    }
                });
                if let Some(st) = live.settings.clone() {
                    let s = &st["settings"];
                    let bitrate = s["bitrate"].as_i64().unwrap_or(0);
                    let name = PRESETS.iter().find(|p| p.0 == bitrate).map(|p| p.1.to_string())
                        .unwrap_or(format!("{} Mbps", bitrate / 1_000_000));
                    egui::ComboBox::from_id_salt("quality").selected_text(name).show_ui(ui, |ui| {
                        for (b, n) in PRESETS {
                            if ui.selectable_label(b == bitrate, format!("{n} — {} Mbps", b / 1_000_000)).clicked() {
                                setting(live, "bitrate", json!(b));
                            }
                        }
                    });
                    let retina = s["captureScale"].as_f64().unwrap_or(2.0) >= 1.5;
                    if ui.selectable_label(retina, "Sharp").on_hover_text("Full resolution (Retina). Off: half, for slow links.").clicked() {
                        setting(live, "captureScale", json!(if retina { 1.0 } else { 2.0 }));
                    }
                    let fps120 = live.fps == 120;
                    if ui.selectable_label(fps120, "120 fps").clicked() {
                        live.fps = if fps120 { 60 } else { 120 };
                        if !fps120 && s["maxFPS"].as_i64().unwrap_or(60) < 120 {
                            setting(live, "maxFPS", json!(120));
                        }
                    }
                    if st["virtualDisplayAvailable"] == true {
                        if ui.selectable_label(live.match_screen, "Match this screen")
                            .on_hover_text("Full screen, on a virtual screen with exactly this monitor's resolution").clicked() {
                            toggle_match(ctx, live);
                        }
                        let vd = s["virtualDisplay"] == true;
                        if ui.selectable_label(vd, "Fit screen").on_hover_text("Desktop on a virtual screen sized to this window").clicked() {
                            setting(live, "virtualDisplay", json!(!vd));
                        }
                    }
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.button("Disconnect").clicked() {
                        leave = Some(String::new());
                    }
                    if ui.button("Get copied files")
                        .on_hover_text(format!("Copy files on {} (Ctrl+C in Files), then click here: they come to your \
                                                Downloads folder. To send files there, drop them on this window.", live.mac_name))
                        .clicked() {
                        live.session.request_files();
                        live.note = Some(("Asking for the copied files…".into(), Instant::now()));
                    }
                    // A Mac has its own full screen button (the green one), so no second one here.
                    if !cfg!(target_os = "macos") && ui.button("Full screen").on_hover_text("Ctrl+Alt+Shift+F leaves it").clicked() {
                        live.fullscreen = true;
                        ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(true));
                    }
                    let sh = live.shared.lock().unwrap();
                    ui.label(RichText::new(format!("{}×{} · {} · {:.0} ms", sh.size.0, sh.size.1, sh.decoder, live.rtt)).weak());
                });
            });
        });
    }

    egui::CentralPanel::default().frame(egui::Frame::none().fill(Color32::BLACK)).show(ctx, |ui| {
        let avail = ui.available_rect_before_wrap();
        let (vw, vh) = live.shared.lock().unwrap().size;
        let rect = if vw > 0 && vh > 0 {
            let s = (avail.width() / vw as f32).min(avail.height() / vh as f32);
            Rect::from_center_size(avail.center(), Vec2::new(vw as f32 * s, vh as f32 * s))
        } else {
            avail
        };
        let resp = ui.allocate_rect(avail, egui::Sense::click_and_drag());
        if vw > 0 {
            ui.painter().add(egui_wgpu::Callback::new_paint_callback(rect, VideoCallback { shared: live.shared.clone() }));
        } else {
            let msg = if crate::decode::HW_HUNG.load(std::sync::atomic::Ordering::Relaxed) {
                "The graphics card's video decoder stopped answering.\nClose Sill Viewer and open it again: it will decode in software."
            } else {
                "Waiting for the picture…"
            };
            ui.painter().text(avail.center(), egui::Align2::CENTER_CENTER, msg,
                              egui::FontId::proportional(18.0), Color32::GRAY);
        }
        // The panel's size, in points, so a virtual screen on the host can match this window.
        // "Match this screen": the whole monitor, in its own pixels, for a virtual screen of
        // exactly that size. Otherwise the panel's size in points.
        let (monitor, ppp) = ctx.input(|i| (i.viewport().monitor_size, i.viewport().native_pixels_per_point));
        let pixels = match (live.match_screen, monitor, ppp) {
            (true, Some(m), Some(p)) => Some(((m.x * p).round() as u32, (m.y * p).round() as u32, p)),
            _ => None,
        };
        let size = if live.match_screen { monitor.unwrap_or(avail.size()) } else { avail.size() };
        let vp = (size.x.round(), size.y.round(), live.fps, pixels.map_or(0, |p| p.0), pixels.map_or(0, |p| p.1));
        if vp != live.sent_viewport && avail.width() > 50.0 {
            live.sent_viewport = vp;
            live.session.viewport(vp.0 as f64, vp.1 as f64, vp.2, pixels);
        }
        handle_input(ctx, live, rect, resp.hovered() || resp.dragged(), &mut leave);
    });

    if live.scroll_open.is_some_and(|t| t.elapsed() > Duration::from_millis(150)) {
        live.scroll_open = None;
        live.session.input(input::scroll_phase("ended", live.last_pos.0, live.last_pos.1));
    }
    leave.map(|s| if s.is_empty() { String::new() } else { s })
}

fn handle_input(ctx: &egui::Context, live: &mut Live, rect: Rect, over: bool, leave: &mut Option<String>) {
    let to_frac = |p: Pos2| -> (f64, f64) {
        (((p.x - rect.min.x) / rect.width()).clamp(0.0, 1.0) as f64, ((p.y - rect.min.y) / rect.height()).clamp(0.0, 1.0) as f64)
    };
    let (events, mods, focused) = ctx.input(|i| (i.events.clone(), i.modifiers, i.focused));
    if !focused {
        // Leaving the window lets go of everything, so no key or button stays down on the host.
        release_all(live);
        return;
    }
    if over && live.cursor_in_video {
        ctx.set_cursor_icon(egui::CursorIcon::None);   // the host draws its own cursor into the video
    }
    for (usage, down) in input::modifier_changes(&live.sent_mods, &mods) {
        live.session.input(input::key(usage, down, &mods));
    }
    live.sent_mods = mods;
    for ev in events {
        match ev {
            egui::Event::PointerMoved(p) if over || !live.buttons_down.is_empty() => {
                live.last_pos = to_frac(p);
                live.session.input(input::pointer("move", live.last_pos.0, live.last_pos.1));
            }
            egui::Event::PointerButton { pos, button, pressed, .. } if over || !pressed => {
                let action = match (button, pressed) {
                    (egui::PointerButton::Primary, true) => "leftDown",
                    (egui::PointerButton::Primary, false) => "leftUp",
                    (egui::PointerButton::Secondary, true) => "rightDown",
                    (egui::PointerButton::Secondary, false) => "rightUp",
                    _ => continue,
                };
                let down: &'static str = if action.starts_with("left") { "leftDown" } else { "rightDown" };
                if !pressed && !live.buttons_down.contains(&down) {
                    continue;   // an up whose down was not ours (it started outside the video)
                }
                live.last_pos = to_frac(pos);
                live.session.input(input::pointer(action, live.last_pos.0, live.last_pos.1));
                if pressed { live.buttons_down.push(down) } else { live.buttons_down.retain(|b| *b != down) }
            }
            egui::Event::MouseWheel { unit, delta, .. } if over => {
                let px = match unit {
                    egui::MouseWheelUnit::Point => delta,
                    egui::MouseWheelUnit::Line => delta * 40.0,
                    egui::MouseWheelUnit::Page => delta * rect.height(),
                };
                if live.scroll_open.is_none() {
                    live.session.input(input::scroll_phase("began", live.last_pos.0, live.last_pos.1));
                }
                live.scroll_open = Some(Instant::now());
                live.session.input(input::scroll(live.last_pos.0, live.last_pos.1,
                                                 (px.x / rect.width()) as f64, (px.y / rect.height()) as f64));
            }
            egui::Event::Key { key, physical_key, pressed, repeat, modifiers } => {
                if pressed && key == egui::Key::F && modifiers.ctrl && modifiers.alt && modifiers.shift {
                    if live.match_screen {
                        toggle_match(ctx, live);
                    } else {
                        live.fullscreen = !live.fullscreen;
                        ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(live.fullscreen));
                    }
                    continue;
                }
                if repeat {
                    continue;   // the host's own key repeat runs while the key is down
                }
                if let Some(u) = input::hid(physical_key.unwrap_or(key)) {
                    live.session.input(input::key(u, pressed, &modifiers));
                }
            }
            // The platform turned these shortcuts into clipboard events: send the keys they were.
            egui::Event::Copy => tap(live, egui::Key::C, &mods),
            egui::Event::Cut => tap(live, egui::Key::X, &mods),
            egui::Event::Paste(text) => {
                live.session.offer_clipboard(&text);   // the host gets the newest text before the keys
                tap(live, egui::Key::V, &mods)
            }
            _ => {}
        }
    }
    let _ = leave;
}

fn tap(live: &Live, key: egui::Key, mods: &Modifiers) {
    if let Some(u) = input::hid(key) {
        live.session.input(input::key(u, true, mods));
        live.session.input(input::key(u, false, mods));
    }
}

fn release_all(live: &mut Live) {
    let none = Modifiers::NONE;
    for (usage, down) in input::modifier_changes(&live.sent_mods, &none) {
        live.session.input(input::key(usage, down, &none));
    }
    live.sent_mods = none;
    for b in std::mem::take(&mut live.buttons_down) {
        live.session.input(input::pointer(&b.replace("Down", "Up"), live.last_pos.0, live.last_pos.1));
    }
}
