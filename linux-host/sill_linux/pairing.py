"""Pairing (Sources/StreamProtocol/Pairing.swift, docs/home-pairing-plan.md).

A device that has not paired asks ("ask"); this computer opens a pairing window with a 12-digit
code and shows it; the device sends a proof made from the code ("code") or from a QR link's secret
("qr"); both sides check the other's proof, bound to both TLS keys.
"""
import hashlib
import hmac
import logging
import os
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse

from .identity import b64u, b64u_decode, mac_id

log = logging.getLogger("sill.pair")

DAMM = [[0, 3, 1, 7, 5, 9, 8, 6, 4, 2], [7, 0, 9, 2, 1, 5, 4, 8, 6, 3], [4, 2, 0, 6, 8, 7, 1, 3, 5, 9],
        [1, 7, 5, 0, 9, 8, 3, 4, 2, 6], [6, 1, 2, 3, 0, 4, 5, 9, 7, 8], [3, 6, 7, 4, 2, 0, 9, 5, 8, 1],
        [5, 8, 6, 9, 7, 2, 0, 1, 3, 4], [8, 9, 4, 5, 3, 6, 2, 0, 1, 7], [9, 4, 3, 8, 6, 1, 7, 2, 0, 5],
        [2, 5, 8, 1, 4, 3, 6, 7, 9, 0]]

WINDOW_SECONDS = 300
TRIES = 5
QUIET_AFTER_FAILS = 600
ASK_WINDOWS_PER_10_MIN = 3
ROUNDS = 600_000


def damm(digits):
    i = 0
    for d in digits:
        i = DAMM[i][int(d)]
    return i


def new_code():
    digits = []
    while len(digits) < 11:
        b = secrets.randbelow(256)
        if b < 250:
            digits.append(b % 10)
    digits.append(damm(digits))
    return "".join(map(str, digits))


def grouped(code):
    return " ".join(code[i:i + 4] for i in range(0, len(code), 4))


def code_key(code, fp_mac):
    return hashlib.pbkdf2_hmac("sha256", code.encode(), b"sill-pair-v1" + fp_mac, ROUNDS, 32)


def device_proof(key, fp_dev, fp_mac):
    return hmac.new(key, b"sill-pair-v1 device\x00" + fp_dev + fp_mac, hashlib.sha256).digest()


def mac_proof(key, fp_mac, fp_dev):
    return hmac.new(key, b"sill-pair-v1 mac\x00" + fp_mac + fp_dev, hashlib.sha256).digest()


def notify(title, body):
    if shutil.which("notify-send"):
        try:
            subprocess.Popen(["notify-send", "-u", "critical", "-a", "Sill", "-i", "video-display", title, body],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass


class Window:
    def __init__(self, by_ask):
        self.code = new_code()
        self.secret = secrets.token_bytes(16)
        self.opened = time.monotonic()
        self.tries = TRIES
        self.by_ask = by_ask

    def expired(self):
        return time.monotonic() - self.opened > WINDOW_SECONDS


class Pairing:
    def __init__(self, identity, devices, name, port, addresses_fn, on_change=None):
        self.identity = identity
        self.devices = devices
        self.name = name
        self.port = port
        self.addresses_fn = addresses_fn
        self.on_change = on_change
        self.lock = threading.Lock()
        self.window = None
        self.ask_windows = []          # monotonic times of windows an ask opened
        self.quiet_until = 0.0
        self.qr_proc = None

    # --- the window -------------------------------------------------------------------------
    def open_window(self, by_ask=False):
        with self.lock:
            if self.window is None or self.window.expired():
                self.window = Window(by_ask)
                log.info("pairing window open for 5 minutes: code %s", grouped(self.window.code))
            w = self.window
        self._show_qr(w)
        notify(f"Pair a device with {self.name}", f"Code: {grouped(w.code)}\nScan the QR code, or choose Enter Code Instead.")
        return w

    def _show_qr(self, w):
        """The pairing window on screen, as the Mac shows one: QR code and code."""
        p = self.qr_proc
        if p is not None and p.poll() is None and getattr(p, "sill_window", None) is w:
            return
        self._hide_qr()
        if not shutil.which("qrencode"):
            return
        try:
            env = dict(os.environ, PYTHONPATH=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
            p = subprocess.Popen([sys.executable, "-m", "sill_linux.qrwindow", self.link(w), grouped(w.code), self.name],
                                 env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            p.sill_window = w
            self.qr_proc = p
        except OSError as e:
            log.warning("cannot show the QR window: %s", e)

    def _hide_qr(self):
        p, self.qr_proc = self.qr_proc, None
        if p is not None and p.poll() is None:
            p.terminate()

    def link(self, w):
        items = [("v", "1"), ("m", self.identity.mac_id), ("k", b64u(self.identity.fingerprint)),
                 ("s", b64u(w.secret)), ("n", self.name), ("p", str(self.port))]
        items += [("a", a) for a in self.addresses_fn()[:5]]
        esc = lambda s: urllib.parse.quote(s, safe="-._~:")
        return "sill://pair?" + "&".join(f"{k}={esc(v)}" for k, v in items)

    def close_window(self):
        with self.lock:
            self.window = None
        self._hide_qr()

    # --- kind 19 -> kind 20 ------------------------------------------------------------------
    def handle(self, req, fp_dev):
        if not isinstance(req, dict) or req.get("v") != 1:
            return {"ok": False, "reason": "closed"}
        method = req.get("method")
        name = str(req.get("name") or "Device")[:64]
        model = req.get("model")
        if method == "cancel":
            with self.lock:
                if self.window is not None and self.window.by_ask:
                    self.window = None
                    self._hide_qr()
            return {"ok": False, "reason": "closed"}
        if method == "ask":
            now = time.monotonic()
            with self.lock:
                if now < self.quiet_until:
                    return {"ok": False, "reason": "openOnMac"}
                open_now = self.window is not None and not self.window.expired()
                self.ask_windows = [t for t in self.ask_windows if now - t < 600]
                if not open_now and len(self.ask_windows) >= ASK_WINDOWS_PER_10_MIN:
                    return {"ok": False, "reason": "openOnMac"}
                if not open_now:
                    self.ask_windows.append(now)
            log.info("%s asks to pair", name)
            self.open_window(by_ask=True)
            return {"ok": False, "reason": "shown"}
        if method not in ("code", "qr"):
            return {"ok": False, "reason": "closed"}
        with self.lock:
            w = self.window
            if w is None:
                return {"ok": False, "reason": "closed"}
            if w.expired():
                self.window = None
                return {"ok": False, "reason": "expired"}
        try:
            proof = b64u_decode(req.get("proof") or "")
        except ValueError:
            proof = b""
        fp_mac = self.identity.fingerprint
        key = code_key(w.code, fp_mac) if method == "code" else w.secret
        if not hmac.compare_digest(device_proof(key, fp_dev, fp_mac), proof):
            with self.lock:
                if self.window is not w:
                    return {"ok": False, "reason": "closed"}
                w.tries -= 1
                left = w.tries
                if left <= 0:
                    self.window = None
                    self._hide_qr()
                    self.quiet_until = time.monotonic() + QUIET_AFTER_FAILS
            log.warning("wrong pairing proof from %s (%d tries left)", name, max(left, 0))
            return {"ok": False, "reason": "code", "triesLeft": max(left, 0)}
        with self.lock:
            if self.window is w:
                self.window = None
        self._hide_qr()
        self.devices.add(fp_dev, name, model)
        log.info("paired with %s (%s)", name, mac_id(fp_dev)[:6])
        notify("Device paired", f"{name} can now connect to {self.name}.")
        if self.on_change:
            self.on_change()
        return {"ok": True, "proof": b64u(mac_proof(key, fp_mac, fp_dev)), "macID": self.identity.mac_id,
                "name": self.name, "recognitionKey": b64u(self.identity.recognition_key)}
