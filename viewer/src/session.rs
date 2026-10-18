//! One session with a host: hello, the catalog, video, pings, and what this viewer sends.

use crate::identity::Identity;
use crate::tls::{self, TlsConn};
use crate::wire;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub enum Event {
    WindowList(Value),
    HostSettings(Value),
    Goodbye(Value),
    Rtt(f64),
    Ended(String),
    /// A short note for the person (file transfers).
    Note(String),
}

/// One access unit for the decoder.
pub struct VideoPacket {
    pub params: Option<Vec<Vec<u8>>>,
    pub nal_len: usize,
    pub au: Vec<u8>,
    pub key: bool,
}

pub struct Session {
    conn: Arc<TlsConn>,
    alive: Arc<AtomicBool>,
    /// True while this window has the keyboard focus: only then does this computer's clipboard go
    /// to the host (so text copied while working in other apps stays here until you come back).
    pub focused: Arc<AtomicBool>,
    /// The clipboard text both sides have, so neither sends it back.
    clip_last: Arc<Mutex<Option<String>>>,
    /// The host speaks Sill's clipboard (kind 32): a Mac with Sill, or a new sill-linux.
    sill_clip: Arc<AtomicBool>,
    listed: Arc<AtomicBool>,
    events: Sender<Event>,
    wake: Arc<dyn Fn() + Send + Sync>,
    file_id: Arc<AtomicU32>,
    sending: Arc<AtomicBool>,
    pub frames: Arc<AtomicU32>,
    pub host_fp: [u8; 32],
    pub peer_addr: String,
}

impl Session {
    pub fn start(addr: &str, id: &Identity, pin: Option<[u8; 32]>, events: Sender<Event>,
                 video: Sender<VideoPacket>, wake: Arc<dyn Fn() + Send + Sync>) -> Result<Session, String> {
        let conn = Arc::new(tls::connect(addr, wire::SESSION_ALPN, pin, id)?);
        let hello = json!({"appVersion": env!("CARGO_PKG_VERSION"), "build": "1", "protocol": 1,
                           "device": format!("Sill Viewer ({})", crate::os_name())});
        conn.send(&wire::json(wire::HELLO, &hello)).map_err(|e| e.to_string())?;
        let alive = Arc::new(AtomicBool::new(true));
        let frames = Arc::new(AtomicU32::new(0));
        let start = Instant::now();
        let focused = Arc::new(AtomicBool::new(true));
        let clip_last = Arc::new(Mutex::new(None::<String>));
        let sill_clip = Arc::new(AtomicBool::new(false));
        // Set once the host's first window list came: until then it is unknown which clipboard
        // message it speaks, so nothing is sent.
        let listed = Arc::new(AtomicBool::new(false));
        let (clip_tx, clip_rx) = channel::<String>();
        let events_out = events.clone();
        // The worst frame age (host send to here, in ms; the clocks are assumed in sync) since the
        // last stats report.
        let age_max = Arc::new(AtomicU32::new(0));

        {
            let (conn, alive, frames, wake) = (conn.clone(), alive.clone(), frames.clone(), wake.clone());
            let age_max_r = age_max.clone();
            let sill_clip_r = sill_clip.clone();
            let listed_r = listed.clone();
            let mut incoming = crate::files::Incoming::default();
            std::thread::Builder::new().name("session read".into()).spawn(move || {
                let mut params: Option<(usize, Vec<Vec<u8>>)> = None;
                let mut pending_params = false;
                let why = conn.read_loop(|m| {
                    match m.kind {
                        wire::PARAMETER_SETS => {
                            if let Some(p) = wire::parse_parameter_sets(&m.payload) {
                                params = Some(p);
                                pending_params = true;
                            }
                        }
                        wire::FRAME => {
                            let nal_len = params.as_ref().map(|p| p.0).unwrap_or(4);
                            let ps = if m.key && pending_params { params.as_ref().map(|p| p.1.clone()) } else { None };
                            if m.key {
                                pending_params = false;
                            }
                            frames.fetch_add(1, Ordering::Relaxed);
                            if m.ts > 0.0 {
                                let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
                                    .map(|d| d.as_secs_f64()).unwrap_or(0.0);
                                let age = ((now - m.ts) * 1000.0).clamp(0.0, 60_000.0) as u32;
                                age_max_r.fetch_max(age, Ordering::Relaxed);
                            }
                            let _ = video.send(VideoPacket { params: ps, nal_len, au: m.payload, key: m.key });
                        }
                        wire::WINDOW_LIST | wire::HOST_SETTINGS | wire::GOODBYE => {
                            if let Ok(v) = serde_json::from_slice::<Value>(&m.payload) {
                                // A host with Sill's clipboard: subscribe once, with an empty one.
                                if m.kind == wire::WINDOW_LIST && v["clipboard"].as_i64().unwrap_or(0) >= 1
                                    && !sill_clip_r.swap(true, Ordering::SeqCst) {
                                    let _ = conn.send(&wire::json(wire::SILL_CLIPBOARD, &json!({})));
                                }
                                if m.kind == wire::WINDOW_LIST {
                                    listed_r.store(true, Ordering::SeqCst);
                                }
                                let ev = match m.kind {
                                    wire::WINDOW_LIST => Event::WindowList(v),
                                    wire::HOST_SETTINGS => Event::HostSettings(v),
                                    _ => Event::Goodbye(v),
                                };
                                let _ = events.send(ev);
                                wake();
                            }
                        }
                        wire::PONG => {
                            if m.payload.len() == 8 {
                                let sent = f64::from_bits(u64::from_be_bytes(m.payload[..8].try_into().unwrap()));
                                let _ = events.send(Event::Rtt((start.elapsed().as_secs_f64() - sent) * 1000.0));
                            }
                        }
                        wire::FILE_START | wire::FILE_DATA | wire::FILE_END | wire::FILE_CANCEL => {
                            if let Some(n) = incoming.on_message(m.kind, &m.payload) {
                                let _ = events.send(Event::Note(n));
                                wake();
                            }
                        }
                        wire::FILE_STATUS => {
                            if let Ok(v) = serde_json::from_slice::<Value>(&m.payload) {
                                if let Some(t) = v["text"].as_str() {
                                    let _ = events.send(Event::Note(t.to_string()));
                                    wake();
                                }
                            }
                        }
                        wire::CLIPBOARD | wire::SILL_CLIPBOARD => {
                            if let Ok(v) = serde_json::from_slice::<Value>(&m.payload) {
                                if let Some(t) = v["text"].as_str() {
                                    let _ = clip_tx.send(t.to_string());
                                }
                            }
                        }
                        _ => {} // ticks, icons, thumbnails, cursor shapes, menus: not used here
                    }
                    alive.load(Ordering::Relaxed)
                });
                alive.store(false, Ordering::Relaxed);
                let _ = events.send(Event::Ended(why));
                wake();
            }).map_err(|e| e.to_string())?;
        }
        {
            let (conn, alive, frames, age_max) = (conn.clone(), alive.clone(), frames.clone(), age_max.clone());
            std::thread::Builder::new().name("session ping".into()).spawn(move || {
                let mut tick = 0u32;
                let mut last_frames = frames.load(Ordering::Relaxed);
                while alive.load(Ordering::Relaxed) {
                    if conn.send(&tls::ping_payload(start.elapsed().as_secs_f64())).is_err() {
                        break;
                    }
                    // Once a second: the frames that came in and the worst frame age, so the host's
                    // log shows what this viewer gets.
                    tick += 1;
                    if tick % 4 == 0 {
                        let n = frames.load(Ordering::Relaxed);
                        let fps = n.wrapping_sub(last_frames);
                        last_frames = n;
                        let age = age_max.swap(0, Ordering::Relaxed);
                        let stats = json!({"fps": fps, "frameAgeMs": if fps > 0 { age as i64 } else { -1 }, "rttMs": -1,
                                           "device": format!("Sill Viewer ({})", crate::os_name()),
                                           "frameAgeMaxMs": if fps > 0 { age as i64 } else { -1 }});
                        let _ = conn.send(&wire::json(wire::CLIENT_STATS, &stats));
                    }
                    std::thread::sleep(Duration::from_millis(250));
                }
            }).map_err(|e| e.to_string())?;
        }
        {
            // The clipboard: text from the host goes on this computer's clipboard; text copied
            // here goes to the host (checked twice a second, while this window has the focus).
            let (conn, alive, focused, last) = (conn.clone(), alive.clone(), focused.clone(), clip_last.clone());
            let sill = sill_clip.clone();
            let listed_c = listed.clone();
            std::thread::Builder::new().name("clipboard".into()).spawn(move || {
                let mut cb = match arboard::Clipboard::new() {
                    Ok(c) => c,
                    Err(e) => {
                        log::warn!("clipboard sharing is off: {e}");
                        return;
                    }
                };
                while alive.load(Ordering::Relaxed) {
                    match clip_rx.recv_timeout(Duration::from_millis(500)) {
                        Ok(text) => {
                            *last.lock().unwrap() = Some(text.clone());
                            if let Err(e) = cb.set_text(text) {
                                log::warn!("clipboard: {e}");
                            }
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                            if focused.load(Ordering::Relaxed) && listed_c.load(Ordering::SeqCst) {
                                if let Ok(t) = cb.get_text() {
                                    offer(&conn, &last, &sill, &t);
                                }
                            }
                        }
                        Err(_) => break,
                    }
                }
            }).map_err(|e| e.to_string())?;
        }
        let host_fp = conn.peer_fp;
        let peer_addr = conn.peer_addr.clone();
        Ok(Session { conn, alive, focused, clip_last, sill_clip, listed, events: events_out, wake, file_id: Arc::new(AtomicU32::new(1)),
                     sending: Arc::new(AtomicBool::new(false)), frames, host_fp, peer_addr })
    }

    pub fn send(&self, kind: u8, v: &Value) {
        if self.alive.load(Ordering::Relaxed) {
            let _ = self.conn.send(&wire::json(kind, v));
        }
    }

    pub fn select(&self, source: Value) {
        self.send(wire::SELECT_SOURCE, &source);
    }

    /// The panel's size in points. `pixels`: the exact pixel size wanted for a virtual screen
    /// ("Match this screen"); an extra key that Sill's own apps ignore.
    /// `ppp`: this screen's pixels per point, so a host can size Fit screen in real pixels.
    pub fn viewport(&self, width: f64, height: f64, fps: u32, pixels: Option<(u32, u32, f32)>, ppp: f32) {
        let mut v = json!({"width": width, "height": height, "fps": fps, "pixelsPerPoint": ppp});
        if let Some((pw, ph, scale)) = pixels {
            v["pixelWidth"] = json!(pw);
            v["pixelHeight"] = json!(ph);
            v["pixelScale"] = json!(scale);
        }
        self.send(wire::VIEWPORT, &v);
    }

    /// Sends `text` as the clipboard now, if the host does not have it yet. Called on a paste, so
    /// the host has the newest text before the paste keys arrive.
    pub fn offer_clipboard(&self, text: &str) {
        if self.alive.load(Ordering::Relaxed) && self.listed.load(Ordering::SeqCst) {
            offer(&self.conn, &self.clip_last, &self.sill_clip, text);
        }
    }

    /// Sends files and folders to the host's Downloads folder, on a worker thread.
    pub fn send_files(&self, paths: Vec<std::path::PathBuf>) {
        let note = { let (ev, wake) = (self.events.clone(), self.wake.clone());
                     move |t: String| { let _ = ev.send(Event::Note(t)); wake(); } };
        if self.sending.swap(true, Ordering::SeqCst) {
            note("Still sending the last files; try again when they are done".into());
            return;
        }
        let (conn, sending, ids) = (self.conn.clone(), self.sending.clone(), self.file_id.clone());
        let first = ids.fetch_add(100_000, Ordering::SeqCst);
        std::thread::Builder::new().name("send files".into()).spawn(move || {
            if let Err(e) = crate::files::send(&conn, &paths, first, &note) {
                note(e);
            }
            sending.store(false, Ordering::SeqCst);
        }).ok();
    }

    /// Asks the host for the files copied there; they arrive in this computer's Downloads folder.
    pub fn request_files(&self) {
        self.send(wire::FILE_REQUEST, &json!({}));
    }

    pub fn input(&self, v: Value) {
        self.send(wire::INPUT, &v);
    }

    pub fn stop(&self) {
        self.alive.store(false, Ordering::Relaxed);
        self.conn.shutdown();
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop();
    }
}

fn offer(conn: &TlsConn, last: &Mutex<Option<String>>, sill: &AtomicBool, text: &str) {
    let sill = sill.load(Ordering::SeqCst);
    let max = if sill { wire::SILL_CLIPBOARD_TEXT } else { wire::MAX_CLIPBOARD_TEXT };
    if text.is_empty() || text.len() > max {
        return;
    }
    let mut l = last.lock().unwrap();
    if l.as_deref() == Some(text) {
        return;
    }
    *l = Some(text.to_string());
    let kind = if sill { wire::SILL_CLIPBOARD } else { wire::CLIPBOARD };
    let _ = conn.send(&wire::json(kind, &json!({"text": text})));
}
