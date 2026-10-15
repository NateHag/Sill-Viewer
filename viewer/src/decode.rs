//! HEVC decoding with FFmpeg: the graphics card when it can (D3D11VA on Windows, VideoToolbox on
//! Mac, CUDA or VA-API on Linux), else software. Runs on its own thread; the newest picture wins.

use crate::session::VideoPacket;
use crate::wire;
use ffmpeg_next as ff;
use ff::ffi;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Format {
    Nv12,
    I420,
}

pub struct Picture {
    pub width: u32,
    pub height: u32,
    pub format: Format,
    pub full_range: bool,
    /// Tightly packed planes: Y, then UV (NV12) or U and V (I420).
    pub planes: Vec<Vec<u8>>,
}

#[derive(Default)]
pub struct Shared {
    pub latest: Option<Picture>,
    pub decoded: u64,
    pub decoder: String,
    pub size: (u32, u32),
}

fn hw_types() -> Vec<ffi::AVHWDeviceType> {
    use ffi::AVHWDeviceType::*;
    if cfg!(target_os = "windows") {
        vec![AV_HWDEVICE_TYPE_D3D11VA, AV_HWDEVICE_TYPE_DXVA2]
    } else if cfg!(target_os = "macos") {
        vec![AV_HWDEVICE_TYPE_VIDEOTOOLBOX]
    } else {
        vec![AV_HWDEVICE_TYPE_CUDA, AV_HWDEVICE_TYPE_VAAPI]
    }
}

/// The first graphics-card decoder device that opens, tried on its own thread: a driver that never
/// answers must not freeze the picture, so after 4 s this gives up and software decoding runs.
fn hw_device() -> Option<(usize, String)> {
    // A driver that hung once may hold a lock the software decoder also needs: after a hang, this
    // viewer skips the graphics card until the marker file is deleted.
    let marker = crate::identity::config_dir().join("hardware-decoder-hung");
    if marker.exists() {
        log::warn!("skipping the graphics card's decoder: it hung before (delete {marker:?} to try again)");
        return None;
    }
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for t in hw_types() {
            let mut dev: *mut ffi::AVBufferRef = std::ptr::null_mut();
            let ok = unsafe { ffi::av_hwdevice_ctx_create(&mut dev, t, std::ptr::null(), std::ptr::null_mut(), 0) } == 0;
            if ok {
                let name = format!("{t:?}").replace("AV_HWDEVICE_TYPE_", "").to_lowercase();
                let _ = tx.send(Some((dev as usize, name)));
                return;
            }
        }
        let _ = tx.send(None);
    });
    match rx.recv_timeout(std::time::Duration::from_secs(4)) {
        Ok(r) => r,
        Err(_) => {
            log::warn!("the graphics card's decoder did not answer in 4 s; decoding in software");
            let _ = std::fs::write(&marker, b"hung\n");
            HW_HUNG.store(true, std::sync::atomic::Ordering::Relaxed);
            None
        }
    }
}

/// Set when the graphics card's decoder hung in this run: the window says to reopen the app.
pub static HW_HUNG: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

struct Decoder {
    dec: ff::decoder::Video,
    hw: Option<String>,
}

fn open(hardware: bool) -> Result<Decoder, String> {
    let codec = ff::decoder::find(ff::codec::Id::HEVC).ok_or("FFmpeg has no HEVC decoder")?;
    let mut ctx = ff::codec::context::Context::new_with_codec(codec);
    let mut hw = None;
    unsafe {
        let p = ctx.as_mut_ptr();
        (*p).flags |= ffi::AV_CODEC_FLAG_LOW_DELAY as i32;
        if hardware && std::env::var_os("SILL_SOFTWARE_DECODE").is_none() {
            if let Some((dev, name)) = hw_device() {
                let mut dev = dev as *mut ffi::AVBufferRef;
                (*p).hw_device_ctx = ffi::av_buffer_ref(dev);
                ffi::av_buffer_unref(&mut dev);
                hw = Some(name);
            }
        }
        if hw.is_some() {
            (*p).thread_count = 1;
        } else {
            // Software: frame threads cost a few frames of delay but keep 4K at 60 fps.
            (*p).thread_count = std::env::var("SILL_DECODE_THREADS").ok().and_then(|v| v.parse().ok())
                // Windows: frame threads hung in tests (under Wine); the graphics card is the usual path there.
                .unwrap_or(if cfg!(windows) { 1 } else { 0 });
            (*p).thread_type = 1 | 2;
        }
    }
    let dec = ctx.decoder().video().map_err(|e| format!("open HEVC decoder: {e}"))?;
    Ok(Decoder { dec, hw })
}

fn tight(frame: &ff::frame::Video, plane: usize, width_bytes: usize, rows: usize) -> Vec<u8> {
    let stride = frame.stride(plane);
    let data = frame.data(plane);
    if stride == width_bytes {
        return data[..width_bytes * rows].to_vec();
    }
    let mut out = Vec::with_capacity(width_bytes * rows);
    for r in 0..rows {
        out.extend_from_slice(&data[r * stride..r * stride + width_bytes]);
    }
    out
}

fn picture(frame: &ff::frame::Video) -> Option<Picture> {
    let (w, h) = (frame.width() as usize, frame.height() as usize);
    let (cw, ch) = ((w + 1) / 2, (h + 1) / 2);
    let full_range = frame.color_range() == ff::util::color::Range::JPEG;
    use ff::format::Pixel;
    match frame.format() {
        Pixel::NV12 => Some(Picture {
            width: w as u32, height: h as u32, format: Format::Nv12, full_range,
            planes: vec![tight(frame, 0, w, h), tight(frame, 1, cw * 2, ch)],
        }),
        Pixel::YUV420P | Pixel::YUVJ420P => Some(Picture {
            width: w as u32, height: h as u32, format: Format::I420,
            full_range: full_range || frame.format() == Pixel::YUVJ420P,
            planes: vec![tight(frame, 0, w, h), tight(frame, 1, cw, ch), tight(frame, 2, cw, ch)],
        }),
        other => {
            log::warn!("unsupported pixel format {other:?}");
            None
        }
    }
}

pub fn spawn(rx: Receiver<VideoPacket>, shared: Arc<Mutex<Shared>>, wake: Arc<dyn Fn() + Send + Sync>) {
    std::thread::Builder::new().name("decode".into()).spawn(move || {
        log::info!("decoder thread starting");
        let _ = ff::init();
        unsafe { ffi::av_log_set_level(ffi::AV_LOG_ERROR) };
        let mut dec = match open(true) {
            Ok(d) => d,
            Err(e) => {
                log::error!("{e}");
                return;
            }
        };
        log::info!("decoder ready: {}", dec.hw.as_deref().unwrap_or("software"));
        let mut use_hw = dec.hw.is_some();
        shared.lock().unwrap().decoder = dec.hw.clone().unwrap_or_else(|| "software".into());
        let mut annexb = Vec::new();
        let mut have_key = false;
        let mut params: Option<Vec<Vec<u8>>> = None;
        let mut frame = ff::frame::Video::empty();
        let mut sw = ff::frame::Video::empty();
        let mut errors = 0;
        while let Ok(mut pkt) = rx.recv() {
            if let Some(p) = pkt.params.take() {
                // New parameter sets mean a new stream: another size or format. A hardware decoder
                // can keep its old, larger surfaces and write the new picture into their top-left
                // corner, so the old picture shows around it. A fresh decoder starts clean.
                if params.as_ref().is_some_and(|old| *old != p) {
                    log::info!("the stream changed (new parameter sets): reopening the decoder");
                    if let Ok(d) = open(use_hw) {
                        dec = d;
                        if dec.hw.is_none() {
                            use_hw = false;
                        }
                    }
                }
                params = Some(p);
            }
            if !have_key {
                if !pkt.key || params.is_none() {
                    continue;          // the decoder starts at a keyframe with its parameter sets
                }
                have_key = true;
            }
            let ps = if pkt.key { params.as_deref() } else { None };
            wire::to_annexb(ps, &pkt.au, pkt.nal_len, &mut annexb);
            let packet = ff::Packet::copy(&annexb);
            if let Err(e) = dec.dec.send_packet(&packet) {
                log::warn!("send_packet: {e}");
                errors += 1;
                log::warn!("decode: {e}");
                if errors > 5 && use_hw {
                    log::warn!("hardware decoding fails here; switching to software");
                    use_hw = false;
                    if let Ok(d) = open(false) {
                        dec = d;
                        shared.lock().unwrap().decoder = "software".into();
                    }
                    have_key = false;
                    errors = 0;
                }
                continue;
            }
            // Many packets waiting means the decoder is behind: decode them all, show the last.
            let mut newest = None;
            while dec.dec.receive_frame(&mut frame).is_ok() {
                errors = 0;
                let src = if frame.format() == ff::format::Pixel::None || is_hw(&frame) {
                    // A fresh frame each time: given one that already holds buffers, FFmpeg copies
                    // into them at their old size, so a smaller picture lands in the top-left
                    // corner of the last bigger one and the rest of that one stays on screen.
                    sw = ff::frame::Video::empty();
                    unsafe {
                        if ffi::av_hwframe_transfer_data(sw.as_mut_ptr(), frame.as_ptr(), 0) < 0 {
                            continue;
                        }
                    }
                    &sw
                } else {
                    &frame
                };
                newest = picture(src);
            }
            if let Some(p) = newest {
                let mut s = shared.lock().unwrap();
                s.decoded += 1;
                s.size = (p.width, p.height);
                s.latest = Some(p);
                drop(s);
                wake();
            }
        }
    }).ok();
}

fn is_hw(frame: &ff::frame::Video) -> bool {
    unsafe { !(*frame.as_ptr()).hw_frames_ctx.is_null() }
}
