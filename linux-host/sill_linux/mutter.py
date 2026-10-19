"""GNOME's own screen sharing and input API (the one gnome-remote-desktop uses).

org.gnome.Mutter.RemoteDesktop gives a session that injects pointer and keyboard events.
org.gnome.Mutter.ScreenCast, tied to that session, records a monitor (RecordMonitor) or a new
virtual monitor of any size (RecordVirtual) into a PipeWire stream. No portal dialog, no extra
display driver, no X11.
"""
import logging
import threading

from gi.repository import Gio, GLib

log = logging.getLogger("sill.mutter")

RD_BUS = "org.gnome.Mutter.RemoteDesktop"
RD_PATH = "/org/gnome/Mutter/RemoteDesktop"
RD_SESSION = "org.gnome.Mutter.RemoteDesktop.Session"
SC_BUS = "org.gnome.Mutter.ScreenCast"
SC_PATH = "/org/gnome/Mutter/ScreenCast"
SC_IFACE = "org.gnome.Mutter.ScreenCast"
SC_SESSION = "org.gnome.Mutter.ScreenCast.Session"
SC_STREAM = "org.gnome.Mutter.ScreenCast.Stream"
DC_BUS = "org.gnome.Mutter.DisplayConfig"
DC_PATH = "/org/gnome/Mutter/DisplayConfig"

CURSOR_HIDDEN, CURSOR_EMBEDDED, CURSOR_METADATA = 0, 1, 2

BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
AXIS_FINISH_X, AXIS_FINISH_Y = 1, 2


def session_bus():
    return Gio.bus_get_sync(Gio.BusType.SESSION, None)


def wake_screen(bus):
    """Turn the monitors on if GNOME has blanked them. A blanked GNOME paints nothing, so a
    screen cast of it sends no frames at all and the viewer waits for the picture forever."""
    props = "org.freedesktop.DBus.Properties"
    try:
        r = bus.call_sync(DC_BUS, DC_PATH, props, "Get", GLib.Variant("(ss)", (DC_BUS, "PowerSaveMode")),
                          GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 3000, None)
        mode = r.unpack()[0]
        if mode not in (0, -1):   # 0 = on, -1 = unknown
            log.info("the screen is blanked (power save mode %s); turning it on", mode)
            bus.call_sync(DC_BUS, DC_PATH, props, "Set",
                          GLib.Variant("(ssv)", (DC_BUS, "PowerSaveMode", GLib.Variant("i", 0))),
                          None, Gio.DBusCallFlags.NONE, 3000, None)
        return mode
    except GLib.Error as e:
        log.warning("could not wake the screen: %s", e.message)
        return None


class IdleInhibit:
    """Keeps GNOME from blanking the screen (and so stopping the frames) while a viewer is connected."""
    SM = ("org.gnome.SessionManager", "/org/gnome/SessionManager", "org.gnome.SessionManager")
    IDLE = 8

    def __init__(self, bus):
        self.bus = bus
        self.cookie = None

    def on(self):
        if self.cookie is not None:
            return
        try:
            r = self.bus.call_sync(*self.SM, "Inhibit",
                                   GLib.Variant("(susu)", ("sill-linux", 0, "A Sill viewer is connected", self.IDLE)),
                                   GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 3000, None)
            self.cookie = r.unpack()[0]
            log.info("screen blanking held off while a viewer is connected")
        except GLib.Error as e:
            log.warning("could not hold off screen blanking: %s", e.message)

    def off(self):
        if self.cookie is None:
            return
        cookie, self.cookie = self.cookie, None
        try:
            self.bus.call_sync(*self.SM, "Uninhibit", GLib.Variant("(u)", (cookie,)),
                               None, Gio.DBusCallFlags.NONE, 3000, None)
        except GLib.Error as e:
            log.warning("could not release the blanking hold: %s", e.message)


def available(bus):
    try:
        r = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                          GLib.Variant("(s)", (RD_BUS,)), GLib.VariantType("(b)"), Gio.DBusCallFlags.NONE, 2000, None)
        return r.unpack()[0]
    except GLib.Error:
        return False


class Monitor:
    def __init__(self, connector, name, width, height, refresh, primary, x, y, scale):
        self.connector, self.name = connector, name
        self.width, self.height, self.refresh = width, height, refresh
        self.primary, self.x, self.y, self.scale = primary, x, y, scale

    def __repr__(self):
        return f"<{self.connector} {self.width}x{self.height}@{self.refresh:.0f}{' primary' if self.primary else ''}>"


def monitors(bus):
    """Active physical monitors from DisplayConfig.GetCurrentState. Virtual ones are left out."""
    r = bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "GetCurrentState", None, None, Gio.DBusCallFlags.NONE, 5000, None)
    _serial, mons, logical, _props = r.unpack()
    placed = {}
    for (x, y, scale, transform, primary, specs, _lp) in logical:
        for spec in specs:
            placed[spec[0]] = (x, y, scale, primary, transform)
    out = []
    for (spec, modes, props) in mons:
        connector = spec[0]
        if connector not in placed or connector.startswith("Meta-"):
            continue
        current = next((m for m in modes if m[6].get("is-current")), None)
        if current is None:
            continue
        w, h, refresh = current[1], current[2], current[3]
        x, y, scale, primary, transform = placed[connector]
        if transform % 2 == 1:      # rotated 90 or 270 degrees
            w, h = h, w
        name = props.get("display-name") or f"{spec[1]} {spec[2]}".strip() or connector
        out.append(Monitor(connector, name, w, h, refresh, primary, x, y, scale))
    out.sort(key=lambda m: (not m.primary, m.x, m.y))
    return out


def take_over(bus, want):
    """Makes the virtual monitor (connector "Meta-…") the only screen: the physical monitors are
    turned off while it streams, so every window, the desktop icons and the top bar move to the
    screen the viewer sees. Its scale is the supported one nearest `want`. Temporary: GNOME goes
    back to its saved layout when the virtual monitor goes away.
    Returns (scale, logical): `logical` is True when GNOME lays monitors out in logical pixels
    (then pointer positions on the stream are in logical pixels too). None if there is no virtual
    monitor."""
    r = bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "GetCurrentState", None, None, Gio.DBusCallFlags.NONE, 5000, None)
    serial, mons, _logical, props = r.unpack()
    logical = int(props.get("layout-mode", 1)) == 1
    for (spec, mode_list, _mprops) in mons:
        if not spec[0].startswith("Meta-"):
            continue
        cur = next((m for m in mode_list if m[6].get("is-current")), None) or (mode_list[0] if mode_list else None)
        if cur is None:
            continue
        scale = min(list(cur[5]) or [1.0], key=lambda v: abs(v - want))
        configs = [(0, 0, scale, 0, True, [(spec[0], cur[0], {})])]
        bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "ApplyMonitorsConfig",
                      GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (serial, 1, configs, {})),
                      None, Gio.DBusCallFlags.NONE, 5000, None)
        return scale, logical
    return None


CONFIG_SIG = "(uua(iiduba(ssa{sv}))a{sv})"


def layout(bus):
    """The current layout, to put back later: [(x, y, scale, transform, primary, [(connector, mode)])]."""
    r = bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "GetCurrentState", None, None, Gio.DBusCallFlags.NONE, 5000, None)
    _serial, mons, logical, _props = r.unpack()
    current = {}
    for (spec, modes, _p) in mons:
        m = next((m for m in modes if m[6].get("is-current")), None)
        if m is not None:
            current[spec[0]] = m[0]
    out = []
    for (x, y, scale, transform, primary, specs, _lp) in logical:
        members = [(sp[0], current[sp[0]]) for sp in specs if sp[0] in current]
        if members:
            out.append((x, y, scale, transform, primary, members))
    return out


def apply_layout(bus, saved):
    """Puts back a layout from `layout()`. Temporary: GNOME's saved settings are untouched."""
    r = bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "GetCurrentState", None, None, Gio.DBusCallFlags.NONE, 5000, None)
    serial = r.unpack()[0]
    configs = [(x, y, scale, t, primary, [(c, mode, {}) for (c, mode) in members])
               for (x, y, scale, t, primary, members) in saved]
    bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "ApplyMonitorsConfig", GLib.Variant(CONFIG_SIG, (serial, 1, configs, {})),
                  None, Gio.DBusCallFlags.NONE, 5000, None)


def reset_to_preferred(bus):
    """Puts every monitor in its preferred (native) mode, laid out left to right in its current
    order. Temporary, like apply_layout. Returns True when something changed."""
    r = bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "GetCurrentState", None, None, Gio.DBusCallFlags.NONE, 5000, None)
    serial, mons, logical, props = r.unpack()
    logical_mode = int(props.get("layout-mode", 1)) == 1
    modes = {spec[0]: ms for (spec, ms, _p) in mons}
    changed = False
    configs = []
    x = None
    y0 = 0
    for (lx, ly, scale, transform, primary, specs, _lp) in sorted(logical, key=lambda l: (l[0], l[1])):
        members = []
        width = 0
        for sp in specs:
            c = sp[0]
            ms = modes.get(c) or []
            cur = next((m for m in ms if m[6].get("is-current")), None)
            pref = next((m for m in ms if m[6].get("is-preferred")), None) or cur
            if pref is None:
                continue
            if cur is None or pref[0] != cur[0]:
                changed = True
            scales = list(pref[5]) or [1.0]
            if scale not in scales:
                scale = min(scales, key=lambda v: abs(v - scale))
            w = pref[2] if transform % 2 == 1 else pref[1]
            width = max(width, int(round(w / scale)) if logical_mode else w)
            members.append((c, pref[0], {}))
        if not members:
            continue
        if x is None:
            x, y0 = lx, ly
        configs.append((x, y0, scale, transform, primary, members))
        x += width
    if not changed or not configs:
        return False
    bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "ApplyMonitorsConfig", GLib.Variant(CONFIG_SIG, (serial, 1, configs, {})),
                  None, Gio.DBusCallFlags.NONE, 5000, None)
    return True


def fit_mode(bus, connector, want_w, want_h):
    """Switches `connector` to its mode closest to want_w x want_h pixels: the shape first, then the
    size; among equal sizes the highest refresh rate (at least 50 Hz when there is one). The other
    monitors keep their modes, laid out again side by side to its right. Temporary, like
    apply_layout. Returns (width, height) of the mode, or None when nothing changed."""
    import math
    r = bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "GetCurrentState", None, None, Gio.DBusCallFlags.NONE, 5000, None)
    serial, mons, logical, props = r.unpack()
    logical_mode = int(props.get("layout-mode", 1)) == 1
    target = next(((spec, modes) for (spec, modes, _p) in mons if spec[0] == connector), None)
    if target is None or not target[1]:
        return None
    modes = target[1]
    cur = next((m for m in modes if m[6].get("is-current")), None)
    fast = [m for m in modes if m[3] >= 49.5] or list(modes)
    want_aspect = want_w / max(want_h, 1)

    def cost(m):
        shape = abs(math.log((m[1] / max(m[2], 1)) / want_aspect))
        size = abs(math.log((m[1] * m[2]) / max(want_w * want_h, 1)))
        return (round(shape * 20 + size, 2), -m[3])
    best = min(fast, key=cost)
    if cur is not None and best[0] == cur[0]:
        return None
    # The monitor's place and scale stay; the others keep theirs, moved right so none overlaps.
    place = {}
    for (x, y, scale, transform, primary, specs, _lp) in logical:
        for sp in specs:
            place[sp[0]] = (x, y, scale, transform, primary)
    current = {spec[0]: next((m for m in ms if m[6].get("is-current")), None) for (spec, ms, _p) in mons}
    x0, y0, scale, transform, primary = place.get(connector, (0, 0, 1.0, 0, True))
    scales = list(best[5]) or [1.0]
    if scale not in scales:
        scale = min(scales, key=lambda v: abs(v - scale))
    width = best[1] / scale if logical_mode else best[1]
    configs = [(x0, y0, scale, transform, primary, [(connector, best[0], {})])]
    x = x0 + int(round(width))
    for c, (lx, ly, ls, lt, lp) in sorted(place.items(), key=lambda kv: kv[1][0]):
        m = current.get(c)
        if c == connector or m is None:
            continue
        configs.append((x, y0, ls, lt, lp and not primary, [(c, m[0], {})]))
        x += int(round(m[1] / ls if logical_mode else m[1]))
    bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "ApplyMonitorsConfig", GLib.Variant(CONFIG_SIG, (serial, 1, configs, {})),
                  None, Gio.DBusCallFlags.NONE, 5000, None)
    return best[1], best[2]


def watch_monitors(bus, callback):
    return bus.signal_subscribe(None, DC_BUS, "MonitorsChanged", DC_PATH, None, Gio.DBusSignalFlags.NONE,
                                lambda *a: callback())


TEXT_MIMES = ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT"]


def _read_all(fd, limit, timeout=3.0):
    """Reads a pipe to its end (at most `limit` bytes), then closes it."""
    import os, select
    out = bytearray()
    try:
        while len(out) <= limit:
            r, _, _ = select.select([fd], [], [], timeout)
            if not r:
                break
            b = os.read(fd, 65536)
            if not b:
                break
            out += b
    finally:
        os.close(fd)
    return bytes(out) if len(out) <= limit else None


class Capture:
    """One RemoteDesktop session with one ScreenCast stream. Call from the GLib main thread.

    on_ready(node_id) runs once the PipeWire stream exists; on_closed() if GNOME ends it.
    Input methods may be called from any thread (fire and forget).
    """

    def __init__(self, bus, monitor=None, virtual=False, cursor_mode=CURSOR_HIDDEN, on_ready=None, on_closed=None):
        self.bus = bus
        self.on_ready, self.on_closed = on_ready, on_closed
        self.closed = False
        self.subs = []
        self.rd_path = self._call(RD_BUS, RD_PATH, RD_BUS, "CreateSession", None, "(o)")[0]
        sid = self._call(RD_BUS, self.rd_path, "org.freedesktop.DBus.Properties", "Get",
                         GLib.Variant("(ss)", (RD_SESSION, "SessionId")), "(v)")[0]
        self.sc_path = self._call(SC_BUS, SC_PATH, SC_IFACE, "CreateSession",
                                  GLib.Variant("(a{sv})", ({"remote-desktop-session-id": GLib.Variant("s", sid)},)),
                                  "(o)")[0]
        props = {"cursor-mode": GLib.Variant("u", cursor_mode)}
        if virtual:
            props["is-platform"] = GLib.Variant("b", True)
            self.stream_path = self._call(SC_BUS, self.sc_path, SC_SESSION, "RecordVirtual",
                                          GLib.Variant("(a{sv})", (props,)), "(o)")[0]
        else:
            self.stream_path = self._call(SC_BUS, self.sc_path, SC_SESSION, "RecordMonitor",
                                          GLib.Variant("(sa{sv})", (monitor, props)), "(o)")[0]
        self.subs.append(bus.signal_subscribe(None, SC_STREAM, "PipeWireStreamAdded", self.stream_path, None,
                                              Gio.DBusSignalFlags.NONE, self._added))
        self.subs.append(bus.signal_subscribe(None, RD_SESSION, "Closed", self.rd_path, None,
                                              Gio.DBusSignalFlags.NONE, self._closed))
        self._call(RD_BUS, self.rd_path, RD_SESSION, "Start", None, None)
        log.info("screen cast started (%s)", "virtual monitor" if virtual else monitor)

    def _call(self, bus_name, path, iface, method, params, reply):
        r = self.bus.call_sync(bus_name, path, iface, method, params,
                               GLib.VariantType(reply) if reply else None, Gio.DBusCallFlags.NONE, 10000, None)
        return r.unpack() if r is not None else None

    def _added(self, _conn, _sender, _path, _iface, _signal, params):
        node = params.unpack()[0]
        log.info("PipeWire node %d", node)
        if self.on_ready and not self.closed:
            self.on_ready(node)

    def _closed(self, *_a):
        if self.closed:
            return
        log.warning("GNOME closed the screen cast session")
        self.closed = True
        self._unsubscribe()
        if self.on_closed:
            self.on_closed()

    def _unsubscribe(self):
        for s in self.subs:
            self.bus.signal_unsubscribe(s)
        self.subs = []

    def stop(self):
        if self.closed:
            return
        self.closed = True
        self._unsubscribe()
        try:
            self._call(RD_BUS, self.rd_path, RD_SESSION, "Stop", None, None)
        except GLib.Error as e:
            log.debug("stop: %s", e.message)

    # --- clipboard ------------------------------------------------------------------------------
    def enable_clipboard(self, on_text, limit):
        """Shares the clipboard: on_text(str) runs (on a worker thread) when an app on this computer
        copies text; set_text() makes text the clipboard here. Call after the session started."""
        self.on_clip, self.clip_limit, self.clip_bytes = on_text, limit, None
        self.subs.append(self.bus.signal_subscribe(None, RD_SESSION, "SelectionOwnerChanged", self.rd_path, None,
                                                   Gio.DBusSignalFlags.NONE, self._owner_changed))
        self.subs.append(self.bus.signal_subscribe(None, RD_SESSION, "SelectionTransfer", self.rd_path, None,
                                                   Gio.DBusSignalFlags.NONE, self._transfer))
        try:
            self._call(RD_BUS, self.rd_path, RD_SESSION, "EnableClipboard", GLib.Variant("(a{sv})", ({},)), None)
            return True
        except GLib.Error as e:
            log.warning("clipboard sharing is off: %s", e.message)
            return False

    def _owner_changed(self, _c, _s, _p, _i, _sig, params):
        opts = params.unpack()[0]
        mimes = opts.get("mime-types") or []
        if isinstance(mimes, tuple):
            mimes = mimes[0] if mimes else []
        self.clip_mimes = [] if opts.get("session-is-owner") else list(mimes)
        if self.closed or opts.get("session-is-owner") or not mimes:
            return
        mime = next((m for m in TEXT_MIMES if m in mimes), None)
        if mime is None:
            return
        threading.Thread(target=self._read_selection, args=(mime,), daemon=True).start()

    def _read_selection(self, mime):
        try:
            r, fds = self.bus.call_with_unix_fd_list_sync(
                RD_BUS, self.rd_path, RD_SESSION, "SelectionRead", GLib.Variant("(s)", (mime,)),
                GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, 5000, None, None)
            data = _read_all(fds.get(r.unpack()[0]), self.clip_limit)
        except GLib.Error as e:
            log.debug("clipboard read: %s", e.message)
            return
        if data is None:
            log.info("clipboard: too big to share")
            return
        text = data.decode("utf-8", "replace")
        if text and self.on_clip:
            self.on_clip(text)

    def copied_paths(self):
        """Any thread but the main one (it waits for GNOME). The local paths of the files copied
        on this computer (Ctrl+C in Files), or [] when what is copied is not files. Asks GNOME
        each time, so it does not depend on having seen the copy happen."""
        from urllib.parse import unquote, urlparse
        if self.closed:
            return []
        log.info("copied files: GNOME offers %s", getattr(self, "clip_mimes", "(no copy seen)"))
        for mime in ("text/uri-list", "x-special/gnome-copied-files"):
            try:
                r, fds = self.bus.call_with_unix_fd_list_sync(
                    RD_BUS, self.rd_path, RD_SESSION, "SelectionRead", GLib.Variant("(s)", (mime,)),
                    GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, 5000, None, None)
                data = _read_all(fds.get(r.unpack()[0]), 4 << 20) or b""
            except GLib.Error as e:
                log.info("copied files as %s: %s", mime, e.message)
                continue
            paths = []
            for line in data.decode("utf-8", "replace").splitlines():
                u = urlparse(line.strip())
                if u.scheme == "file":       # gnome-copied-files starts with "copy" or "cut": skipped
                    paths.append(unquote(u.path))
            log.info("copied files as %s: %d", mime, len(paths))
            if paths:
                return paths
        return []

    def set_text(self, text):
        """Any thread. Offers `text` as the clipboard; GNOME asks for it when an app pastes."""
        if self.closed:
            return
        self.clip_bytes = text.encode("utf-8")
        self.bus.call(RD_BUS, self.rd_path, RD_SESSION, "SetSelection",
                      GLib.Variant("(a{sv})", ({"mime-types": GLib.Variant("as", TEXT_MIMES)},)),
                      None, Gio.DBusCallFlags.NONE, 5000, None, None)

    def _transfer(self, _c, _s, _p, _i, _sig, params):
        _mime, serial = params.unpack()
        threading.Thread(target=self._write_selection, args=(serial,), daemon=True).start()

    def _write_selection(self, serial):
        import os
        ok = False
        try:
            if self.clip_bytes is not None:
                r, fds = self.bus.call_with_unix_fd_list_sync(
                    RD_BUS, self.rd_path, RD_SESSION, "SelectionWrite", GLib.Variant("(u)", (serial,)),
                    GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, 5000, None, None)
                fd = fds.get(r.unpack()[0])
                try:
                    view = memoryview(self.clip_bytes)
                    while view:
                        view = view[os.write(fd, view):]
                    ok = True
                finally:
                    os.close(fd)
        except (GLib.Error, OSError) as e:
            log.debug("clipboard write: %s", e)
        try:
            self._call(RD_BUS, self.rd_path, RD_SESSION, "SelectionWriteDone", GLib.Variant("(ub)", (serial, ok)), None)
        except GLib.Error as e:
            log.debug("clipboard write done: %s", e.message)

    # --- input (any thread) --------------------------------------------------------------------
    def _fire(self, method, sig, args):
        if self.closed:
            return
        self.bus.call(RD_BUS, self.rd_path, RD_SESSION, method, GLib.Variant(sig, args), None,
                      Gio.DBusCallFlags.NONE, 2000, None, None)

    def motion(self, x, y):
        self._fire("NotifyPointerMotionAbsolute", "(sdd)", (self.stream_path, float(x), float(y)))

    def button(self, button, pressed):
        self._fire("NotifyPointerButton", "(ib)", (button, pressed))

    def axis(self, dx, dy, flags=0):
        self._fire("NotifyPointerAxis", "(ddu)", (float(dx), float(dy), flags))

    def key(self, keycode, pressed):
        self._fire("NotifyKeyboardKeycode", "(ub)", (keycode, pressed))

    def keysym(self, keysym, pressed):
        self._fire("NotifyKeyboardKeysym", "(ub)", (keysym, pressed))
