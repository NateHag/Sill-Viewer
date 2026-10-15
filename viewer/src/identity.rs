//! This viewer's key and the hosts it paired with. Trust is the key, pinned as the SHA-256 of its
//! SubjectPublicKeyInfo (Sources/StreamProtocol/RemoteIdentity.swift).

use base64::Engine;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::PathBuf;

const CROCKFORD: &[u8] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
/// The SPKI of a P-256 key, up to the 65-byte point.
const P256_SPKI_PREFIX: [u8; 26] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
];

pub fn b64u(b: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b)
}

pub fn b64u_decode(t: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(t).ok()
}

pub fn mac_id(fp: &[u8]) -> String {
    let mut n: u128 = 0;
    for b in &fp[..10] {
        n = (n << 8) | *b as u128;
    }
    (0..16).map(|i| CROCKFORD[((n >> (75 - 5 * i)) & 31) as usize] as char).collect()
}

/// SHA-256 of a certificate's SPKI when its key is P-256, else None.
pub fn cert_fingerprint(der: &[u8]) -> Option<[u8; 32]> {
    let (_, cert) = x509_parser::parse_x509_certificate(der).ok()?;
    let spki = cert.tbs_certificate.subject_pki.raw;
    if spki.len() != 91 || spki[..26] != P256_SPKI_PREFIX {
        return None;
    }
    Some(Sha256::digest(spki).into())
}

pub fn config_dir() -> PathBuf {
    let d = dirs::config_dir().unwrap_or_else(|| PathBuf::from(".")).join("sill-viewer");
    let _ = std::fs::create_dir_all(&d);
    d
}

pub struct Identity {
    pub cert_der: Vec<u8>,
    pub key_der: Vec<u8>,
    pub fingerprint: [u8; 32],
}

impl Identity {
    pub fn load_or_create() -> Result<Identity, String> {
        let path = config_dir().join("identity.pem");
        let key = match std::fs::read_to_string(&path) {
            Ok(pem) => rcgen::KeyPair::from_pem(&pem).map_err(|e| e.to_string())?,
            Err(_) => {
                let k = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256).map_err(|e| e.to_string())?;
                write_private(&path, k.serialize_pem().as_bytes()).map_err(|e| e.to_string())?;
                k
            }
        };
        let mut params = rcgen::CertificateParams::new(Vec::<String>::new()).map_err(|e| e.to_string())?;
        let mut cn = [0u8; 8];
        rand::Rng::fill(&mut rand::thread_rng(), &mut cn[..]);
        params.distinguished_name = rcgen::DistinguishedName::new();
        params.distinguished_name.push(rcgen::DnType::CommonName, hex(&cn));
        params.not_before = rcgen::date_time_ymd(2026, 1, 1);
        params.not_after = rcgen::date_time_ymd(9999, 12, 31);
        let cert = params.self_signed(&key).map_err(|e| e.to_string())?;
        let cert_der = cert.der().to_vec();
        let fingerprint = cert_fingerprint(&cert_der).ok_or("own certificate is not P-256")?;
        Ok(Identity { cert_der, key_der: key.serialize_der(), fingerprint })
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn write_private(path: &PathBuf, data: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, data)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

/// A host this viewer paired with.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct SavedHost {
    #[serde(rename = "macID")]
    pub mac_id: String,
    pub name: String,
    pub fingerprint: String,
    #[serde(rename = "recognitionKey")]
    pub recognition_key: Option<String>,
    #[serde(rename = "lastAddress")]
    pub last_address: Option<String>,
}

impl SavedHost {
    pub fn fp(&self) -> Option<[u8; 32]> {
        b64u_decode(&self.fingerprint).and_then(|v| v.try_into().ok())
    }

    /// Whether a Bonjour TXT `r` tag was made with this host's recognition key.
    pub fn matches_tag(&self, tag: &str) -> bool {
        let (Some(key), Some(bytes)) = (self.recognition_key.as_deref().and_then(b64u_decode), b64u_decode(tag)) else {
            return false;
        };
        if bytes.len() != 12 {
            return false;
        }
        let mut m = <Hmac<Sha256> as Mac>::new_from_slice(&key).unwrap();
        m.update(b"sill-tag-v1");
        m.update(&bytes[..6]);
        let out = m.finalize().into_bytes();
        out[..6] == bytes[6..]
    }
}

pub fn load_hosts() -> Vec<SavedHost> {
    std::fs::read(config_dir().join("hosts.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub fn save_hosts(hosts: &[SavedHost]) {
    if let Ok(b) = serde_json::to_vec_pretty(hosts) {
        let _ = write_private(&config_dir().join("hosts.json"), &b);
    }
}
