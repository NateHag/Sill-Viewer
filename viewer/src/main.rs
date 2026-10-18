//! Sill Viewer: a desktop app for Sill hosts (a Mac with Sill, or Linux with sill-linux).
//!
//!   sill-viewer                       the window
//!   sill-viewer --headless ADDR ...   a test run without a window (see `headless`)

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod app;
mod decode;
mod discovery;
mod files;
mod identity;
mod input;
#[cfg(target_os = "macos")]
mod macos;
mod pairing;
mod render;
mod session;
mod single;
mod tls;
mod tray;
#[cfg(windows)]
mod win;
mod wire;

use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub fn os_name() -> &'static str {
    if cfg!(target_os = "windows") { "Windows" } else if cfg!(target_os = "macos") { "macOS" } else { "Linux" }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut logger = env_logger::Builder::from_env(env_logger::Env::default()
        .default_filter_or("info,wgpu_core=warn,wgpu_hal=warn,naga=warn,mdns_sd=warn"));
    if let Some(f) = std::env::var_os("SILL_LOG_FILE").and_then(|p| std::fs::File::create(p).ok()) {
        logger.target(env_logger::Target::Pipe(Box::new(f)));
    } else if args.iter().any(|a| a == "--headless") {
        logger.target(env_logger::Target::Stdout);
    }
    logger.init();
    let id = match identity::Identity::load_or_create() {
        Ok(i) => i,
        Err(e) => {
            eprintln!("identity: {e}");
            std::process::exit(1);
        }
    };
    if let Some(i) = args.iter().position(|a| a == "--headless") {
        std::process::exit(headless(&args[i + 1..], id));
    }
    // Windows: DirectX 12 first (smooth window moves with its flip model; Vulkan stutters there),
    // in step with the screen, at most one frame queued. If DirectX 12 does not start, Vulkan or GL.
    // WGPU_BACKEND (vulkan, dx12, gl) picks one by hand.
    match single::start() {
        single::Start::Exit => return,
        single::Start::Run(l) => single::listen(l),
    }
    let chosen = std::env::var("WGPU_BACKEND").ok().map(|_| eframe::wgpu::util::backend_bits_from_env().unwrap_or(eframe::wgpu::Backends::PRIMARY));
    let mut tries = vec![chosen.unwrap_or(if cfg!(windows) { eframe::wgpu::Backends::DX12 } else { eframe::wgpu::Backends::PRIMARY | eframe::wgpu::Backends::GL })];
    if cfg!(windows) && chosen.is_none() {
        tries.push(eframe::wgpu::Backends::VULKAN | eframe::wgpu::Backends::GL);
    }
    let id = std::cell::RefCell::new(Some(id));
    for (n, backends) in tries.iter().enumerate() {
        let mut options = eframe::NativeOptions {
            viewport: eframe::egui::ViewportBuilder::default().with_title("Sill Viewer (unofficial)").with_inner_size([1280.0, 800.0]),
            renderer: eframe::Renderer::Wgpu,
            vsync: cfg!(windows),
            ..Default::default()
        };
        options.wgpu_options.supported_backends = *backends;
        options.wgpu_options.desired_maximum_frame_latency = Some(1);
        log::info!("graphics: trying {backends:?}");
        let r = eframe::run_native("Sill Viewer", options, Box::new(|cc| {
            Ok(Box::new(app::App::new(cc, id.borrow_mut().take().expect("identity"))))
        }));
        match r {
            Ok(()) => return,
            Err(e) if n + 1 < tries.len() && id.borrow().is_some() => log::warn!("graphics {backends:?} failed: {e}; trying the next"),
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
    }
}

/// `--headless ADDR [--seconds N] [--ask-code-file FILE] [--any-key]`: connect (pairing first with
/// the code read from FILE once the host shows it), stream the desktop, decode, print stats.
fn headless(a: &[String], id: identity::Identity) -> i32 {
    let addr = a.first().cloned().unwrap_or_default();
    let opt = |name: &str| a.iter().position(|x| x == name).and_then(|i| a.get(i + 1)).cloned();
    let seconds: u64 = opt("--seconds").and_then(|s| s.parse().ok()).unwrap_or(5);
    let mut hosts = identity::load_hosts();
    let mut pin = hosts.iter().find(|h| h.last_address.as_deref() == Some(addr.as_str())).and_then(|h| h.fp());
    if a.iter().any(|x| x == "--any-key") {
        pin = None;
    }
    if let Some(file) = opt("--ask-code-file") {
        match pairing::ask(&addr, &id) {
            Ok((reason, fp)) => {
                println!("ASK {reason}");
                let deadline = Instant::now() + Duration::from_secs(10);
                let code = loop {
                    if let Ok(c) = std::fs::read_to_string(&file) {
                        if pairing::check_code(c.trim()).is_ok() {
                            break c.trim().to_string();
                        }
                    }
                    if Instant::now() > deadline {
                        println!("PAIR FAIL: no code in {file}");
                        return 1;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                };
                match pairing::pair_with_code(&addr, &id, &code, Some(fp)) {
                    Ok(h) => {
                        println!("PAIR ok: {} ({})", h.name, h.mac_id);
                        pin = h.fp();
                        hosts.retain(|x| x.mac_id != h.mac_id);
                        hosts.push(h);
                        identity::save_hosts(&hosts);
                    }
                    Err(e) => {
                        println!("PAIR FAIL: {e}");
                        return 1;
                    }
                }
            }
            Err(e) => {
                println!("ASK FAIL: {e}");
                return 1;
            }
        }
    }
    let (ev_tx, ev_rx) = channel();
    let (v_tx, v_rx) = channel();
    let shared = Arc::new(Mutex::new(decode::Shared::default()));
    let wake: Arc<dyn Fn() + Send + Sync> = Arc::new(|| {});
    let s = match session::Session::start(&addr, &id, pin, ev_tx, v_tx, wake.clone()) {
        Ok(s) => s,
        Err(e) => {
            println!("SESSION FAIL: {e}");
            return 1;
        }
    };
    println!("SESSION ok: {} ({})", s.peer_addr, identity::mac_id(&s.host_fp));
    decode::spawn(v_rx, shared.clone(), wake);
    let fps: u32 = opt("--fps").and_then(|v| v.parse().ok()).unwrap_or(60);
    if fps > 60 {
        s.send(wire::CHANGE_SETTINGS, &serde_json::json!({"token": 1, "maxFPS": fps}));
    }
    s.viewport(1280.0, 800.0, fps, opt("--pixels").and_then(|p| { let (w, h) = p.split_once('x')?; Some((w.parse().ok()?, h.parse().ok()?, opt("--scale").and_then(|v| v.parse().ok()).unwrap_or(1.0))) }), 1.0);
    if let Some(p) = opt("--send") {
        s.send_files(vec![std::path::PathBuf::from(p)]);
    }
    if a.iter().any(|x| x == "--get-files") {
        s.request_files();
    }
    let start = Instant::now();
    let mut last = 0u64;
    let mut rtt = 0.0;
    while start.elapsed() < Duration::from_secs(seconds) {
        while let Ok(ev) = ev_rx.try_recv() {
            match ev {
                session::Event::WindowList(v) => {
                    println!("  windowList: {} windows, active {}", v["windows"].as_array().map_or(0, |w| w.len()), v["active"]);
                    if v["active"].get("none").is_some() {
                        s.select(serde_json::json!({"desktop": {}}));
                    }
                }
                session::Event::HostSettings(v) => println!("  settings: {}", v["settings"]),
                session::Event::Rtt(ms) => rtt = ms,
                session::Event::Note(t) => println!("  note: {t}"),
                session::Event::Goodbye(v) => println!("  goodbye: {v}"),
                session::Event::Ended(why) => {
                    println!("ENDED: {why}");
                    return 1;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(100));
        if start.elapsed().as_secs() > last {
            last = start.elapsed().as_secs();
            let sh = shared.lock().unwrap();
            println!("t={last}s received={} decoded={} size={}x{} decoder={} rtt={rtt:.1}ms",
                     s.frames.load(std::sync::atomic::Ordering::Relaxed), sh.decoded, sh.size.0, sh.size.1, sh.decoder);
        }
    }
    // A short input sequence, so a host's logs show it arrives.
    s.input(input::pointer("move", 0.5, 0.5));
    s.input(input::scroll_phase("began", 0.5, 0.5));
    s.input(input::scroll(0.5, 0.5, 0.0, 0.05));
    s.input(input::scroll_phase("ended", 0.5, 0.5));
    std::thread::sleep(Duration::from_millis(200));
    let sh = shared.lock().unwrap();
    println!("DONE decoded={} decoder={}", sh.decoded, sh.decoder);
    if sh.decoded > 0 { 0 } else { 1 }
}
