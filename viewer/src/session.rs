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
        let (clip_tx, clip_rx) = channel::<String>();

        {
            let (conn, alive, frames, wake) = (conn.clone(), alive.clone(), frames.clone(), wake.clone());
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
                            let _ = video.send(VideoPacket { params: ps, nal_len, au: m.payload, key: m.key });
                        }
                        wire::WINDOW_LIST | wire::HOST_SETTINGS | wire::GOODBYE => {
                            if let Ok(v) = serde_json::from_slice::<Value>(&m.payload) {
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
                        wire::CLIPBOARD => {
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
            let (conn, alive) = (conn.clone(), alive.clone());
            std::thread::Builder::new().name("session ping".into()).spawn(move || {
                while alive.load(Ordering::Relaxed) {
                    if conn.send(&tls::ping_payload(start.elapsed().as_secs_f64())).is_err() {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(250));
                }
            }).map_err(|e| e.to_string())?;
        }
        {
            // The clipboard: text from the host goes on this computer's clipboard; text copied
            // here goes to the host (checked twice a second, while this window has the focus).
            let (conn, alive, focused, last) = (conn.clone(), alive.clone(), focused.clone(), clip_last.clone());
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
                            if focused.load(Ordering::Relaxed) {
                                if let Ok(t) = cb.get_text() {
                                    offer(&conn, &last, &t);
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
        Ok(Session { conn, alive, focused, clip_last, frames, host_fp, peer_addr })
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
    pub fn viewport(&self, width: f64, height: f64, fps: u32, pixels: Option<(u32, u32, f32)>) {
        let mut v = json!({"width": width, "height": height, "fps": fps});
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
        if self.alive.load(Ordering::Relaxed) {
            offer(&self.conn, &self.clip_last, text);
        }
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

fn offer(conn: &TlsConn, last: &Mutex<Option<String>>, text: &str) {
    if text.is_empty() || text.len() > wire::MAX_CLIPBOARD_TEXT {
        return;
    }
    let mut l = last.lock().unwrap();
    if l.as_deref() == Some(text) {
        return;
    }
    *l = Some(text.to_string());
    let _ = conn.send(&wire::json(wire::CLIPBOARD, &json!({"text": text})));
}
