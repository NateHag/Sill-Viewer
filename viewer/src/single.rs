//! One viewer at a time. The running viewer listens on a local port; a new one asks it first.
//! The same build: the running one comes to the front and the new one closes. Another build (an
//! update): the running one quits and the new one takes over.

use eframe::egui;
use std::io::{BufRead, BufReader, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const PORT: u16 = 47457;

/// The window to bring forward when another launch asks; set once the window exists.
pub static CTX: OnceLock<egui::Context> = OnceLock::new();

/// This build: the executable's path, size and time, so a new copy unzipped over the old one counts
/// as another build.
fn build_id() -> String {
    let exe = std::env::current_exe().unwrap_or_default();
    let meta = std::fs::metadata(&exe).ok();
    let len = meta.as_ref().map_or(0, |m| m.len());
    let time = meta.and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs());
    format!("{}|{len}|{time}|{}", env!("CARGO_PKG_VERSION"), exe.display())
}

pub enum Start {
    /// Run, and keep this listener to hear later launches.
    Run(TcpListener),
    /// The running viewer (the same build) came forward: close.
    Exit,
}

pub fn start() -> Start {
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, PORT));
    let me = build_id();
    if let Ok(mut s) = TcpStream::connect_timeout(&addr, Duration::from_millis(500)) {
        let _ = s.set_read_timeout(Some(Duration::from_secs(3)));
        let _ = writeln!(s, "SILL-VIEWER {me}");
        let mut reply = String::new();
        let _ = BufReader::new(&s).read_line(&mut reply);
        if reply.trim() == "shown" {
            log::info!("a viewer of this build already runs; it came to the front");
            return Start::Exit;
        }
        log::info!("an older viewer was running; it quits");
    }
    // Wait for the old one to let go of the port (it quits right after answering).
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match TcpListener::bind(addr) {
            Ok(l) => return Start::Run(l),
            Err(e) if Instant::now() > deadline => {
                log::warn!("cannot watch for other launches: {e}");
                // Still run: one viewer too many is better than none.
                return Start::Run(TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("a local port"));
            }
            Err(_) => std::thread::sleep(Duration::from_millis(100)),
        }
    }
}

/// Answers later launches (a thread).
pub fn listen(l: TcpListener) {
    let me = build_id();
    std::thread::Builder::new().name("single".into()).spawn(move || {
        for s in l.incoming().flatten() {
            let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
            let mut line = String::new();
            if BufReader::new(&s).read_line(&mut line).is_err() || !line.starts_with("SILL-VIEWER ") {
                continue;
            }
            let theirs = line.trim_end().trim_start_matches("SILL-VIEWER ");
            let mut s = s;
            if theirs == me {
                let _ = writeln!(s, "shown");
                if let Some(ctx) = CTX.get() {
                    crate::tray::show_window(ctx);
                }
            } else {
                log::info!("a newer viewer started; quitting");
                let _ = writeln!(s, "bye");
                let _ = s.flush();
                drop(s);
                drop(l);
                std::process::exit(0);
            }
        }
    }).ok();
}
