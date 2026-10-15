"""Bonjour: advertise _sill._tcp with TXT p (how the door speaks) and r (recognition tag).

Uses the Avahi daemon that every Ubuntu desktop runs (D-Bus, system bus); falls back to
python-zeroconf when Avahi is not there.
"""
import logging
import socket

from gi.repository import Gio, GLib

log = logging.getLogger("sill.mdns")

AVAHI = "org.freedesktop.Avahi"
SERVER = "org.freedesktop.Avahi.Server"
GROUP = "org.freedesktop.Avahi.EntryGroup"
SERVICE = "_sill._tcp"


class Advertiser:
    def __init__(self, name, port, txt_fn):
        self.name, self.port, self.txt_fn = name, port, txt_fn
        self.bus = None
        self.group = None
        self.sub = None
        self.zc = None
        self.zc_info = None

    def start(self):
        try:
            self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            self.group = self._call("/", SERVER, "EntryGroupNew", None, "(o)")[0]
            self.sub = self.bus.signal_subscribe(AVAHI, GROUP, "StateChanged", self.group, None,
                                                 Gio.DBusSignalFlags.NONE, self._state)
            self._publish()
            return
        except GLib.Error as e:
            log.warning("Avahi not reachable (%s); using python-zeroconf", e.message)
            self.bus = None
        try:
            self._zeroconf()
        except Exception as e:
            self.zc = None
            log.error("cannot advertise on the network (%s); devices will not find this computer", e)

    def _call(self, path, iface, method, params, reply):
        r = self.bus.call_sync(AVAHI, path, iface, method, params, GLib.VariantType(reply) if reply else None,
                               Gio.DBusCallFlags.NONE, 5000, None)
        return r.unpack() if r is not None else None

    def _txt(self):
        return [f"{k}={v}".encode() for k, v in self.txt_fn().items()]

    def _publish(self):
        self._call(self.group, GROUP, "AddService",
                   GLib.Variant("(iiussssqaay)", (-1, -1, 0, self.name, SERVICE, "", "", self.port, self._txt())), None)
        self._call(self.group, GROUP, "Commit", None, None)
        log.info("advertising \"%s\" on port %d", self.name, self.port)

    def _state(self, _c, _s, _p, _i, _sig, params):
        state, error = params.unpack()
        if state == 3:     # collision: take Avahi's next name ("Name (2)") and try again
            new = self._call("/", SERVER, "GetAlternativeServiceName", GLib.Variant("(s)", (self.name,)), "(s)")[0]
            log.warning("the name \"%s\" is taken on this network; using \"%s\"", self.name, new)
            self.name = new
            self._call(self.group, GROUP, "Reset", None, None)
            self._publish()
        elif state == 4:
            log.error("Avahi could not advertise: %s", error)

    def refresh(self):
        """Publish the TXT record again (p changed, or a fresh r)."""
        if self.bus is not None:
            try:
                self._call(self.group, GROUP, "Reset", None, None)
                self._publish()
            except GLib.Error as e:
                log.error("Avahi refresh: %s", e.message)
        elif self.zc is not None:
            self.zc_info.properties = {k.encode(): v.encode() for k, v in self.txt_fn().items()}
            self.zc.update_service(self.zc_info)

    def _zeroconf(self):
        from zeroconf import IPVersion, ServiceInfo, Zeroconf
        from .host import local_addresses
        addrs = [socket.inet_pton(socket.AF_INET6 if ":" in a else socket.AF_INET, a.split("%")[0])
                 for a in local_addresses()]
        try:
            self.zc = Zeroconf(ip_version=IPVersion.All)
        except OSError:
            self.zc = Zeroconf(ip_version=IPVersion.V4Only)
            addrs = [a for a in addrs if len(a) == 4]
        self.zc_info = ServiceInfo(f"{SERVICE}.local.", f"{self.name}.{SERVICE}.local.", port=self.port,
                                   properties=self.txt_fn(), addresses=addrs,
                                   server=f"{socket.gethostname()}-sill.local.")
        self.zc.register_service(self.zc_info, allow_name_change=True)
        log.info("advertising \"%s\" on port %d (zeroconf)", self.name, self.port)

    def stop(self):
        try:
            if self.bus is not None and self.group:
                self._call(self.group, GROUP, "Free", None, None)
            if self.zc is not None:
                self.zc.unregister_all_services()
                self.zc.close()
        except Exception:
            pass
