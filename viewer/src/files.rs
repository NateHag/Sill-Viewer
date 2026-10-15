//! Files both ways: dropped files go to the host's Downloads folder; the files copied on the host
//! come to this computer's Downloads folder. Each file is a ".part" until it is complete.

use crate::tls::TlsConn;
use crate::wire;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};

pub fn downloads_dir() -> PathBuf {
    let d = dirs::download_dir().or_else(|| dirs::home_dir().map(|h| h.join("Downloads"))).unwrap_or_else(|| ".".into());
    let _ = std::fs::create_dir_all(&d);
    d
}

/// A relative path that stays inside the folder.
fn safe_relative(name: &str) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for part in name.replace('\\', "/").split('/') {
        if part.is_empty() || part == "." || part == ".." || part.starts_with('~') || part.contains(':') {
            continue;
        }
        out.push(part.replace('\0', ""));
    }
    if out.components().all(|c| matches!(c, Component::Normal(_))) && out.components().next().is_some() {
        Some(out)
    } else {
        None
    }
}

fn part(p: &Path) -> PathBuf {
    let mut s = p.as_os_str().to_owned();
    s.push(".part");
    s.into()
}

fn unique(p: PathBuf) -> PathBuf {
    if !p.exists() && !part(&p).exists() {
        return p;
    }
    let stem = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let ext = p.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    let dir = p.parent().map(Path::to_path_buf).unwrap_or_default();
    (1..).map(|n| dir.join(format!("{stem} ({n}){ext}"))).find(|c| !c.exists() && !part(c).exists()).unwrap()
}

/// Files the host is sending here.
#[derive(Default)]
pub struct Incoming {
    open: HashMap<u32, (File, PathBuf, u64, u64)>,
    folders: HashMap<i64, PathBuf>,
    saved: Vec<PathBuf>,
}

impl Incoming {
    /// Handles one file message; returns a note for the person, if any.
    pub fn on_message(&mut self, kind: u8, payload: &[u8]) -> Option<String> {
        match kind {
            wire::FILE_DATA if payload.len() >= 4 => {
                let id = u32::from_be_bytes(payload[..4].try_into().unwrap());
                if let Some(t) = self.open.get_mut(&id) {
                    if t.0.write_all(&payload[4..]).is_err() {
                        let name = t.1.display().to_string();
                        self.drop_one(id);
                        return Some(format!("Could not save {name}"));
                    }
                    t.3 += (payload.len() - 4) as u64;
                }
                None
            }
            wire::FILE_START => {
                let v: Value = serde_json::from_slice(payload).ok()?;
                let id = v["id"].as_u64()? as u32;
                let size = v["size"].as_u64()?;
                let rel = safe_relative(v["name"].as_str()?)?;
                let top = downloads_dir();
                let mut parts = rel.components();
                let first = PathBuf::from(parts.next()?.as_os_str());
                let rest: PathBuf = parts.collect();
                let dest = if rest.as_os_str().is_empty() {
                    unique(top.join(&first))
                } else {
                    let root = v["root"].as_i64().unwrap_or(0);
                    let folder = self.folders.entry(root).or_insert_with(|| unique(top.join(&first))).clone();
                    folder.join(rest)
                };
                if let Some(d) = dest.parent() {
                    let _ = std::fs::create_dir_all(d);
                }
                match File::create(part(&dest)) {
                    Ok(f) => {
                        self.open.insert(id, (f, dest, size, 0));
                        None
                    }
                    Err(e) => Some(format!("Could not save {}: {e}", rel.display())),
                }
            }
            wire::FILE_END => {
                let v: Value = serde_json::from_slice(payload).ok()?;
                let id = v["id"].as_u64()? as u32;
                let (f, dest, size, got) = self.open.remove(&id)?;
                drop(f);
                if got != size {
                    let _ = std::fs::remove_file(part(&dest));
                    return Some(format!("{} did not arrive whole", dest.display()));
                }
                let _ = std::fs::rename(part(&dest), &dest);
                log::info!("received {}", dest.display());
                self.saved.push(dest);
                if v["last"] == true {
                    let n = self.saved.len();
                    self.saved.clear();
                    self.folders.clear();
                    return Some(format!("Saved {n} file{} to {}", if n == 1 { "" } else { "s" }, downloads_dir().display()));
                }
                None
            }
            wire::FILE_CANCEL => {
                let v: Value = serde_json::from_slice(payload).ok()?;
                self.drop_one(v["id"].as_u64()? as u32);
                None
            }
            _ => None,
        }
    }

    fn drop_one(&mut self, id: u32) {
        if let Some((f, dest, _, _)) = self.open.remove(&id) {
            drop(f);
            let _ = std::fs::remove_file(part(&dest));
        }
    }
}

impl Drop for Incoming {
    fn drop(&mut self) {
        for id in self.open.keys().copied().collect::<Vec<_>>() {
            self.drop_one(id);
        }
    }
}

/// (local path, relative name, root index) for every file, folders included.
pub fn walk(paths: &[PathBuf]) -> Vec<(PathBuf, String, usize)> {
    fn add(dir: &Path, base: &Path, root: usize, out: &mut Vec<(PathBuf, String, usize)>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        let mut entries: Vec<_> = rd.flatten().map(|e| e.path()).collect();
        entries.sort();
        for p in entries {
            let Ok(meta) = std::fs::symlink_metadata(&p) else { continue };
            if meta.is_dir() {
                add(&p, base, root, out);
            } else if meta.is_file() {
                let rel = p.strip_prefix(base).unwrap_or(&p).components()
                    .map(|c| c.as_os_str().to_string_lossy().to_string()).collect::<Vec<_>>().join("/");
                out.push((p.clone(), rel, root));
            }
        }
    }
    let mut out = Vec::new();
    for (i, p) in paths.iter().enumerate() {
        if p.is_dir() {
            add(p, p.parent().unwrap_or(Path::new("")), i, &mut out);
        } else if p.is_file() {
            out.push((p.clone(), p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(), i));
        }
    }
    out
}

/// Sends files to the host (call on a worker thread). `note` reports progress.
pub fn send(conn: &TlsConn, paths: &[PathBuf], first_id: u32, note: &dyn Fn(String)) -> Result<usize, String> {
    let items = walk(paths);
    if items.is_empty() {
        return Err("Nothing to send (only files and folders can be sent)".into());
    }
    let total: u64 = items.iter().filter_map(|(p, _, _)| std::fs::metadata(p).ok()).map(|m| m.len()).sum();
    let mut sent_bytes = 0u64;
    let mut last_note = std::time::Instant::now();
    note(format!("Sending {} file{} ({:.1} MB)…", items.len(), if items.len() == 1 { "" } else { "s" }, total as f64 / 1e6));
    let mut buf = vec![0u8; wire::FILE_CHUNK];
    for (i, (path, name, root)) in items.iter().enumerate() {
        let id = first_id + i as u32;
        let mut f = File::open(path).map_err(|e| format!("Could not read {name}: {e}"))?;
        let size = f.metadata().map(|m| m.len()).unwrap_or(0);
        let io = |e: std::io::Error| format!("Sending stopped: {e}");
        conn.send(&wire::json(wire::FILE_START, &json!({"id": id, "name": name, "size": size, "root": root}))).map_err(io)?;
        loop {
            let n = f.read(&mut buf).map_err(|e| format!("Could not read {name}: {e}"))?;
            if n == 0 {
                break;
            }
            let mut payload = Vec::with_capacity(4 + n);
            payload.extend_from_slice(&id.to_be_bytes());
            payload.extend_from_slice(&buf[..n]);
            conn.send(&wire::pack(wire::FILE_DATA, &payload, false, None)).map_err(io)?;
            sent_bytes += n as u64;
            if last_note.elapsed().as_millis() > 500 && total > 0 {
                last_note = std::time::Instant::now();
                note(format!("Sending… {:.0}%", sent_bytes as f64 * 100.0 / total as f64));
            }
        }
        conn.send(&wire::json(wire::FILE_END, &json!({"id": id, "last": i + 1 == items.len()}))).map_err(io)?;
    }
    Ok(items.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paths_stay_inside() {
        assert_eq!(safe_relative("../../etc/passwd").unwrap(), PathBuf::from("etc/passwd"));
        assert_eq!(safe_relative("/abs/x.txt").unwrap(), PathBuf::from("abs/x.txt"));
        assert_eq!(safe_relative("a\\b.txt").unwrap(), PathBuf::from("a/b.txt"));
        assert!(safe_relative("..").is_none());
        assert!(safe_relative("C:/x").is_some_and(|p| p == PathBuf::from("x")));
    }
}
