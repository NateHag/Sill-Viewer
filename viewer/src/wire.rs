//! Sill's wire format (Sources/StreamProtocol/StreamMessage.swift): a 14-byte big-endian header,
//! kind(1) timestamp(8, f64) isKeyframe(1) length(4), then the payload.

pub const HEADER_LEN: usize = 14;

pub const PARAMETER_SETS: u8 = 0;
pub const FRAME: u8 = 1;
pub const WINDOW_LIST: u8 = 2;
pub const SELECT_SOURCE: u8 = 6;
pub const INPUT: u8 = 8;
pub const VIEWPORT: u8 = 9;
pub const PING: u8 = 10;
pub const PONG: u8 = 11;
pub const CLIENT_STATS: u8 = 12;
pub const CURSOR_SHAPE: u8 = 14;
pub const HOST_SETTINGS: u8 = 16;
pub const CHANGE_SETTINGS: u8 = 17;
pub const PAIR_REQUEST: u8 = 19;
pub const PAIR_RESULT: u8 = 20;
pub const GOODBYE: u8 = 22;
pub const HELLO: u8 = 23;
/// Not Sill's: sill-linux and Sill Viewer only. JSON {"text": "..."} both ways: the clipboard
/// changed on this side. Sill's own apps skip kinds they do not know.
pub const CLIPBOARD: u8 = 200;
/// Sill's own clipboard (Mac hosts, and sill-linux): JSON {"text"}, or {} to subscribe, or
/// {"stop": true}. Only to a host whose window list says "clipboard" 1 or more. Text at most 256 KB.
pub const SILL_CLIPBOARD: u8 = 32;
pub const SILL_CLIPBOARD_TEXT: usize = 256 * 1024;
pub const MAX_CLIPBOARD_TEXT: usize = 900_000;
/// Not Sill's either: files both ways (see sill-linux's wire.py for the shapes).
pub const FILE_START: u8 = 201;
pub const FILE_DATA: u8 = 202;
pub const FILE_END: u8 = 203;
pub const FILE_REQUEST: u8 = 204;
pub const FILE_STATUS: u8 = 205;
pub const FILE_CANCEL: u8 = 206;
pub const FILE_CHUNK: usize = 128 * 1024;

pub const MAX_FRAME_PAYLOAD: usize = 32 << 20;
pub const MAX_OTHER_PAYLOAD: usize = 4 << 20;

pub const SESSION_ALPN: &[u8] = b"sill/1";
pub const PAIRING_ALPN: &[u8] = b"sill-pair/1";

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub fn pack(kind: u8, payload: &[u8], key: bool, ts: Option<f64>) -> Vec<u8> {
    let mut v = Vec::with_capacity(HEADER_LEN + payload.len());
    v.push(kind);
    v.extend_from_slice(&ts.unwrap_or_else(now).to_bits().to_be_bytes());
    v.push(key as u8);
    v.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    v.extend_from_slice(payload);
    v
}

pub fn json(kind: u8, value: &serde_json::Value) -> Vec<u8> {
    pack(kind, &serde_json::to_vec(value).unwrap_or_default(), false, None)
}

pub struct Message {
    pub kind: u8,
    pub ts: f64,
    pub key: bool,
    pub payload: Vec<u8>,
}

/// Incremental parser: feed bytes, take whole messages.
#[derive(Default)]
pub struct Reader {
    buf: Vec<u8>,
    start: usize,
}

impl Reader {
    pub fn feed(&mut self, data: &[u8]) {
        if self.start > 0 && self.start == self.buf.len() {
            self.buf.clear();
            self.start = 0;
        }
        self.buf.extend_from_slice(data);
    }

    pub fn next(&mut self) -> Result<Option<Message>, String> {
        let avail = &self.buf[self.start..];
        if avail.len() < HEADER_LEN {
            self.compact();
            return Ok(None);
        }
        let kind = avail[0];
        let ts = f64::from_bits(u64::from_be_bytes(avail[1..9].try_into().unwrap()));
        let key = avail[9] == 1;
        let len = u32::from_be_bytes(avail[10..14].try_into().unwrap()) as usize;
        let max = if kind == FRAME { MAX_FRAME_PAYLOAD } else { MAX_OTHER_PAYLOAD };
        if len > max {
            return Err(format!("the host announced {len} bytes for kind {kind}: not Sill"));
        }
        if avail.len() < HEADER_LEN + len {
            self.compact();
            return Ok(None);
        }
        let payload = avail[HEADER_LEN..HEADER_LEN + len].to_vec();
        self.start += HEADER_LEN + len;
        Ok(Some(Message { kind, ts, key, payload }))
    }

    fn compact(&mut self) {
        if self.start > 1 << 20 {
            self.buf.drain(..self.start);
            self.start = 0;
        }
    }
}

/// Kind 0's payload: nalLen(1) count(1) then per set len(2) bytes.
pub fn parse_parameter_sets(p: &[u8]) -> Option<(usize, Vec<Vec<u8>>)> {
    if p.len() < 2 {
        return None;
    }
    let nal_len = p[0] as usize;
    let count = p[1] as usize;
    let mut off = 2;
    let mut sets = Vec::with_capacity(count);
    for _ in 0..count {
        if p.len() < off + 2 {
            return None;
        }
        let n = u16::from_be_bytes([p[off], p[off + 1]]) as usize;
        off += 2;
        if p.len() < off + n {
            return None;
        }
        sets.push(p[off..off + n].to_vec());
        off += n;
    }
    Some((nal_len, sets))
}

/// An access unit of length-prefixed NAL units (hvcC style) as Annex B, for the decoder.
pub fn to_annexb(params: Option<&[Vec<u8>]>, au: &[u8], nal_len: usize, out: &mut Vec<u8>) {
    out.clear();
    if let Some(ps) = params {
        for s in ps {
            out.extend_from_slice(&[0, 0, 0, 1]);
            out.extend_from_slice(s);
        }
    }
    let mut i = 0;
    while i + nal_len <= au.len() {
        let mut n = 0usize;
        for b in &au[i..i + nal_len] {
            n = (n << 8) | *b as usize;
        }
        i += nal_len;
        if i + n > au.len() {
            break;
        }
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(&au[i..i + n]);
        i += n;
    }
}
