"""GNOME's own screen sharing and input API (the one gnome-remote-desktop uses).

org.gnome.Mutter.RemoteDesktop gives a session that injects pointer and keyboard events.
org.gnome.Mutter.ScreenCast, tied to that session, records a monitor (RecordMonitor) or a new
virtual monitor of any size (RecordVirtual) into a PipeWire stream. No portal dialog, no extra
display driver, no X11.
"""
import logging

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


def set_virtual_scale(bus, want):
    """Sets the scale of the virtual monitor (connector "Meta-…") to the supported scale nearest
    `want`, and makes it the primary monitor, so the top bar and the desktop icons are on the
    screen the viewer sees. Other monitors keep their place and scale. Temporary: GNOME goes back
    to its saved layout when the virtual monitor goes. Returns the scale set, or None."""
    r = bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "GetCurrentState", None, None, Gio.DBusCallFlags.NONE, 5000, None)
    serial, mons, logical, _props = r.unpack()
    modes = {}
    for (spec, mode_list, _mprops) in mons:
        cur = next((m for m in mode_list if m[6].get("is-current")), None)
        if cur is not None:
            modes[spec[0]] = (cur[0], list(cur[5]) or [1.0])
    configs, chosen = [], None
    for (x, y, scale, transform, primary, specs, _lp) in logical:
        connectors = [sp[0] for sp in specs if sp[0] in modes]
        if not connectors:
            continue
        primary = False
        if any(c.startswith("Meta-") for c in connectors) and chosen is None:
            supported = modes[connectors[0]][1]
            scale = min(supported, key=lambda v: abs(v - want))
            chosen = scale
            primary = True
        configs.append((x, y, scale, transform, primary, [(c, modes[c][0], {}) for c in connectors]))
    if chosen is None:
        return None
    bus.call_sync(DC_BUS, DC_PATH, DC_BUS, "ApplyMonitorsConfig",
                  GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (serial, 1, configs, {})),
                  None, Gio.DBusCallFlags.NONE, 5000, None)
    return chosen


def watch_monitors(bus, callback):
    return bus.signal_subscribe(None, DC_BUS, "MonitorsChanged", DC_PATH, None, Gio.DBusSignalFlags.NONE,
                                lambda *a: callback())


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
