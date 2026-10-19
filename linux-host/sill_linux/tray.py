"""The Sill icon at the top of the screen (an AppIndicator, which Ubuntu's GNOME shows by default).

It talks to the running host through its control socket, like the `sill-linux` command does:
pause and resume sharing, disconnect a device, the stream's quality, pairing, paired devices.
"""
import json
import shutil
import socket
import subprocess

import gi

gi.require_version("Gtk", "3.0")
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator
from gi.repository import GLib, Gtk  # noqa: E402

from .host import control_path  # noqa: E402

PRESETS = [(4_000_000, "Low"), (8_000_000, "Efficient"), (15_000_000, "Balanced"), (25_000_000, "High"),
           (40_000_000, "Pro"), (80_000_000, "Ultra"), (150_000_000, "Extreme")]
ICONS = {"down": "dialog-warning-symbolic", "paused": "media-playback-pause-symbolic",
         "idle": "video-display-symbolic", "live": "screen-shared-symbolic"}


def control(op, **kw):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(3)
    try:
        c.connect(control_path())
        c.sendall(json.dumps(dict(op=op, **kw)).encode())
        data = b""
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
        return json.loads(data)
    except (OSError, ValueError):
        return None
    finally:
        c.close()


def systemctl(*args):
    subprocess.Popen(["systemctl", "--user", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Tray:
    def __init__(self):
        self.ind = AppIndicator.Indicator.new("sill-linux", ICONS["idle"],
                                              AppIndicator.IndicatorCategory.APPLICATION_STATUS)
        self.ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.ind.set_title("Sill")
        self.status = None
        self.shown = None
        self.refresh()
        GLib.timeout_add_seconds(2, self.refresh)

    # --- state -----------------------------------------------------------------------------------
    def refresh(self):
        self.status = control("status")
        key = json.dumps(self._digest(self.status), sort_keys=True)
        if key != self.shown:
            self.shown = key
            self.build()
        return True

    @staticmethod
    def _digest(st):
        """What the menu shows, so it is rebuilt only when that changes."""
        if st is None:
            return None
        s = st.get("settings", {})
        return {"paused": st.get("paused"), "sessions": [(x["name"], x["address"]) for x in st.get("sessions", [])],
                "devices": [(d["key"], d["name"]) for d in st.get("devices", [])],
                "settings": s.get("settings"), "vd": s.get("virtualDisplayAvailable"),
                "stream": s.get("stream"), "name": st.get("name"),
                "build": st.get("build"), "update": st.get("update"), "canUpdate": st.get("canUpdate")}

    # --- the menu ----------------------------------------------------------------------------------
    def item(self, menu, label, callback=None, sensitive=True):
        it = Gtk.MenuItem(label=label)
        it.set_sensitive(sensitive and callback is not None)
        if callback:
            it.connect("activate", lambda _w: callback())
        menu.append(it)
        return it

    def radio(self, menu, choices, current, apply):
        group = None
        for value, label in choices:
            it = Gtk.RadioMenuItem.new_with_label_from_widget(group, label)
            group = it
            it.set_active(value == current)
            it.connect("toggled", lambda w, v=value: w.get_active() and v != current and apply(v))
            menu.append(it)

    def submenu(self, menu, label):
        top = Gtk.MenuItem(label=label)
        sub = Gtk.Menu()
        top.set_submenu(sub)
        menu.append(top)
        return sub

    def build(self):
        st = self.status
        menu = Gtk.Menu()
        if st is None:
            self.ind.set_icon_full(ICONS["down"], "Sill is not running")
            self.item(menu, "Sill is not running")
            menu.append(Gtk.SeparatorMenuItem())
            self.item(menu, "Start Sill", lambda: (systemctl("start", "sill-linux"), GLib.timeout_add_seconds(2, self.refresh)))
            self.item(menu, "Show log", self.show_log)
            menu.show_all()
            self.ind.set_menu(menu)
            return
        sessions = st.get("sessions", [])
        paused = st.get("paused")
        state = "paused" if paused else ("live" if sessions else "idle")
        self.ind.set_icon_full(ICONS[state], "Sill")
        title = {"paused": "Sharing is paused",
                 "live": f"Sharing with {len(sessions)} device{'s' if len(sessions) != 1 else ''}",
                 "idle": "Waiting for a device"}[state]
        self.item(menu, f"Sill for Linux (unofficial) · {st.get('name')}")
        self.item(menu, title)
        stream = st.get("settings", {}).get("stream")
        if stream and sessions:
            self.item(menu, f"{stream['width']}×{stream['height']} · {stream['fps']} fps · {stream['mbps']} Mbps")
        for x in sessions:
            sub = self.submenu(menu, f"    {x['name']}  ({x['address']})")
            self.item(sub, "Disconnect", lambda n=x["name"]: self.act("disconnect", device=n))
        menu.append(Gtk.SeparatorMenuItem())
        if not paused and sessions:
            self.item(menu, "Release stuck keys and buttons", lambda: self.act("release"))
        if paused:
            self.item(menu, "Resume sharing", lambda: self.act("resume"))
        else:
            self.item(menu, "Pause sharing (frees your mouse)", lambda: self.act("pause"))
        menu.append(Gtk.SeparatorMenuItem())

        s = st.get("settings", {}).get("settings", {})
        sub = self.submenu(menu, "Quality")
        choices = [(b, f"{n} — {b // 1_000_000} Mbps") for b, n in PRESETS]
        if s.get("bitrate") not in dict(PRESETS):
            choices.append((s.get("bitrate"), f"Custom — {s.get('bitrate', 0) // 1_000_000} Mbps"))
        self.radio(sub, choices, s.get("bitrate"), lambda v: self.set(bitrate=v))
        sub = self.submenu(menu, "Frame rate")
        self.radio(sub, [(60, "Up to 60 fps"), (120, "Up to 120 fps")], s.get("maxFPS"), lambda v: self.set(maxFPS=v))
        sub = self.submenu(menu, "Resolution")
        self.radio(sub, [(2.0, "Sharp (full resolution)"), (1.0, "Standard (half, for slow links)")],
                   s.get("captureScale"), lambda v: self.set(captureScale=v))
        if st.get("settings", {}).get("virtualDisplayAvailable"):
            vd = Gtk.CheckMenuItem(label="Desktop on a virtual screen sized to the device")
            vd.set_active(bool(s.get("virtualDisplay")))
            vd.connect("toggled", lambda w: self.set(virtualDisplay=w.get_active()))
            menu.append(vd)
        menu.append(Gtk.SeparatorMenuItem())

        self.item(menu, "Pair iPhone or iPad…", lambda: self.act("pair"))
        devices = st.get("devices", [])
        sub = self.submenu(menu, f"Paired devices ({len(devices)})")
        if not devices:
            self.item(sub, "None yet")
        for d in devices:
            dsub = self.submenu(sub, f"{d['name']} ({d.get('model') or 'device'})")
            self.item(dsub, "Remove", lambda k=d["key"]: self.act("forget", device=k))
        menu.append(Gtk.SeparatorMenuItem())
        build = st.get("build") or "dev"
        self.item(menu, f"Version {build[:7]}")
        if st.get("update"):
            if st.get("canUpdate"):
                self.item(menu, "Update available: Update now", lambda: self.act("update"))
            else:
                self.item(menu, "Update available (install the new download)")
        self.item(menu, "Show log", self.show_log)
        self.item(menu, "Restart Sill", lambda: systemctl("restart", "sill-linux"))
        self.item(menu, "Stop Sill", self.stop)
        menu.show_all()
        self.ind.set_menu(menu)

    # --- actions -------------------------------------------------------------------------------------
    def act(self, op, **kw):
        control(op, **kw)
        GLib.timeout_add(300, lambda: (self.refresh(), False)[1])

    def set(self, **changes):
        self.act("settings", changes=changes)

    def show_log(self):
        cmd = ["journalctl", "--user", "-u", "sill-linux", "-f", "-n", "200"]
        for term in (["gnome-terminal", "--"], ["ptyxis", "--"], ["kgx", "--"], ["xterm", "-e"]):
            if shutil.which(term[0]):
                subprocess.Popen(term + cmd)
                return

    def stop(self):
        """Stops the host; this icon stays, with Start Sill, until you log out."""
        systemctl("stop", "sill-linux")
        GLib.timeout_add_seconds(1, lambda: (self.refresh(), False)[1])


def main():
    Tray()
    Gtk.main()


if __name__ == "__main__":
    main()
