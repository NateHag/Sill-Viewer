"""Files both ways between a viewer and this computer.

From the viewer: dropped files arrive as FILE_START / FILE_DATA / FILE_END and are saved in the
Downloads folder (a ".part" file until the end, so a broken transfer never looks complete).
To the viewer: on FILE_REQUEST, the files copied here (Ctrl+C in Files) are sent the same way.
"""
import json
import logging
import os
import struct
import threading

from gi.repository import GLib

from . import wire

log = logging.getLogger("sill.files")


def downloads_dir():
    d = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD) or os.path.expanduser("~/Downloads")
    os.makedirs(d, exist_ok=True)
    return d


def safe_relative(name):
    """A relative path that stays inside the folder: no "..", no absolute parts, no empty parts."""
    parts = [p for p in str(name).replace("\\", "/").split("/") if p not in ("", ".", "..")]
    parts = [p.replace("\0", "") for p in parts if not p.startswith("~")]
    return os.path.join(*parts) if parts else None


def unique_path(path):
    if not os.path.exists(path) and not os.path.exists(path + ".part"):
        return path
    base, ext = os.path.splitext(path)
    n = 1
    while os.path.exists(f"{base} ({n}){ext}") or os.path.exists(f"{base} ({n}){ext}.part"):
        n += 1
    return f"{base} ({n}){ext}"


def status(s, text):
    s.send(wire.jmsg(wire.FILE_STATUS, {"text": text}))


class Incoming:
    """The transfers one session is sending here."""

    def __init__(self):
        self.open = {}        # id -> [file, final path, size, received]
        self.saved = []
        self.folders = {}     # the sender's root index -> the folder made for it here
        self.lock = threading.Lock()

    def start(self, s, msg):
        rel = safe_relative(msg.get("name", ""))
        tid, size = msg.get("id"), msg.get("size")
        if rel is None or not isinstance(tid, int) or not isinstance(size, int) or size < 0:
            return
        top = downloads_dir()
        first, sep, rest = rel.partition(os.sep)
        if not sep:
            dest = unique_path(os.path.join(top, rel))
        else:
            # A folder keeps its shape; if its name is taken, the whole folder gets " (1)".
            key = msg.get("root")
            folder = self.folders.get(key)
            if folder is None:
                folder = self.folders[key] = unique_path(os.path.join(top, first))
            dest = os.path.join(folder, rest)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        try:
            f = open(dest + ".part", "wb")
        except OSError as e:
            status(s, f"Could not save {rel}: {e.strerror}")
            s.send(wire.jmsg(wire.FILE_CANCEL, {"id": tid}))
            return
        with self.lock:
            self.open[tid] = [f, dest, size, 0]

    def data(self, s, payload):
        if len(payload) < 4:
            return
        tid = struct.unpack(">I", payload[:4])[0]
        with self.lock:
            t = self.open.get(tid)
        if t is None:
            return
        try:
            t[0].write(payload[4:])
            t[3] += len(payload) - 4
        except OSError as e:
            self._drop(tid)
            status(s, f"Could not save {os.path.basename(t[1])}: {e.strerror}")
            s.send(wire.jmsg(wire.FILE_CANCEL, {"id": tid}))

    def end(self, s, msg):
        tid = msg.get("id")
        with self.lock:
            t = self.open.pop(tid, None)
        if t is None:
            return
        f, dest, size, got = t
        f.close()
        if got != size:
            os.unlink(dest + ".part")
            status(s, f"{os.path.basename(dest)} did not arrive whole")
            return
        os.replace(dest + ".part", dest)
        log.info("received %s (%d bytes)", dest, size)
        self.saved.append(dest)
        if msg.get("last"):
            n = len(self.saved)
            where = os.path.dirname(self.saved[0]) if n == 1 else downloads_dir()
            status(s, f"Saved {n} file{'s' if n != 1 else ''} to {where}")
            self.saved = []
            self.folders = {}

    def cancel(self, msg):
        self._drop(msg.get("id"))

    def _drop(self, tid):
        with self.lock:
            t = self.open.pop(tid, None)
        if t is not None:
            t[0].close()
            try:
                os.unlink(t[1] + ".part")
            except OSError:
                pass

    def close(self):
        for tid in list(self.open):
            self._drop(tid)


def _walk(paths):
    """(local path, relative name, root) for every file in `paths`, folders included."""
    for root_i, p in enumerate(paths):
        p = os.path.abspath(p)
        if os.path.isdir(p) and not os.path.islink(p):
            base = os.path.dirname(p.rstrip("/"))
            for dirpath, dirs, names in os.walk(p):
                dirs.sort()
                for n in sorted(names):
                    full = os.path.join(dirpath, n)
                    if os.path.isfile(full):
                        yield full, os.path.relpath(full, base).replace(os.sep, "/"), root_i
        elif os.path.isfile(p):
            yield p, os.path.basename(p), root_i


def send_paths(s, paths, next_id):
    """Sends files to a session (call on a worker thread). Returns how many arrived."""
    items = list(_walk(paths))
    if not items:
        status(s, "Nothing to send: copy files in Files first (Ctrl+C), then try again")
        return 0
    total = sum(os.path.getsize(p) for p, _, _ in items)
    status(s, f"Sending {len(items)} file{'s' if len(items) != 1 else ''} ({total / 1e6:.1f} MB)…")
    sent = 0
    for i, (path, name, root) in enumerate(items):
        tid = next_id()
        try:
            size = os.path.getsize(path)
            s.send(wire.jmsg(wire.FILE_START, {"id": tid, "name": name, "size": size, "root": root}))
            with open(path, "rb") as f:
                while True:
                    chunk = f.read(wire.FILE_CHUNK)
                    if not chunk:
                        break
                    if not s.send_bulk(wire.pack(wire.FILE_DATA, struct.pack(">I", tid) + chunk)):
                        log.info("file transfer to %s stopped", s)
                        return sent
            s.send(wire.jmsg(wire.FILE_END, {"id": tid, "last": i == len(items) - 1}))
            sent += 1
        except OSError as e:
            s.send(wire.jmsg(wire.FILE_CANCEL, {"id": tid}))
            status(s, f"Could not read {name}: {e.strerror}")
    log.info("sent %d files to %s", sent, s)
    return sent
