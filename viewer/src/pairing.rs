//! Pairing (Sources/StreamProtocol/Pairing.swift): ask the host to show its code, then prove the
//! code (or a QR link's secret), bound to both TLS keys; check the host's proof back.

use crate::identity::{b64u, b64u_decode, mac_id, Identity, SavedHost};
use crate::tls;
use crate::wire;
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
use std::time::Duration;

const DAMM: [[u8; 10]; 10] = [
    [0, 3, 1, 7, 5, 9, 8, 6, 4, 2], [7, 0, 9, 2, 1, 5, 4, 8, 6, 3], [4, 2, 0, 6, 8, 7, 1, 3, 5, 9],
    [1, 7, 5, 0, 9, 8, 3, 4, 2, 6], [6, 1, 2, 3, 0, 4, 5, 9, 7, 8], [3, 6, 7, 4, 2, 0, 9, 5, 8, 1],
    [5, 8, 6, 9, 7, 2, 0, 1, 3, 4], [8, 9, 4, 5, 3, 6, 2, 0, 1, 7], [9, 4, 3, 8, 6, 1, 7, 2, 0, 5],
    [2, 5, 8, 1, 4, 3, 6, 7, 9, 0],
];

/// The 12 digits of a typed code, or why it is not one.
pub fn check_code(input: &str) -> Result<String, String> {
    let digits: String = input.chars().filter(|c| !c.is_whitespace() && *c != '-').collect();
    if digits.len() != 12 || !digits.chars().all(|c| c.is_ascii_digit()) {
        return Err("A code has 12 digits.".into());
    }
    let check = digits.bytes().fold(0u8, |i, d| DAMM[i as usize][(d - b'0') as usize]);
    if check != 0 {
        return Err("That code has a typo. Check it against the computer.".into());
    }
    Ok(digits)
}

fn hmac(key: &[u8], parts: &[&[u8]]) -> Vec<u8> {
    let mut m = <Hmac<Sha256> as Mac>::new_from_slice(key).unwrap();
    for p in parts {
        m.update(p);
    }
    m.finalize().into_bytes().to_vec()
}

fn request(addr: &str, id: &Identity, pin: Option<[u8; 32]>, req: Value) -> Result<(Value, [u8; 32]), String> {
    let conn = tls::connect(addr, wire::PAIRING_ALPN, pin, id)?;
    conn.send(&wire::json(wire::PAIR_REQUEST, &req)).map_err(|e| e.to_string())?;
    let m = conn.read_one(Duration::from_secs(20))?;
    conn.shutdown();
    if m.kind != wire::PAIR_RESULT {
        return Err(format!("unexpected reply (kind {})", m.kind));
    }
    let v: Value = serde_json::from_slice(&m.payload).map_err(|e| e.to_string())?;
    Ok((v, conn.peer_fp))
}

fn device_name() -> String {
    let host = std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .ok()
        .or_else(|| std::fs::read_to_string("/etc/hostname").ok().map(|s| s.trim().to_string()))
        .unwrap_or_default();
    if host.is_empty() { format!("Sill Viewer ({})", crate::os_name()) } else { host }
}

/// "Show your code": the host opens its pairing window. Returns the host's reason ("shown",
/// "openOnMac", ...) and the key it answered with, which the code step then pins.
pub fn ask(addr: &str, id: &Identity) -> Result<(String, [u8; 32]), String> {
    let (r, fp) = request(addr, id, None, json!({"v": 1, "method": "ask", "proof": "", "name": device_name(),
                                                  "model": "Sill Viewer"}))?;
    Ok((r["reason"].as_str().unwrap_or(if r["ok"] == true { "ok" } else { "closed" }).to_string(), fp))
}

/// The typed code. `pin` is the key the ask saw (None: any, the proofs bind both keys anyway).
pub fn pair_with_code(addr: &str, id: &Identity, code: &str, pin: Option<[u8; 32]>) -> Result<SavedHost, String> {
    let code = check_code(code)?;
    // The salt needs the host's key, which only the TLS session shows: connect, then derive.
    let conn = tls::connect(addr, wire::PAIRING_ALPN, pin, id)?;
    let fp_mac = conn.peer_fp;
    let mut key = [0u8; 32];
    let mut salt = b"sill-pair-v1".to_vec();
    salt.extend_from_slice(&fp_mac);
    pbkdf2::pbkdf2_hmac::<Sha256>(code.as_bytes(), &salt, 600_000, &mut key);
    let proof = hmac(&key, &[b"sill-pair-v1 device\0", &id.fingerprint, &fp_mac]);
    let req = json!({"v": 1, "method": "code", "proof": b64u(&proof), "name": device_name(), "model": "Sill Viewer"});
    conn.send(&wire::json(wire::PAIR_REQUEST, &req)).map_err(|e| e.to_string())?;
    let m = conn.read_one(Duration::from_secs(20))?;
    conn.shutdown();
    let r: Value = serde_json::from_slice(&m.payload).map_err(|e| e.to_string())?;
    if r["ok"] != true {
        return Err(match r["reason"].as_str().unwrap_or("") {
            "code" => format!("Wrong code. {} tries left.", r["triesLeft"].as_i64().unwrap_or(0)),
            "expired" => "The code expired. Ask for a new one.".into(),
            "closed" => "The computer shows no code now. Ask again.".into(),
            "busy" => "The computer is busy. Try again in a moment.".into(),
            other => r["message"].as_str().map(String::from).unwrap_or_else(|| format!("Refused: {other}")),
        });
    }
    let want = hmac(&key, &[b"sill-pair-v1 mac\0", &fp_mac, &id.fingerprint]);
    let got = r["proof"].as_str().and_then(b64u_decode).unwrap_or_default();
    if got != want {
        return Err("The computer's proof does not check: someone may be in the middle.".into());
    }
    if r["macID"].as_str() != Some(&mac_id(&fp_mac)) {
        return Err("The computer's ID does not match its key.".into());
    }
    Ok(SavedHost {
        mac_id: mac_id(&fp_mac),
        name: r["name"].as_str().unwrap_or("Computer").to_string(),
        fingerprint: b64u(&fp_mac),
        recognition_key: r["recognitionKey"].as_str().map(String::from),
        last_address: Some(addr.to_string()),
    })
}
