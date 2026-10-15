//! TLS 1.3 to a Sill host (Sources/StreamProtocol/RemoteTLS.swift): this viewer's self-signed
//! P-256 certificate, the host's key pinned (or any P-256 key when there is no pin yet), one ALPN,
//! SNI "sill", no resumption. The handshake signature is still checked against the presented key.

use crate::identity::{cert_fingerprint, Identity};
use crate::wire::{self, Message, Reader};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, SignatureScheme};
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug)]
struct PinVerifier {
    pin: Option<[u8; 32]>,
    seen: Arc<Mutex<Option<[u8; 32]>>>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(&self, end_entity: &CertificateDer<'_>, _i: &[CertificateDer<'_>], _n: &ServerName<'_>,
                          _o: &[u8], _t: UnixTime) -> Result<ServerCertVerified, rustls::Error> {
        let fp = cert_fingerprint(end_entity.as_ref())
            .ok_or_else(|| rustls::Error::General("the host's key is not P-256".into()))?;
        if let Some(pin) = self.pin {
            if pin != fp {
                return Err(rustls::Error::General("PIN".into()));
            }
        }
        *self.seen.lock().unwrap() = Some(fp);
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(&self, _m: &[u8], _c: &CertificateDer<'_>, _d: &DigitallySignedStruct)
                              -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.2 is not Sill".into()))
    }

    fn verify_tls13_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct)
                              -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

pub struct TlsConn {
    sock: TcpStream,
    conn: Mutex<ClientConnection>,
    pub peer_fp: [u8; 32],
    pub peer_addr: String,
}

/// Why a connection failed, in words for the user.
fn explain(e: &rustls::Error) -> String {
    use rustls::AlertDescription as A;
    match e {
        rustls::Error::General(s) if s == "PIN" => "this is not the computer you paired with (its key changed)".into(),
        rustls::Error::AlertReceived(A::BadCertificate | A::CertificateUnknown | A::AccessDenied | A::UnknownCA
                                     | A::CertificateRequired | A::DecryptError) =>
            "the computer does not accept this viewer: pair again".into(),
        rustls::Error::AlertReceived(A::NoApplicationProtocol) => "the host does not speak Sill".into(),
        other => format!("TLS: {other}"),
    }
}

pub fn connect(addr: &str, alpn: &[u8], pin: Option<[u8; 32]>, id: &Identity) -> Result<TlsConn, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let seen = Arc::new(Mutex::new(None));
    let verifier = PinVerifier { pin, seen: seen.clone(), provider: provider.clone() };
    let mut cfg = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|e| e.to_string())?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_client_auth_cert(vec![CertificateDer::from(id.cert_der.clone())],
                               PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(id.key_der.clone())))
        .map_err(|e| e.to_string())?;
    cfg.alpn_protocols = vec![alpn.to_vec()];
    cfg.resumption = rustls::client::Resumption::disabled();

    let addrs: Vec<_> = addr.to_socket_addrs().map_err(|e| format!("{addr}: {e}"))?.collect();
    let mut last = format!("{addr}: no address");
    let mut sock = None;
    for a in addrs {
        match TcpStream::connect_timeout(&a, Duration::from_secs(5)) {
            Ok(s) => {
                sock = Some(s);
                break;
            }
            Err(e) => last = format!("{a}: {e}"),
        }
    }
    let mut sock = sock.ok_or(last)?;
    let _ = sock.set_nodelay(true);
    sock.set_read_timeout(Some(Duration::from_secs(10))).ok();
    let mut conn = ClientConnection::new(Arc::new(cfg), ServerName::try_from("sill").unwrap())
        .map_err(|e| e.to_string())?;
    while conn.is_handshaking() {
        if let Err(e) = conn.complete_io(&mut sock) {
            if let Some(te) = e.get_ref().and_then(|x| x.downcast_ref::<rustls::Error>()) {
                return Err(explain(te));
            }
            return Err(format!("handshake: {e}"));
        }
    }
    sock.set_read_timeout(None).ok();
    if conn.alpn_protocol() != Some(alpn) {
        return Err("the host does not speak Sill".into());
    }
    let peer_fp = seen.lock().unwrap().ok_or("no host key")?;
    let peer_addr = sock.peer_addr().map(|a| a.to_string()).unwrap_or_default();
    Ok(TlsConn { sock, conn: Mutex::new(conn), peer_fp, peer_addr })
}

impl TlsConn {
    pub fn send(&self, data: &[u8]) -> std::io::Result<()> {
        let mut c = self.conn.lock().unwrap();
        let mut s = &self.sock;
        // rustls takes a limited amount of plaintext at a time: write, flush, repeat.
        let mut rest = data;
        while !rest.is_empty() {
            let n = c.writer().write(rest)?;
            rest = &rest[n..];
            let flushed = c.wants_write();
            while c.wants_write() {
                c.write_tls(&mut s)?;
            }
            if n == 0 && !flushed {
                return Err(std::io::Error::new(std::io::ErrorKind::WriteZero, "TLS would not take the data"));
            }
        }
        while c.wants_write() {
            c.write_tls(&mut s)?;
        }
        Ok(())
    }

    pub fn shutdown(&self) {
        {
            let mut c = self.conn.lock().unwrap();
            c.send_close_notify();
            let mut s = &self.sock;
            while c.wants_write() {
                if c.write_tls(&mut s).is_err() {
                    break;
                }
            }
        }
        let _ = self.sock.shutdown(std::net::Shutdown::Both);
    }

    /// Reads until the connection ends, calling `on_msg` for each message; returns why it ended.
    pub fn read_loop(&self, mut on_msg: impl FnMut(Message) -> bool) -> String {
        let mut sock = match self.sock.try_clone() {
            Ok(s) => s,
            Err(e) => return e.to_string(),
        };
        let mut raw = vec![0u8; 256 * 1024];
        let mut plain = vec![0u8; 256 * 1024];
        let mut reader = Reader::default();
        loop {
            let n = match sock.read(&mut raw) {
                Ok(0) => return "the host closed the connection".into(),
                Ok(n) => n,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return format!("connection lost: {e}"),
            };
            let mut closed = false;
            {
                let mut c = self.conn.lock().unwrap();
                let mut slice = &raw[..n];
                while !slice.is_empty() {
                    if let Err(e) = c.read_tls(&mut slice) {
                        return format!("TLS read: {e}");
                    }
                    if let Err(e) = c.process_new_packets() {
                        return explain(&e);
                    }
                    loop {
                        match c.reader().read(&mut plain) {
                            Ok(0) => {
                                closed = true;
                                break;
                            }
                            Ok(k) => reader.feed(&plain[..k]),
                            Err(e) if e.kind() == ErrorKind::WouldBlock => break,
                            Err(e) => return format!("TLS: {e}"),
                        }
                    }
                }
                let mut s = &self.sock;
                while c.wants_write() {
                    if c.write_tls(&mut s).is_err() {
                        break;
                    }
                }
            }
            loop {
                match reader.next() {
                    Ok(Some(m)) => {
                        if !on_msg(m) {
                            return "closed".into();
                        }
                    }
                    Ok(None) => break,
                    Err(e) => return e,
                }
            }
            if closed {
                return "the host closed the connection".into();
            }
        }
    }

    /// One message, for the pairing exchange.
    pub fn read_one(&self, timeout: Duration) -> Result<Message, String> {
        self.sock.set_read_timeout(Some(timeout)).ok();
        let mut got = None;
        let why = self.read_loop(|m| {
            got = Some(m);
            false
        });
        got.ok_or(why)
    }
}

pub fn ping_payload(secs: f64) -> Vec<u8> {
    wire::pack(wire::PING, &secs.to_bits().to_be_bytes(), false, None)
}
