"""This computer's identity and the devices paired with it.

Trust is the key itself (Sources/StreamProtocol/RemoteIdentity.swift): one P-256 key per install,
pinned by the SHA-256 of its SubjectPublicKeyInfo. The certificate around it is rebuilt at every
launch and means nothing else.
"""
import base64
import datetime
import hashlib
import hmac
import json
import os
import secrets
import threading
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def data_dir():
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    d = os.path.join(base, "sill-linux")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    d = os.path.join(base, "sill-linux")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def b64u(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def b64u_decode(t):
    if not t or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" for c in t):
        raise ValueError("not base64url")
    return base64.urlsafe_b64decode(t + "=" * (-len(t) % 4))


def mac_id(fp):
    n = int.from_bytes(fp[:10], "big")
    return "".join(CROCKFORD[(n >> (75 - 5 * i)) & 31] for i in range(16))


def short_name(fp):
    return mac_id(fp)[:6]


def spki_fingerprint(public_key):
    """SHA-256 of the SPKI DER, or None for a key that is not P-256."""
    if not isinstance(public_key, ec.EllipticCurvePublicKey) or not isinstance(public_key.curve, ec.SECP256R1):
        return None
    der = public_key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return hashlib.sha256(der).digest()


def _write_private(path, data):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


class Identity:
    def __init__(self, directory=None):
        self.dir = directory or data_dir()
        key_path = os.path.join(self.dir, "identity.pem")
        if os.path.exists(key_path):
            with open(key_path, "rb") as f:
                self.key = serialization.load_pem_private_key(f.read(), password=None)
        else:
            self.key = ec.generate_private_key(ec.SECP256R1())
            _write_private(key_path, self.key.private_bytes(serialization.Encoding.PEM,
                                                            serialization.PrivateFormat.PKCS8,
                                                            serialization.NoEncryption()))
        rk_path = os.path.join(self.dir, "recognition.key")
        if os.path.exists(rk_path):
            with open(rk_path, "rb") as f:
                self.recognition_key = f.read()
        if not os.path.exists(rk_path) or len(self.recognition_key) != 32:
            self.recognition_key = secrets.token_bytes(32)
            _write_private(rk_path, self.recognition_key)
        self.fingerprint = spki_fingerprint(self.key.public_key())
        self.mac_id = mac_id(self.fingerprint)
        self.cert = self._certificate()

    def _certificate(self):
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, secrets.token_hex(8))])
        serial = int.from_bytes(secrets.token_bytes(16), "big") >> 1 | 1
        return (x509.CertificateBuilder()
                .subject_name(name).issuer_name(name)
                .public_key(self.key.public_key())
                .serial_number(serial)
                .not_valid_before(datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc))
                .not_valid_after(datetime.datetime(9999, 12, 31, 23, 59, 59, tzinfo=datetime.timezone.utc))
                .sign(self.key, hashes.SHA256()))

    def recognition_tag(self):
        """The Bonjour TXT `r` (Pairing.swift RecognitionTag): nonce(6) + HMAC(...)[:6], base64url."""
        nonce = secrets.token_bytes(6)
        mac = hmac.new(self.recognition_key, b"sill-tag-v1" + nonce, hashlib.sha256).digest()[:6]
        return b64u(nonce + mac)


class Devices:
    """Paired devices, keyed by the base64url fingerprint of their key."""

    def __init__(self, directory=None):
        self.path = os.path.join(directory or data_dir(), "devices.json")
        self.lock = threading.Lock()
        self.devices = {}
        if os.path.exists(self.path):
            try:
                with open(self.path) as f:
                    self.devices = json.load(f)
            except (OSError, ValueError):
                self.devices = {}

    def _save(self):
        _write_private(self.path, json.dumps(self.devices, indent=1).encode())

    def is_paired(self, fp):
        with self.lock:
            return b64u(fp) in self.devices

    def add(self, fp, name, model):
        with self.lock:
            self.devices[b64u(fp)] = {"name": name, "model": model, "paired": time.time(), "lastSeen": None}
            self._save()

    def seen(self, fp):
        with self.lock:
            d = self.devices.get(b64u(fp))
            if d is not None:
                d["lastSeen"] = time.time()
                self._save()

    def name(self, fp):
        with self.lock:
            d = self.devices.get(b64u(fp))
            return d["name"] if d else None

    def listing(self):
        with self.lock:
            return dict(self.devices)

    def remove(self, key_or_name):
        with self.lock:
            hits = [k for k, d in self.devices.items() if k == key_or_name or k.startswith(key_or_name)
                    or d.get("name") == key_or_name]
            for k in hits:
                del self.devices[k]
            if hits:
                self._save()
            return hits
