"""The door: TLS 1.3, both keys pinned (Sources/StreamProtocol/RemoteTLS.swift), one TCP port.

ALPN sill/1 is a session; sill-pair/1 is one pairing exchange. pyOpenSSL is used because the
standard library cannot accept an unknown self-signed client certificate and check its key itself.
Each connection runs in its own thread with a non-blocking socket, so one thread both reads and
writes its TLS object.
"""
import collections
import json
import logging
import select
import socket
import threading
import time

from OpenSSL import SSL, crypto

from . import wire
from .identity import short_name, spki_fingerprint

log = logging.getLogger("sill.net")

TCP_NOTSENT_LOWAT = 25
CHUNK = 64 * 1024
MAX_PENDING_FRAMES = 2
STALL_SECONDS = 4.0
STALL_GRACE = 8.0
SILENT_SECONDS = 20.0
TICK = 0.030


class Closed(Exception):
    pass


def _wait(sock, want_write, deadline):
    left = deadline - time.monotonic()
    if left <= 0:
        raise TimeoutError
    if want_write:
        select.select([], [sock], [], left)
    else:
        select.select([sock], [], [], left)


def _drive(sock, fn, deadline):
    while True:
        try:
            return fn()
        except SSL.WantReadError:
            _wait(sock, False, deadline)
        except SSL.WantWriteError:
            _wait(sock, True, deadline)


class Door:
    def __init__(self, identity, port, host, devices, require_pairing):
        self.identity = identity
        self.host = host                  # the coordinator: admits(), session callbacks, pairing
        self.devices = devices
        self.require_pairing = require_pairing
        self.ctx = SSL.Context(SSL.TLS_SERVER_METHOD)
        self.ctx.set_min_proto_version(SSL.TLS1_3_VERSION)
        self.ctx.set_max_proto_version(SSL.TLS1_3_VERSION)
        self.ctx.set_options(SSL.OP_NO_TICKET)
        self.ctx.set_session_cache_mode(SSL.SESS_CACHE_OFF)
        self.ctx.use_certificate(crypto.X509.from_cryptography(identity.cert))
        self.ctx.use_privatekey(crypto.PKey.from_cryptography_key(identity.key))
        self.ctx.set_verify(SSL.VERIFY_PEER | SSL.VERIFY_FAIL_IF_NO_PEER_CERT, self._verify)
        self.ctx.set_alpn_select_callback(self._alpn)
        try:
            self.sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            self.sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.sock.bind(("::", port))
        except OSError:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.sock.bind(("0.0.0.0", port))
        self.sock.listen(16)
        self.port = self.sock.getsockname()[1]
        self.pending = 0
        self.pending_lock = threading.Lock()

    # --- TLS callbacks (inside the handshake) ---------------------------------------------------
    def _alpn(self, conn, offered):
        for p in (wire.SESSION_ALPN, wire.PAIRING_ALPN):
            if p in offered:
                return p
        return SSL.NO_OVERLAPPING_PROTOCOLS

    def _verify(self, conn, cert, errno, depth, ok):
        if depth != 0:
            return True
        fp = spki_fingerprint(cert.to_cryptography().public_key())
        if fp is None:
            return False
        conn.set_app_data(fp)
        alpn = conn.get_alpn_proto_negotiated()
        if alpn == wire.PAIRING_ALPN:
            return True
        if alpn == wire.SESSION_ALPN:
            if not self.require_pairing or self.devices.is_paired(fp):
                return True
            log.info("refused an unpaired device key %s", short_name(fp))
            return False
        return False

    # --- accepting ----------------------------------------------------------------------------
    def serve_forever(self):
        threading.Thread(target=self._accept_loop, name="door", daemon=True).start()

    def _accept_loop(self):
        while True:
            try:
                s, addr = self.sock.accept()
            except OSError as e:
                log.error("accept: %s", e)
                time.sleep(0.5)
                continue
            with self.pending_lock:
                if self.pending >= 8:
                    s.close()
                    continue
                self.pending += 1
            threading.Thread(target=self._connection, args=(s, addr), name=f"conn {addr[0]}", daemon=True).start()

    def _connection(self, s, addr):
        peer = addr[0].removeprefix("::ffff:")
        admitted = False
        try:
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            for opt, val in ((getattr(socket, "TCP_KEEPIDLE", None), 5), (getattr(socket, "TCP_KEEPINTVL", None), 2),
                             (getattr(socket, "TCP_KEEPCNT", None), 3), (TCP_NOTSENT_LOWAT, 256 * 1024)):
                if opt is not None:
                    try:
                        s.setsockopt(socket.IPPROTO_TCP, opt, val)
                    except OSError:
                        pass
            s.setblocking(False)
            conn = SSL.Connection(self.ctx, s)
            conn.set_accept_state()
            try:
                _drive(s, conn.do_handshake, time.monotonic() + 10)
            except (SSL.Error, TimeoutError, OSError) as e:
                log.info("handshake with %s failed: %s", peer, e)
                return
            alpn = conn.get_alpn_proto_negotiated()
            fp = conn.get_app_data()
            if fp is None:
                return
            with self.pending_lock:
                self.pending -= 1
                admitted = True
            if alpn == wire.PAIRING_ALPN:
                self._pairing(conn, s, fp, peer)
            else:
                Session(self, conn, s, fp, peer).run()
        except Exception:
            log.exception("connection from %s", peer)
        finally:
            if not admitted:
                with self.pending_lock:
                    self.pending -= 1
            try:
                s.close()
            except OSError:
                pass

    def _pairing(self, conn, s, fp, peer):
        reader = wire.Reader(wire.MAX_PAIRING_PAYLOAD)
        deadline = time.monotonic() + 10
        req = None
        while req is None:
            try:
                data = _drive(s, lambda: conn.recv(4096), deadline)
            except (SSL.ZeroReturnError, SSL.SysCallError, TimeoutError, SSL.Error):
                return
            reader.feed(data)
            try:
                for kind, _ts, _key, payload in reader.messages():
                    if kind == wire.PAIR_REQUEST:
                        req = payload
                        break
            except ValueError:
                return
        try:
            req = json.loads(req)
        except ValueError:
            req = None
        result = self.host.pairing.handle(req, fp)
        log.info("pairing from %s (%s): %s", peer, short_name(fp), result.get("reason") or "ok")
        out = wire.jmsg(wire.PAIR_RESULT, result)
        try:
            _drive(s, lambda: conn.sendall(out), time.monotonic() + 5)
            _drive(s, conn.shutdown, time.monotonic() + 1)
        except (SSL.Error, TimeoutError, OSError):
            pass


class Session:
    """One device's session. send() may be called from any thread."""

    def __init__(self, door, conn, sock, fp, peer):
        self.door, self.conn, self.sock, self.fp, self.peer = door, conn, sock, fp, peer
        self.host = door.host
        self.name = door.devices.name(fp) or f"device {short_name(fp)}"
        self.lock = threading.Lock()
        self.out = collections.deque()
        self.pending_frames = 0
        self.waiting_key = True
        self.withheld = 0
        self.cur = None            # (bytes, offset, is_frame)
        self.chunk = None
        self.alive = True
        self.closing_after_flush = False
        self.rwake, self.wwake = socket.socketpair()
        self.rwake.setblocking(False)
        self.wwake.setblocking(False)
        self.last_sent = time.monotonic()
        self.last_progress = time.monotonic()
        self.last_heard = time.monotonic()
        self.started = time.monotonic()
        self.viewport = None
        self.fps = 60
        self.hello = None

    def __repr__(self):
        return f"{self.name} at {self.peer}"

    # --- outgoing -------------------------------------------------------------------------------
    def _wake(self):
        try:
            self.wwake.send(b"x")
        except OSError:
            pass

    def send(self, data, frame=False):
        with self.lock:
            if not self.alive:
                return
            self.out.append((data, frame))
            if frame:
                self.pending_frames += 1
        self._wake()

    def offer_au(self, params_msg, frame_msg, key):
        """A video access unit. Withholds deltas when the link is behind, then waits for a keyframe."""
        need_key = False
        with self.lock:
            if not self.alive:
                return False
            if self.waiting_key and not key:
                self.withheld += 1
                return False
            if not key and self.pending_frames >= MAX_PENDING_FRAMES:
                self.waiting_key = True
                self.withheld += 1
                need_key = True
            else:
                if key:
                    self.waiting_key = False
                    if params_msg:
                        self.out.append((params_msg, False))
                self.out.append((frame_msg, True))
                self.pending_frames += 1
        if need_key:
            return True       # the caller asks the encoder for a keyframe
        self._wake()
        return False

    def close(self, goodbye=None):
        if goodbye is not None:
            self.send(wire.jmsg(wire.GOODBYE, goodbye))
            with self.lock:
                self.closing_after_flush = True
            self._wake()
        else:
            with self.lock:
                self.alive = False
            self._wake()

    # --- the loop -------------------------------------------------------------------------------
    def run(self):
        log.info("session: %s (%s)", self, short_name(self.fp))
        self.door.devices.seen(self.fp)
        reader = wire.Reader(wire.MAX_CLIENT_PAYLOAD)
        self.host.session_started(self)
        try:
            while True:
                with self.lock:
                    alive = self.alive
                    want_write = self.cur is not None or bool(self.out)
                    flush_close = self.closing_after_flush and not want_write
                if not alive or flush_close:
                    break
                r, w, _ = select.select([self.sock, self.rwake], [self.sock] if want_write else [], [], TICK)
                if self.rwake in r:
                    try:
                        while self.rwake.recv(4096):
                            pass
                    except (BlockingIOError, OSError):
                        pass
                if self.sock in r or self.conn.pending():
                    self._read(reader)
                if want_write and (self.sock in w):
                    self._write()
                self._timers()
        except Closed:
            pass
        except Exception:
            log.exception("session %s", self)
        finally:
            with self.lock:
                self.alive = False
                self.out.clear()
            for s in (self.rwake, self.wwake):
                s.close()
            try:
                self.conn.shutdown()
            except Exception:
                pass
            self.host.session_ended(self)
            log.info("session ended: %s", self)

    def _read(self, reader):
        while True:
            try:
                data = self.conn.recv(65536)
            except SSL.WantReadError:
                return
            except SSL.WantWriteError:
                return
            except (SSL.ZeroReturnError, SSL.SysCallError, SSL.Error):
                raise Closed
            if not data:
                raise Closed
            self.last_heard = time.monotonic()
            reader.feed(data)
            try:
                for kind, ts, key, payload in reader.messages():
                    if kind == wire.PING:
                        self.send(wire.pack(wire.PONG, payload, ts=ts))
                    else:
                        try:
                            self.host.on_message(self, kind, payload)
                        except Exception:
                            log.exception("message kind %d from %s", kind, self)
            except ValueError as e:
                log.warning("%s: %s; closing", self, e)
                raise Closed
            if not self.conn.pending():
                return

    def _write(self):
        while True:
            if self.chunk is None:
                with self.lock:
                    if self.cur is None:
                        if not self.out:
                            return
                        data, is_frame = self.out.popleft()
                        self.cur = (data, 0, is_frame)
                    data, off, is_frame = self.cur
                self.chunk = data[off:off + CHUNK]
            try:
                n = self.conn.send(self.chunk)
            except SSL.WantWriteError:
                return
            except SSL.WantReadError:
                return
            except (SSL.ZeroReturnError, SSL.SysCallError, SSL.Error):
                raise Closed
            now = time.monotonic()
            self.last_sent = now
            self.last_progress = now
            with self.lock:
                data, off, is_frame = self.cur
                off += n
                if n < len(self.chunk):
                    self.chunk = self.chunk[n:]
                    self.cur = (data, off, is_frame)
                    continue
                self.chunk = None
                if off >= len(data):
                    self.cur = None
                    if is_frame:
                        self.pending_frames -= 1
                else:
                    self.cur = (data, off, is_frame)

    def _timers(self):
        now = time.monotonic()
        if now - self.last_heard > SILENT_SECONDS:
            log.info("%s: nothing heard for %.0f s", self, SILENT_SECONDS)
            raise Closed
        with self.lock:
            stuck = self.pending_frames > 0 and now - self.last_progress > STALL_SECONDS
            idle = not self.out and self.cur is None
        if stuck and now - self.started > STALL_GRACE:
            log.info("%s: link stalled for %.0f s", self, STALL_SECONDS)
            raise Closed
        if idle and now - self.last_sent >= TICK and self.host.ticking():
            self.send(wire.pack(wire.TICK))
