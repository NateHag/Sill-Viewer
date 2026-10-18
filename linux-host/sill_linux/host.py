"""The coordinator: sessions, what streams, settings, input."""
import json
import logging
import os
import socket
import subprocess
import threading
import time
import uuid
import zlib

from gi.repository import GLib

from . import files, keymap, mutter, video, wire
from .identity import Devices, Identity, config_dir
from .mdns import Advertiser
from .net import Door
from .pairing import Pairing, grouped

log = logging.getLogger("sill.host")

VIRTUAL_ID = 1
PRESETS = [4_000_000, 8_000_000, 15_000_000, 25_000_000, 40_000_000, 80_000_000, 150_000_000]
DEFAULTS = {"maxFPS": 60, "bitrate": 40_000_000, "captureScale": 2.0, "prioritizeSpeed": False,
            "virtualDisplay": False, "paused": False}
SKIP_IFACES = ("lo", "docker", "br-", "veth", "virbr", "vmnet", "vboxnet")


def local_addresses():
    """This computer's LAN and VPN addresses, best first (Tailscale, then IPv4, then IPv6)."""
    try:
        out = subprocess.run(["ip", "-j", "addr", "show"], capture_output=True, text=True, timeout=3).stdout
        ifaces = json.loads(out)
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    found = []
    for iface in ifaces:
        name = iface.get("ifname", "")
        if name.startswith(SKIP_IFACES) or "UP" not in iface.get("flags", []):
            continue
        for a in iface.get("addr_info", []):
            if a.get("scope") != "global":
                continue
            ip = a["local"]
            rank = 0 if name.startswith("tailscale") else (1 if a["family"] == "inet" else 2)
            found.append((rank, ip))
    return [ip for _, ip in sorted(found)]


def _even(n):
    return max(2, int(n) // 2 * 2)


def window_id(connector):
    return (zlib.crc32(connector.encode()) & 0x7FFFFFFF) | 0x100


class Settings:
    def __init__(self):
        self.path = os.path.join(config_dir(), "settings.json")
        self.values = dict(DEFAULTS)
        if os.path.exists(self.path):
            try:
                with open(self.path) as f:
                    saved = json.load(f)
                self.values.update({k: v for k, v in saved.items() if k in DEFAULTS})
            except (OSError, ValueError):
                pass

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.values, f, indent=1)
        os.replace(tmp, self.path)

    def __getitem__(self, k):
        return self.values[k]


class Spec:
    """What should run. Two equal specs mean the running pipeline can stay."""

    def __init__(self, **kw):
        self.__dict__.update(kw)

    def key(self):
        return tuple(sorted(self.__dict__.items()))

    def __eq__(self, other):
        return isinstance(other, Spec) and self.key() == other.key()


class Host:
    def __init__(self, args):
        self.args = args
        self.identity = Identity()
        self.devices = Devices()
        self.settings = Settings()
        self.name = args.name or socket.gethostname()
        self.launch_id = str(uuid.uuid4()).upper()
        self.lock = threading.RLock()
        self.sessions = set()
        self.active = {"none": {}}
        self.monitors = []
        self.capture = None
        self.pipeline = None
        self.running = None          # the Spec now running
        self.fail_count = 0
        # Highest frame rate this computer's encoder managed; lowered when a faster one fails.
        self.fps_limit = 120
        self.apply_pending = None
        self.idle_since = None
        self.last_frames = (0, time.monotonic())
        self.input_state = {}        # session -> {"keys": set(), "buttons": set(), "finish": source id}
        self.bus = None
        self.mutter = False
        if not args.test_source:
            self.bus = mutter.session_bus()
            self.mutter = mutter.available(self.bus)
            if not self.mutter:
                raise SystemExit("GNOME's remote desktop API (org.gnome.Mutter.RemoteDesktop) is not on the session "
                                 "bus. Run this inside your GNOME session, or use --test-source.")
            self.monitors = mutter.monitors(self.bus)
            mutter.watch_monitors(self.bus, self._monitors_changed)
            log.info("monitors: %s", self.monitors)
        self.door = Door(self.identity, args.port, self, self.devices, require_pairing=not args.open)
        self.pairing = Pairing(self.identity, self.devices, self.name, self.door.port, local_addresses)
        self.advertiser = Advertiser(self.name, self.door.port, self._txt)

    # --- running ------------------------------------------------------------------------------
    def run(self):
        video.init()
        self.door.serve_forever()
        self.advertiser.start()
        self._control_server()
        GLib.timeout_add(2000, self._watchdog)
        log.info("ready: \"%s\", ID %s, port %d, %s", self.name, self.identity.mac_id[:6], self.door.port,
                 "pairing required" if not self.args.open else "OPEN: any device may connect")
        self.loop = GLib.MainLoop()
        for sig in (2, 15):
            GLib.unix_signal_add(GLib.PRIORITY_HIGH, sig, self._quit)
        self.loop.run()

    def _quit(self):
        log.info("quitting")
        with self.lock:
            sessions = list(self.sessions)
        for s in sessions:
            s.close({"reason": "quit"})
        time.sleep(0.15)
        self._stop_stream()
        self.advertiser.stop()
        self.loop.quit()
        return False

    def _txt(self):
        return {"p": "0" if self.args.open else "1", "r": self.identity.recognition_tag()}

    # --- catalog --------------------------------------------------------------------------------
    def window_list(self):
        windows = []
        if self.args.test_source:
            windows.append({"id": 0x200, "title": "Test pattern", "appName": "Test", "bundleID": "linux.test",
                            "width": 1920, "height": 1080})
        for m in self.monitors:
            windows.append({"id": window_id(m.connector), "title": f"{m.name} ({m.connector})", "appName": "Display",
                            "bundleID": "linux.display", "width": int(m.width / m.scale),
                            "height": int(m.height / m.scale)})
        if self.mutter:
            windows.append({"id": VIRTUAL_ID, "title": "A screen sized to this device", "appName": "Virtual Display",
                            "bundleID": "linux.virtual", "width": 0, "height": 0})
        return {"macName": self.name, "windows": windows, "active": self.active, "launchID": self.launch_id,
                "hostVersion": "0.1.0", "protocol": wire.PROTOCOL,
                "cursorInVideo": bool(self.running.cursor) if self.running is not None else False,
                "clipboard": 1, "files": 1}

    def settings_state(self, answering=None):
        s = self.settings
        state = {"settings": {"maxFPS": s["maxFPS"], "bitrate": s["bitrate"], "captureScale": s["captureScale"],
                              "prioritizeSpeed": s["prioritizeSpeed"], "virtualDisplay": s["virtualDisplay"]},
                 "persistent": True, "virtualDisplayAvailable": self.mutter, "pixelMatch": self.mutter,
                 "softwareEncoder": bool(self.pipeline and self.pipeline.encoder == "x265enc")}
        if not self.mutter:
            state["virtualDisplayNote"] = "Needs GNOME on Wayland."
        r = self.running
        if r is not None and self.pipeline is not None:
            w, h = self.pipeline.capture_size or (r.width or 0, r.height or 0)
            if r.scale_half and w:
                w, h = _even(w / 2), _even(h / 2)
            state["stream"] = {"width": int(w), "height": int(h), "fps": r.fps,
                               "mbps": int(r.bitrate * r.fps / 60 / 1_000_000), "onVirtualDisplay": r.virtual}
        if answering is not None:
            state["answering"] = answering
        return state

    def broadcast(self, data, frame=False):
        with self.lock:
            sessions = list(self.sessions)
        for s in sessions:
            s.send(data, frame)

    def broadcast_window_list(self):
        self.broadcast(wire.jmsg(wire.WINDOW_LIST, self.window_list()))

    def broadcast_settings(self, except_session=None):
        msg = wire.jmsg(wire.HOST_SETTINGS, self.settings_state())
        with self.lock:
            sessions = [s for s in self.sessions if s is not except_session]
        for s in sessions:
            s.send(msg)

    def _monitors_changed(self):
        try:
            self.monitors = mutter.monitors(self.bus)
        except GLib.Error as e:
            log.error("monitors: %s", e.message)
            return
        log.info("monitors changed: %s", self.monitors)
        self.broadcast_window_list()
        self.schedule_apply(1.0)

    # --- sessions (called from connection threads) ---------------------------------------------
    def paused_goodbye(self):
        return {"reason": "paused", "reconnect": False,
                "message": f"Sharing is paused on {self.name}. Resume it from the Sill icon at the top of the screen."}

    def session_started(self, s):
        if self.settings["paused"]:
            log.info("%s: refused, sharing is paused", s)
            s.close(self.paused_goodbye())
            return
        with self.lock:
            self.sessions.add(s)
            self.input_state[s] = {"keys": set(), "buttons": set(), "finish": None, "scroll_open": False}
            self.idle_since = None
        s.send(wire.jmsg(wire.WINDOW_LIST, self.window_list()))
        s.send(wire.jmsg(wire.HOST_SETTINGS, self.settings_state()))
        s.send(wire.jmsg(wire.APP_LIST, []))
        self.schedule_apply()
        if self.pipeline is not None:
            self.pipeline.force_keyframe()

    def session_ended(self, s):
        self._release_input(s)
        inc = getattr(s, "incoming", None)
        if inc is not None:
            inc.close()      # half-received files are deleted
        with self.lock:
            self.sessions.discard(s)
            self.input_state.pop(s, None)
            if not self.sessions:
                self.idle_since = time.monotonic()
        self.schedule_apply()

    def ticking(self):
        return self.pipeline is not None

    def on_message(self, s, kind, payload):
        if kind == wire.HELLO:
            if s.hello is None:
                s.hello = json.loads(payload or b"{}")
                dev = s.hello.get("device")
                log.info("%s: Sill %s on %s", s, s.hello.get("appVersion"), dev)
                self.schedule_apply(0.2)
        elif kind == wire.SELECT_SOURCE:
            self._select(json.loads(payload))
        elif kind == wire.VIEWPORT:
            vp = json.loads(payload)
            s.viewport = vp
            s.fps = int(vp.get("fps") or 60)
            self.schedule_apply(0.6)
        elif kind == wire.INPUT:
            self._input(s, json.loads(payload))
        elif kind == wire.CHANGE_SETTINGS:
            self._change_settings(s, json.loads(payload))
        elif kind == wire.CLIENT_STATS:
            st = json.loads(payload)
            log.debug("%s: %s fps, frame age %s ms, rtt %s ms", s, st.get("fps"), st.get("frameAgeMs"), st.get("rttMs"))
        elif kind == wire.PAIRING_WANTED:
            self.pairing.open_window()
        elif kind == wire.CLIPBOARD:
            self._clipboard_from_device(s, json.loads(payload))
        elif kind == wire.SILL_CLIPBOARD:
            msg = json.loads(payload or b"{}")
            if not isinstance(msg, dict):
                return
            if msg.get("stop"):
                s.clip_sub = False
                return
            # Subscribing sends nothing back: what was copied before would overwrite what the
            # person just copied on the device. Only new copies go out.
            s.clip_sub = True
            if "text" in msg:
                self._clipboard_from_device(s, msg)
        elif kind == wire.FILE_DATA:
            self._incoming(s).data(s, payload)
        elif kind == wire.FILE_START:
            self._incoming(s).start(s, json.loads(payload))
        elif kind == wire.FILE_END:
            self._incoming(s).end(s, json.loads(payload))
        elif kind == wire.FILE_CANCEL:
            self._incoming(s).cancel(json.loads(payload))
        elif kind == wire.FILE_REQUEST:
            threading.Thread(target=self._send_copied_files, args=(s,), daemon=True).start()
        # kinds 7, 15, 25, 27, 28 and unknown ones are skipped: no apps, menus or gestures here

    # --- files both ways ------------------------------------------------------------------------
    def _incoming(self, s):
        inc = getattr(s, "incoming", None)
        if inc is None:
            inc = s.incoming = files.Incoming()
        return inc

    def _next_file_id(self):
        with self.lock:
            self.file_id = getattr(self, "file_id", 0) + 1
            return self.file_id

    def _send_copied_files(self, s):
        cap = self.capture
        paths = cap.copied_paths() if cap is not None else []
        if not paths:
            files.status(s, f"No files are copied on {self.name}. Select files in Files, press Ctrl+C, "
                            "then try again.")
            return
        files.send_paths(s, paths, self._next_file_id)

    # --- clipboard: text both ways, while a session streams --------------------------------------
    def _clipboard_from_device(self, s, msg):
        text = msg.get("text") if isinstance(msg, dict) else None
        if not isinstance(text, str) or not text or len(text) > wire.MAX_CLIPBOARD_TEXT:
            return
        self.clip_last = text
        self.clip_from = s
        cap = self.capture
        if cap is not None:
            cap.set_text(text)
        # Other viewers get it too, so every screen pastes the same thing.
        with self.lock:
            others = [x for x in self.sessions if x is not s]
        for x in others:
            self._send_clipboard(x, text)

    def _send_clipboard(self, x, text):
        """Sill's kind 32 to a session that subscribed (an iPhone, a Mac app, a new viewer);
        kind 200 to an older Sill Viewer."""
        if getattr(x, "clip_sub", False):
            if len(text.encode("utf-8")) <= wire.SILL_CLIPBOARD_TEXT:
                x.send(wire.jmsg(wire.SILL_CLIPBOARD, {"text": text}))
        else:
            x.send(wire.jmsg(wire.CLIPBOARD, {"text": text}))

    def _clipboard_from_here(self, text):
        if text == getattr(self, "clip_last", None):
            return      # our own text coming back, or no change
        self.clip_last = text
        with self.lock:
            sessions = list(self.sessions)
        for x in sessions:
            self._send_clipboard(x, text)

    def _select(self, src):
        if not isinstance(src, dict) or len(src) != 1:
            return
        if "window" in src:
            wid = src["window"].get("_0")
            known = {w["id"] for w in self.window_list()["windows"]}
            if wid not in known:
                log.info("pick of an unknown window %s: showing the desktop", wid)
                src = {"desktop": {}}
        with self.lock:
            self.active = src
        log.info("source: %s", src)
        self.broadcast_window_list()
        self.schedule_apply()

    # --- settings --------------------------------------------------------------------------------
    def _change_settings(self, s, ch):
        v = self.settings.values
        if "maxFPS" in ch and ch["maxFPS"] in (30, 60, 120):
            v["maxFPS"] = ch["maxFPS"]
        if "bitrate" in ch and isinstance(ch["bitrate"], int) and 1_000_000 <= ch["bitrate"] <= 300_000_000:
            v["bitrate"] = ch["bitrate"]
        if "captureScale" in ch and ch["captureScale"] in (1, 2, 1.0, 2.0):
            v["captureScale"] = float(ch["captureScale"])
        if "prioritizeSpeed" in ch and isinstance(ch["prioritizeSpeed"], bool):
            v["prioritizeSpeed"] = ch["prioritizeSpeed"]
        if "virtualDisplay" in ch and isinstance(ch["virtualDisplay"], bool) and self.mutter:
            v["virtualDisplay"] = ch["virtualDisplay"]
        self.settings.save()
        log.info("settings: %s", v)
        if s is not None:
            s.send(wire.jmsg(wire.HOST_SETTINGS, self.settings_state(answering=ch.get("token"))))
        self.broadcast_settings(except_session=s)
        self.schedule_apply()

    # --- the stream (main thread) --------------------------------------------------------------
    def schedule_apply(self, delay=0.0, force=False):
        def go():
            self.apply_pending = None
            self._apply(force)
            return False
        with self.lock:
            if self.apply_pending is not None:
                GLib.source_remove(self.apply_pending)
            self.apply_pending = GLib.timeout_add(int(delay * 1000), go)

    def _desired(self):
        with self.lock:
            sessions = list(self.sessions)
            active = dict(self.active)
            idle_since = self.idle_since
        if "none" in active or self.settings["paused"]:
            return None
        if not sessions and (idle_since is None or time.monotonic() - idle_since > 10):
            return None
        if not sessions and self.running is not None:
            return self.running      # the 10 s after the last device leaves: keep what runs, a quick return reuses it
        s = self.settings
        fps = max([x.fps for x in sessions] or [60])
        fps = max(24, min(s["maxFPS"], fps, self.fps_limit))
        half = s["captureScale"] < 1.5
        base = dict(fps=fps, bitrate=s["bitrate"], speed=s["prioritizeSpeed"], scale_half=half,
                    cursor=self._cursor_in_video(sessions))
        wid = active.get("window", {}).get("_0") if "window" in active else None
        want_virtual = wid == VIRTUAL_ID or ("desktop" in active and s["virtualDisplay"])
        # GNOME sends at most one frame per screen refresh: asking for more only fails.
        if want_virtual:
            base["fps"] = min(base["fps"], 60)
        if self.args.test_source:
            return Spec(kind="test", connector=None, virtual=False, width=1920, height=1080, **base)
        if want_virtual:
            vps = [x.viewport for x in sessions if x.viewport]
            vp = vps[-1] if vps else {"width": 1180, "height": 820}
            pw, ph = vp.get("pixelWidth"), vp.get("pixelHeight")
            if isinstance(pw, (int, float)) and isinstance(ph, (int, float)) and 320 <= pw <= 8192 and 240 <= ph <= 8192:
                # The viewer asked for its screen's exact pixels ("Match this screen"): one
                # remote pixel per screen pixel, whatever Sharp says.
                ps = vp.get("pixelScale")
                vscale = float(ps) if isinstance(ps, (int, float)) and 0.5 <= ps <= 4 else 1.0
                return Spec(kind="mutter", connector=None, virtual=True, width=_even(pw), height=_even(ph),
                            vscale=vscale, **dict(base, scale_half=False))
            # Fit screen: the window's own pixels (Sill Viewer says how many per point), so nothing
            # is drawn, copied and encoded that the viewer then shrinks away. Older viewers and
            # the iPad don't say: points times 2 (a Retina screen; GNOME shows it at 200%).
            ppp = vp.get("pixelsPerPoint")
            if isinstance(ppp, (int, float)) and 0.5 <= ppp <= 4:
                k = 1.0 if half else max(1.0, float(ppp))
            else:
                k = 1 if half else 2
            return Spec(kind="mutter", connector=None, virtual=True, width=_even(vp["width"] * k),
                        height=_even(vp["height"] * k), vscale=float(k), **dict(base, scale_half=False))
        mon = next((m for m in self.monitors if window_id(m.connector) == wid), None)
        if mon is None:
            mon = next((m for m in self.monitors if m.primary), self.monitors[0] if self.monitors else None)
        if mon is None:
            return None
        if mon.refresh and mon.refresh >= 24:
            base["fps"] = min(base["fps"], max(24, int(round(mon.refresh))))
        return Spec(kind="mutter", connector=mon.connector, virtual=False, width=mon.width, height=mon.height, **base)

    def _apply(self, force=False):
        spec = self._desired()
        if spec == self.running and not force and (spec is None or self.pipeline is not None or self.capture):
            return
        self._stop_stream()
        self.running = spec
        if spec is None:
            log.info("nothing to stream")
            self.broadcast_settings()
            return
        log.info("starting: %s", spec.__dict__)
        if spec.kind == "test":
            self._start_pipeline(spec, f"videotestsrc is-live=true pattern=ball ! "
                                       f"video/x-raw,width={spec.width},height={spec.height},framerate={spec.fps}/1")
            return
        try:
            cursor = mutter.CURSOR_EMBEDDED if spec.cursor else mutter.CURSOR_HIDDEN
            self.capture = mutter.Capture(self.bus, monitor=spec.connector, virtual=spec.virtual, cursor_mode=cursor,
                                          on_ready=lambda node: self._start_pipeline(spec, self._pipewire(node, spec)),
                                          on_closed=self._capture_closed)
            if self.capture.enable_clipboard(self._clipboard_from_here, wire.MAX_CLIPBOARD_TEXT):
                last = getattr(self, "clip_last", None)
                if last and getattr(self, "clip_from", None) is not None:
                    self.capture.set_text(last)   # a new stream keeps what the viewer copied
        except GLib.Error as e:
            log.error("screen cast: %s", e.message)
            self.capture = None
            self._retry()

    def _cursor_in_video(self, sessions):
        """GNOME draws the cursor into the video at the wrong place when the display is scaled, so a
        desktop viewer, which shows its own cursor where the input goes, gets none in the video. An
        iPhone or iPad needs one to see where the pointer is."""
        if self.args.cursor != "auto":
            return self.args.cursor == "embedded"
        return any(not str((x.hello or {}).get("device") or "").startswith("Sill Viewer") for x in sessions)

    def _pipewire(self, node, spec):
        el = video.Gst.ElementFactory.make("pipewiresrc", None)
        if el is None:
            raise RuntimeError("pipewiresrc missing: install gstreamer1.0-pipewire")
        # GNOME gives a node ID. `path` takes a node ID; `target-object` takes a name or serial,
        # so a node ID there links to nothing and no frame ever arrives.
        target = "path"
        extra = ""
        if el.find_property("keepalive-time"):
            extra += " keepalive-time=100"
        if el.find_property("always-copy"):
            extra += " always-copy=true"
        caps = "video/x-raw"
        if self.fail_count % 2 == 0:
            caps += f",max-framerate={spec.fps}/1"
        if spec.virtual:
            caps += f",width={spec.width},height={spec.height}"
        return f"pipewiresrc {target}={node} do-timestamp=true{extra} ! {caps}"

    def _start_pipeline(self, spec, source_desc):
        if self.running is not spec:
            return
        w = h = None
        if spec.scale_half and spec.width:
            w, h = _even(spec.width / 2), _even(spec.height / 2)
        try:
            self.pipeline = video.Pipeline(source_desc, w, h, spec.fps, spec.bitrate, spec.speed,
                                           self._on_au, self._pipeline_failed, encoder=self.args.encoder)
            self.pipeline.start()
        except Exception as e:
            log.error("could not start the stream: %s", e)
            self.pipeline = None
            self._too_fast(spec)
            self.fail_count += 1
            self._retry()
            return
        self.last_frames = (0, time.monotonic())
        self.broadcast_settings()
        self.broadcast_window_list()
        GLib.timeout_add(700, lambda: (self._scale_virtual(), False)[1])

    def _stop_stream(self):
        if self.pipeline is not None:
            self.pipeline.stop()
            self.pipeline = None
        if self.capture is not None:
            self.release_everything()      # nothing stays down when GNOME's input session ends
            self.capture.stop()
            self.capture = None

    def _pipeline_failed(self, reason):
        frames = self.pipeline.frames if self.pipeline else 0
        log.warning("stream stopped: %s", reason)
        self.fail_count = self.fail_count + 1 if frames == 0 else 0
        if frames == 0 and self.running is not None:
            self._too_fast(self.running)
        self._stop_stream()
        self._retry()

    def _capture_closed(self):
        self.capture = None
        if self.pipeline is not None:
            self.pipeline.stop()
            self.pipeline = None
        self._retry()

    def _too_fast(self, spec):
        """A stream above 60 fps that never gave a frame: this GPU's encoder cannot go that fast
        (at this size). Stay at 60 from now on, instead of falling back to a slow software encoder."""
        if spec.fps > 60 and self.fps_limit > 60:
            self.fps_limit = 60
            log.warning("the encoder cannot do %d fps here; using 60 fps", spec.fps)

    def _retry(self):
        delay = min(0.5 * (2 ** min(self.fail_count, 5)), 10)
        log.info("restarting the stream in %.1f s", delay)
        self.running = None
        self.schedule_apply(delay)

    def _watchdog(self):
        self._scale_virtual()
        p = self.pipeline
        if p is not None and self.running is not None:
            n, t = self.last_frames
            if p.frames != n:
                self.last_frames = (p.frames, time.monotonic())
                if p.frames > 30:
                    self.fail_count = 0
            elif time.monotonic() - t > 8:
                log.warning("no frames for 8 s; restarting the stream")
                self._stop_stream()
                self._retry()
        with self.lock:
            idle = self.idle_since
        if idle is not None and self.running is not None and time.monotonic() - idle > 10:
            self.schedule_apply()
        return True

    def _scale_virtual(self):
        """Once a virtual screen is up and streaming, make it the only screen (the physical ones go
        dark until it ends) with the scale the device wants (a Retina Mac: 2). Once per stream."""
        p, r = self.pipeline, self.running
        if self.bus is None or p is None or r is None or not getattr(r, "virtual", False) or getattr(p, "scaled", False):
            return
        if p.capture_size is None:
            return
        p.scaled = True
        want = getattr(r, "vscale", 1.0)
        try:
            got = mutter.take_over(self.bus, want)
            if got:
                scale, logical = got
                log.info("virtual screen is now the only screen, at scale %s (asked %s)", scale, want)
                p.virtual_scale = float(scale) if logical else 1.0
            else:
                log.warning("no virtual monitor to set up")
        except GLib.Error as e:
            log.warning("could not set the virtual screen's scale: %s", e.message)

    def _on_au(self, params, payload, key):
        dump = os.environ.get("SILL_DUMP")
        if dump:     # debugging: write what the device gets back as Annex B, for ffmpeg
            with open(dump, "ab") as f:
                for nal in (params or []) if key else []:
                    f.write(b"\x00\x00\x00\x01" + nal)
                i = 0
                while i < len(payload):
                    n = int.from_bytes(payload[i:i + 4], "big")
                    f.write(b"\x00\x00\x00\x01" + payload[i + 4:i + 4 + n])
                    i += 4 + n
        params_msg = None
        if key and params:
            params_msg = wire.pack(wire.PARAMETER_SETS, wire.parameter_sets_payload(params), key=True)
        frame_msg = wire.pack(wire.FRAME, payload, key=key)
        with self.lock:
            sessions = list(self.sessions)
        need_key = False
        for s in sessions:
            if s.offer_au(params_msg, frame_msg, key):
                need_key = True
            elif s.waiting_key and not key:
                need_key = True
        if need_key and self.pipeline is not None:
            self.pipeline.force_keyframe()

    # --- input (connection threads) --------------------------------------------------------------
    def _frame_size(self):
        p = self.pipeline
        if p is not None and p.capture_size is not None:
            return p.capture_size
        r = self.running
        if r is not None and r.width and r.height:
            return (r.width, r.height)
        return None

    def _virtual_scale(self):
        """The scale set on the virtual screen (1 until it is set). GNOME takes pointer positions on
        a virtual stream in logical pixels (stream pixels / scale), not in stream pixels."""
        p, r = self.pipeline, self.running
        if p is None or r is None or not getattr(r, "virtual", False):
            return 1.0
        return getattr(p, "virtual_scale", 1.0)

    def _logical_scale(self):
        r = self.running
        if r is None or r.connector is None:
            return self._virtual_scale()
        if r.virtual:
            return 1.0
        m = next((m for m in self.monitors if m.connector == r.connector), None)
        return m.scale if m else 1.0

    def _input(self, s, ev):
        cap = self.capture
        st = self.input_state.get(s)
        if st is None or not isinstance(ev, dict):
            return
        size = self._frame_size()
        if self.args.trace_input and ("pointer" in ev or "scroll" in ev or "scrollGesture" in ev):
            log.info("input: %s", ev)          # pointer and scroll only: keys and text are never logged
        elif os.environ.get("SILL_TEST_LOG_KEYS") == "1" and "key" in ev:
            log.info("input: %s", ev)          # tests only, set by hand
        if "pointer" in ev:
            p = ev["pointer"]
            action = p.get("_0")
            if cap is None:
                return
            # A pointer event always ends any scroll still open, so the app under the pointer never
            # takes later moves as part of a finger scroll.
            self._close_scroll(st, cap)
            if size is not None:
                k = self._virtual_scale()
                x = min(max(float(p.get("x", 0)), 0.0), 1.0) * (size[0] - 1) / k
                y = min(max(float(p.get("y", 0)), 0.0), 1.0) * (size[1] - 1) / k
                cap.motion(x, y)
            button = {"leftDown": (mutter.BTN_LEFT, True), "leftUp": (mutter.BTN_LEFT, False),
                      "rightDown": (mutter.BTN_RIGHT, True), "rightUp": (mutter.BTN_RIGHT, False)}.get(action)
            if button:
                cap.button(*button)
                (st["buttons"].add if button[1] else st["buttons"].discard)(button[0])
        elif "scroll" in ev and cap is not None and size is not None:
            sc = ev["scroll"]
            k = self.args.scroll_speed / self._logical_scale()
            dx = -float(sc.get("dx", 0)) * size[0] * k
            dy = -float(sc.get("dy", 0)) * size[1] * k
            self._cancel_finish(st)
            if dx or dy:
                cap.axis(dx, dy)
                st["scroll_open"] = True
        elif "scrollGesture" in ev and cap is not None:
            phase = ev["scrollGesture"].get("_0")
            if phase == "began":
                self._close_scroll(st, cap)
            elif phase == "momentumBegan":
                self._cancel_finish(st)
            elif phase == "ended":
                def finish():
                    st["finish"] = None
                    self._close_scroll(st, cap)
                    return False
                self._cancel_finish(st)
                st["finish"] = GLib.timeout_add(80, finish)
            elif phase == "momentumEnded":
                self._close_scroll(st, cap)
        elif "key" in ev and cap is not None:
            k = ev["key"]
            code = keymap.evdev_code(int(k.get("hidUsage", 0)), self.args.command_key)
            if code is None:
                return
            down = bool(k.get("down"))
            if down or code in st["keys"]:
                cap.key(code, down)
                (st["keys"].add if down else st["keys"].discard)(code)
        elif "text" in ev and cap is not None:
            text = ev["text"].get("_0", "")
            for code in [c for c in st["keys"] if c in keymap.MODIFIER_CODES]:
                cap.key(code, False)
                st["keys"].discard(code)
            for ch in text[:1000]:
                special = {"\n": keymap.KEY_ENTER, "\r": keymap.KEY_ENTER, "\t": keymap.KEY_TAB,
                           "\b": keymap.KEY_BACKSPACE}.get(ch)
                if special:
                    cap.key(special, True)
                    cap.key(special, False)
                else:
                    sym = keymap.keysym_for(ch)
                    cap.keysym(sym, True)
                    cap.keysym(sym, False)

    def _cancel_finish(self, st):
        src, st["finish"] = st.get("finish"), None
        if src is not None:
            GLib.source_remove(src)

    def _close_scroll(self, st, cap):
        self._cancel_finish(st)
        if st.get("scroll_open"):
            st["scroll_open"] = False
            cap.axis(0, 0, mutter.AXIS_FINISH_X | mutter.AXIS_FINISH_Y)

    def _release_input(self, s):
        st = self.input_state.get(s)
        cap = self.capture
        if not st or cap is None:
            return
        for code in list(st["keys"]):
            cap.key(code, False)
        for b in list(st["buttons"]):
            cap.button(b, False)
        st["keys"].clear()
        st["buttons"].clear()
        self._close_scroll(st, cap)

    def release_everything(self):
        """Lets go of every key and button the devices may hold, and every modifier and mouse button
        whether or not this host thinks it is down: a stuck Ctrl or Super turns your own clicks on
        this computer into Ctrl-clicks or Super-clicks, which look like clicks that do nothing."""
        cap = self.capture
        if cap is None:
            return
        with self.lock:
            sessions = list(self.input_state)
        for s in sessions:
            self._release_input(s)
        for code in keymap.MODIFIER_CODES:
            cap.key(code, False)
        for b in (mutter.BTN_LEFT, mutter.BTN_RIGHT, mutter.BTN_MIDDLE):
            cap.button(b, False)
        log.info("released every key and button")

    # --- the control socket (for `sill-linux pair`, `status`, `forget`) -------------------------
    def _control_server(self):
        path = control_path()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        os.chmod(path, 0o600)
        srv.listen(4)

        def loop():
            while True:
                c, _ = srv.accept()
                try:
                    cmd = json.loads(c.recv(4096) or b"{}")
                    c.sendall(json.dumps(self._control(cmd)).encode())
                except Exception as e:
                    log.exception("control")
                    try:
                        c.sendall(json.dumps({"error": str(e)}).encode())
                    except OSError:
                        pass
                finally:
                    c.close()
        threading.Thread(target=loop, name="control", daemon=True).start()

    def _control(self, cmd):
        op = cmd.get("op")
        if op == "pair":
            w = self.pairing.open_window()
            return {"code": grouped(w.code), "link": self.pairing.link(w), "name": self.name}
        if op == "status":
            with self.lock:
                sessions = [{"name": s.name, "address": s.peer, "withheld": s.withheld} for s in self.sessions]
            r = self.running
            return {"name": self.name, "port": self.door.port, "id": self.identity.mac_id,
                    "pairing": not self.args.open, "sessions": sessions, "active": self.active,
                    "paused": self.settings["paused"], "settings": self.settings_state(),
                    "devices": [{"key": k, "name": d.get("name"), "model": d.get("model")}
                                for k, d in self.devices.listing().items()],
                    "stream": r.__dict__ if r else None,
                    "encoder": self.pipeline.encoder if self.pipeline else None,
                    "frames": self.pipeline.frames if self.pipeline else 0,
                    "captureSize": self.pipeline.capture_size if self.pipeline else None}
        if op in ("pause", "resume"):
            self.settings.values["paused"] = op == "pause"
            self.settings.save()
            if op == "pause":
                self.release_everything()
                with self.lock:
                    sessions = list(self.sessions)
                for s in sessions:
                    s.close(self.paused_goodbye())
                log.info("sharing paused: %d device(s) disconnected", len(sessions))
            else:
                log.info("sharing resumed")
            self.schedule_apply()
            return {"paused": self.settings["paused"]}
        if op == "release":
            self.release_everything()
            return {"released": self.capture is not None}
        if op == "disconnect":
            with self.lock:
                hit = [s for s in self.sessions if cmd.get("device") in (s.name, s.peer)]
            for s in hit:
                s.close({"reason": "disconnected", "reconnect": False,
                         "message": f"{self.name} disconnected this device."})
            return {"disconnected": len(hit)}
        if op == "settings":
            self._change_settings(None, cmd.get("changes") or {})
            return self.settings_state()
        if op == "forget":
            removed = self.devices.remove(cmd.get("device", ""))
            with self.lock:
                hit = [s for s in self.sessions if any(s.fp == _fp(k) for k in removed)]
            for s in hit:
                s.close({"reason": "removed"})
            return {"removed": removed}
        return {"error": f"unknown op {op!r}"}


def _fp(key):
    from .identity import b64u_decode
    return b64u_decode(key)


def control_path():
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/sill-linux-{os.getuid()}"
    os.makedirs(base, mode=0o700, exist_ok=True)
    return os.path.join(base, "sill-linux.sock")
