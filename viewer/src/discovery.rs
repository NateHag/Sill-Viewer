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
        a.sort_by_key(|ip| !ip.is_ipv4());
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
                        // A host on this same computer (a Mac running Sill): never offer it.
                        if is_this_computer(info.get_addresses().iter()) {
                            log::info!("not listing {fullname}: it is this computer");
                            continue;
                        }
                        let name = fullname.strip_suffix("._sill._tcp.local.").unwrap_or(&fullname).replace("\\032", " ");
                        let f = Found {
                            name,
                            addresses: info.get_addresses().iter().copied().collect(),
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
        if a.is_loopback() || local.contains(a) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    #[test]
    fn this_computer() {
        let mine: Vec<std::net::IpAddr> = if_addrs::get_if_addrs().unwrap().iter().map(|i| i.ip()).collect();
        assert!(super::is_this_computer(mine.iter()));
        let other: std::net::IpAddr = "203.0.113.9".parse().unwrap();
        assert!(!super::is_this_computer([other].iter()));
    }
}
