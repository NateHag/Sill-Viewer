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
