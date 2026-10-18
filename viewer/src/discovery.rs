//! Bonjour: browse _sill._tcp for hosts on this network.

use mdns_sd::{ServiceDaemon, ServiceEvent};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug)]
pub struct Found {
    pub fullname: String,
    pub name: String,
    pub addresses: Vec<std::net::IpAddr>,
    pub port: u16,
    /// TXT `p`: None = a plain door (old host), Some("0") = open, else pairing required.
    pub door: Option<String>,
    /// TXT `r`: the recognition tag.
    pub tag: Option<String>,
}

impl Found {
    /// "host:port", IPv4 first.
    pub fn address(&self) -> Option<String> {
        let mut a = self.addresses.clone();
        a.sort_by_key(|ip| match ip {
            std::net::IpAddr::V4(_) => 0,
            std::net::IpAddr::V6(v) if (v.segments()[0] & 0xffc0) != 0xfe80 => 1,
            _ => 2,   // link-local IPv6 needs an interface to dial
        });
        a.first().map(|ip| match ip {
            std::net::IpAddr::V4(v) => format!("{v}:{}", self.port),
            std::net::IpAddr::V6(v) => format!("[{v}]:{}", self.port),
        })
    }

    pub fn pairing_required(&self) -> bool {
        self.door.as_deref() != Some("0")
    }
}

pub struct Browser {
    pub found: Arc<Mutex<Vec<Found>>>,
    _daemon: Option<ServiceDaemon>,
}

impl Browser {
    pub fn start(wake: Arc<dyn Fn() + Send + Sync>) -> Browser {
        let found = Arc::new(Mutex::new(Vec::<Found>::new()));
        let daemon = match ServiceDaemon::new() {
            Ok(d) => d,
            Err(e) => {
                log::warn!("Bonjour unavailable: {e}");
                return Browser { found, _daemon: None };
            }
        };
        let rx = match daemon.browse("_sill._tcp.local.") {
            Ok(r) => r,
            Err(e) => {
                log::warn!("Bonjour browse: {e}");
                return Browser { found, _daemon: Some(daemon) };
            }
        };
        let list = found.clone();
        std::thread::Builder::new().name("bonjour".into()).spawn(move || {
            while let Ok(ev) = rx.recv() {
                match ev {
                    ServiceEvent::ServiceResolved(info) => {
                        let fullname = info.get_fullname().to_string();
                        // A Mac also announces itself on its loopback interface: 127.0.0.1 and ::1 mean
                        // "the computer that sent this", never this one, and cannot be dialed from here.
                        let addrs: Vec<std::net::IpAddr> = info.get_addresses().iter().map(|a| a.to_ip_addr())
                            .filter(|a| !a.is_loopback() && !a.is_unspecified()).collect();
                        log::info!("found {fullname} at {addrs:?} port {}", info.get_port());
                        // A host on this same computer (a Mac running Sill): never offer it.
                        if addrs.is_empty() {
                            continue;
                        }
                        if is_this_computer(addrs.iter()) {
                            log::info!("not listing {fullname}: it is this computer");
                            continue;
                        }
                        // Addresses can miss (a VPN, a second network): the host name is a second check.
                        if let Some(mine) = this_host_name() {
                            if same_host(info.get_hostname(), mine) {
                                log::info!("not listing {fullname}: host {} is this computer", info.get_hostname());
                                continue;
                            }
                        }
                        let name = fullname.strip_suffix("._sill._tcp.local.").unwrap_or(&fullname).replace("\\032", " ");
                        let f = Found {
                            name,
                            addresses: addrs.clone(),
                            port: info.get_port(),
                            door: info.get_property_val_str("p").map(String::from),
                            tag: info.get_property_val_str("r").map(String::from),
                            fullname: fullname.clone(),
                        };
                        let mut l = list.lock().unwrap();
                        l.retain(|x| x.fullname != fullname);
                        l.push(f);
                        l.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
                        drop(l);
                        wake();
                    }
                    ServiceEvent::ServiceFound(_, fullname) => log::info!("heard of {fullname}; asking for its address"),
                    ServiceEvent::SearchStarted(_) => {}
                    ServiceEvent::ServiceRemoved(_, fullname) => {
                        list.lock().unwrap().retain(|x| x.fullname != fullname);
                        wake();
                    }
                    _ => {}
                }
            }
        }).ok();
        Browser { found, _daemon: Some(daemon) }
    }
}

/// True when one of the addresses belongs to this computer.
fn is_this_computer<'a>(addrs: impl Iterator<Item = &'a std::net::IpAddr>) -> bool {
    let local: Vec<std::net::IpAddr> = if_addrs::get_if_addrs().map(|v| v.iter().map(|i| i.ip()).collect()).unwrap_or_default();
    for a in addrs {
        if !a.is_loopback() && local.contains(a) {
            return true;
        }
    }
    false
}

/// A host name in the form Bonjour compares: lowercase, no trailing dot, no ".local".
fn normalize_host(h: &str) -> String {
    let h = h.trim().trim_end_matches('.').to_lowercase();
    h.strip_suffix(".local").map(String::from).unwrap_or(h)
}

/// True when a service's host name (as `info.get_hostname()` gives it) is this computer's.
fn same_host(service_host: &str, mine: &str) -> bool {
    let s = normalize_host(service_host);
    !s.is_empty() && s == normalize_host(mine)
}

/// This computer's Bonjour name, normalized. Read once.
fn this_host_name() -> Option<&'static str> {
    static NAME: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
    NAME.get_or_init(|| {
        let raw = read_host_name()?;
        let n = normalize_host(&raw);
        log::info!("this computer's Bonjour name: {n}");
        (!n.is_empty()).then_some(n)
    }).as_deref()
}

#[cfg(target_os = "macos")]
fn read_host_name() -> Option<String> {
    let out = std::process::Command::new("/usr/sbin/scutil").args(["--get", "LocalHostName"]).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(windows)]
fn read_host_name() -> Option<String> {
    std::env::var("COMPUTERNAME").ok()
}

#[cfg(all(unix, not(target_os = "macos")))]
fn read_host_name() -> Option<String> {
    std::fs::read_to_string("/etc/hostname").ok()
}

#[cfg(test)]
mod tests {
    #[test]
    fn host_names() {
        use super::same_host;
        assert!(same_host("Nates-MacBook-Pro.local.", "Nates-MacBook-Pro"));
        assert!(same_host("nate-ms-7e70.local", "nate-MS-7E70\n"));
        assert!(same_host("NATE2.local.", "NATE2"));
        assert!(!same_host("Nates-Mac-mini.local.", "Nates-MacBook-Pro"));
        assert!(!same_host("", ""));
        assert!(!same_host(".local.", "local"));
        // The cached name reads without failing on this computer.
        let _ = super::this_host_name();
    }

    #[test]
    fn this_computer() {
        let mine: Vec<std::net::IpAddr> = if_addrs::get_if_addrs().unwrap().iter().map(|i| i.ip()).collect();
        assert!(super::is_this_computer(mine.iter()));
        let other: std::net::IpAddr = "203.0.113.9".parse().unwrap();
        assert!(!super::is_this_computer([other].iter()));
        // Another computer's loopback address is not this computer.
        let lo: std::net::IpAddr = "127.0.0.1".parse().unwrap();
        assert!(!super::is_this_computer([lo].iter()));
    }
}
