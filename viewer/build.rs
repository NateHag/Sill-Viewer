//! Windows: icon, version information and manifest in the .exe. An .exe with none of these looks
//! more like malware to antivirus heuristics (Defender flagged the bare build).
use std::path::PathBuf;
use std::process::Command;

/// The version stamp: the newest commit that changed viewer/ (SILL_BUILD overrides it), or "dev"
/// when this folder has changes that are not committed. And the repository's folder (SILL_REPO),
/// where the Mac updater is.
fn stamp() {
    println!("cargo:rerun-if-env-changed=SILL_BUILD");
    let git = |args: &[&str]| -> Option<String> {
        let o = Command::new("git").args(args).output().ok()?;
        o.status.success().then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
    };
    if let Some(dir) = git(&["rev-parse", "--absolute-git-dir"]) {
        println!("cargo:rerun-if-changed={dir}/HEAD");
        println!("cargo:rerun-if-changed={dir}/logs/HEAD");
        println!("cargo:rerun-if-changed={dir}/index");
    }
    let build = std::env::var("SILL_BUILD").ok().filter(|s| !s.is_empty()).or_else(|| {
        let clean = git(&["status", "--porcelain", "--", "."]).is_some_and(|s| s.is_empty());
        let sha = git(&["log", "-1", "--format=%H", "--", "."])?;
        (clean && sha.len() == 40).then_some(sha)
    }).unwrap_or_else(|| "dev".into());
    println!("cargo:rustc-env=SILL_BUILD={build}");
    let repo = git(&["rev-parse", "--show-toplevel"]).unwrap_or_default();
    println!("cargo:rustc-env=SILL_REPO={repo}");
}

fn main() {
    stamp();
    println!("cargo:rerun-if-changed=windows/app.rc");
    println!("cargo:rerun-if-changed=windows/app.ico");
    println!("cargo:rerun-if-changed=windows/app.manifest");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("app-res.o");
    let windres = std::env::var("WINDRES").unwrap_or_else(|_| {
        if cfg!(windows) { "windres".into() } else { "x86_64-w64-mingw32-windres".into() }
    });
    let ok = Command::new(&windres)
        .current_dir("windows")
        .args(["app.rc", "-O", "coff", "-o"])
        .arg(&out)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if ok {
        println!("cargo:rustc-link-arg-bins={}", out.display());
    } else {
        println!("cargo:warning=no Windows resources: {windres} failed");
    }
}
