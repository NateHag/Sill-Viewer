//! This viewer's version, and whether GitHub has a newer one.
//!
//! It only checks, once an hour. Installing is the user's choice: the Update button runs this
//! computer's updater once (Windows: update.ps1 next to the viewer; Mac: scripts/update-mac.sh in
//! the copy of the repository the viewer was built from; Linux: the download page).

use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The newest commit that changed viewer/ when this was built, or "dev".
pub const BUILD: &str = env!("SILL_BUILD");
/// The repository this was built from (the Mac updater lives there).
#[allow(dead_code)]
const REPO_DIR: &str = env!("SILL_REPO");
const API: &str = "https://api.github.com/repos/NateHag/Sill-Viewer/commits?sha=main&path=viewer&per_page=1";
#[allow(dead_code)]
const DOWNLOADS: &str = "https://github.com/NateHag/Sill-Viewer/tree/main/downloads";

pub fn short(sha: &str) -> &str {
    if sha.len() >= 7 && sha != "dev" { &sha[..7] } else { sha }
}

#[derive(Clone, Default)]
pub struct Checker {
    /// GitHub's newest commit for viewer/, and whether it comes after this build.
    newest: Arc<Mutex<Option<(String, bool)>>>,
}

impl Checker {
    pub fn start(wake: Arc<dyn Fn() + Send + Sync>) -> Checker {
        let c = Checker::default();
        let newest = c.newest.clone();
        std::thread::Builder::new().name("update-check".into()).spawn(move || {
            std::thread::sleep(Duration::from_secs(10));
            loop {
                match newest_commit() {
                    Some(sha) => {
                        let changed = newest.lock().unwrap().as_ref().map(|n| n.0.as_str()) != Some(sha.as_str());
                        if changed {
                            // Only a newer version is an update: not an older one, not another branch.
                            let newer = BUILD != "dev" && sha != BUILD && is_ahead(BUILD, &sha);
                            if newer {
                                log::info!("update available: this is {}, GitHub has {}", short(BUILD), short(&sha));
                            }
                            *newest.lock().unwrap() = Some((sha, newer));
                            wake();
                        }
                    }
                    None => log::info!("update check: no answer from GitHub; trying again in an hour"),
                }
                std::thread::sleep(Duration::from_secs(3600));
            }
        }).ok();
        c
    }

    pub fn available(&self) -> bool {
        self.newest.lock().unwrap().as_ref().is_some_and(|n| n.1)
    }
}

fn quiet(cmd: &mut Command) -> &mut Command {
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: no console flashes up
    }
    cmd
}

/// A GET to GitHub's API. curl is on every Mac, every Linux desktop and Windows 10 and later.
fn github(url: &str) -> Option<Vec<u8>> {
    let mut cmd = Command::new("curl");
    quiet(&mut cmd).stdout(Stdio::piped());
    cmd.args(["-fsSL", "--max-time", "20", "-H", "User-Agent: sill-viewer", "-H", "Accept: application/vnd.github+json", url]);
    cmd.output().ok().filter(|o| o.status.success()).map(|o| o.stdout)
}

/// The sha of the newest commit in viewer/ on GitHub's main.
fn newest_commit() -> Option<String> {
    parse_newest(&github(API)?)
}

/// True when `head` comes after `base` in GitHub's history (its compare says "ahead"). An unknown
/// build (never pushed) or no answer: false.
fn is_ahead(base: &str, head: &str) -> bool {
    let url = format!("https://api.github.com/repos/NateHag/Sill-Viewer/compare/{base}...{head}");
    github(&url).is_some_and(|b| parse_status(&b).as_deref() == Some("ahead"))
}

fn parse_status(body: &[u8]) -> Option<String> {
    let v: serde_json::Value = serde_json::from_slice(body).ok()?;
    v.get("status")?.as_str().map(String::from)
}

fn parse_newest(body: &[u8]) -> Option<String> {
    let v: serde_json::Value = serde_json::from_slice(body).ok()?;
    let sha = v.get(0)?.get("sha")?.as_str()?;
    (sha.len() == 40 && sha.bytes().all(|b| b.is_ascii_hexdigit())).then(|| sha.to_string())
}

/// The update button's label on this computer.
pub fn button_label() -> &'static str {
    if cfg!(target_os = "linux") { "Download" } else { "Update" }
}

/// Starts this computer's updater once. It quits this viewer, installs the new one and opens it.
/// Returns what to tell the user.
pub fn start_self_update() -> Result<String, String> {
    #[cfg(windows)]
    {
        let dir = std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.to_path_buf()))
            .ok_or("cannot find where the viewer is")?;
        let script = dir.join("update.ps1");
        if !script.exists() {
            return Err("No updater next to the viewer. Run install-sill-viewer.ps1 from GitHub once.".into());
        }
        let mut cmd = Command::new("powershell.exe");
        quiet(&mut cmd).args(["-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&script).args(["-Update", "-Force"]);
        cmd.spawn().map_err(|e| format!("could not start the updater: {e}"))?;
        return Ok("Updating… Sill Viewer closes and opens again in a moment.".into());
    }
    #[cfg(target_os = "macos")]
    {
        let script = std::path::Path::new(REPO_DIR).join("scripts/update-mac.sh");
        if !script.exists() {
            return Err(format!("No updater at {}.", script.display()));
        }
        let mut cmd = Command::new("/bin/bash");
        quiet(&mut cmd).arg(&script).arg("viewer");
        cmd.spawn().map_err(|e| format!("could not start the updater: {e}"))?;
        return Ok("Updating… this takes a few minutes (it builds the viewer). It opens again when done.".into());
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let mut cmd = Command::new("xdg-open");
        quiet(&mut cmd).arg(DOWNLOADS);
        cmd.spawn().map_err(|e| format!("could not open {DOWNLOADS}: {e}"))?;
        return Ok("Opened the download page: get SillViewer-linux.tar.gz.".into());
    }
    #[allow(unreachable_code)]
    Err("no updater for this system".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(short(&"a".repeat(40)), "aaaaaaa");
        assert_eq!(short("dev"), "dev");
        assert!(!Checker::default().available());
    }

    #[test]
    fn compare_answer() {
        assert_eq!(parse_status(br#"{"status":"ahead","ahead_by":2}"#).as_deref(), Some("ahead"));
        assert_eq!(parse_status(br#"{"status":"behind"}"#).as_deref(), Some("behind"));
        assert_eq!(parse_status(br#"{"message":"Not Found"}"#), None);
    }

    /// Asks the real GitHub (needs the network): run with `cargo test -- --ignored`.
    #[test]
    #[ignore]
    fn compare_on_github() {
        let main_old = "fc9077bf13fde6567253a4137c5e1c8ab74e8bff";
        let branch = "61edf65bb30b68230755d336037f10417a42c630";
        assert!(is_ahead(main_old, branch));
        assert!(!is_ahead(branch, main_old));
    }

    #[test]
    fn github_answer() {
        let sha = "0324ae7ed1b6af8be22e4146b5de270fad6a035f";
        let body = format!(r#"[{{"sha":"{sha}","commit":{{"message":"x"}}}}]"#);
        assert_eq!(parse_newest(body.as_bytes()).as_deref(), Some(sha));
        assert_eq!(parse_newest(b"[]"), None);
        assert_eq!(parse_newest(br#"{"message":"API rate limit exceeded"}"#), None);
    }
}
