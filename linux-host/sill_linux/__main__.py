"""sill-linux: a Linux (GNOME, Wayland) host for the Sill iPhone and iPad app.

  sill-linux               run the host (normally started by the systemd user service)
  sill-linux pair          show a pairing code and QR code for a new device
  sill-linux status        what is connected and streaming
  sill-linux devices       the paired devices
  sill-linux forget NAME   remove a paired device
  sill-linux pause         stop sharing (devices disconnect; your mouse is yours again)
  sill-linux resume        share again
  sill-linux release       let go of keys and buttons a device left down (Ctrl, Super, a click)
  sill-linux tray          the icon at the top of the screen (started by its own service)
"""
import argparse
import json
import logging
import shutil
import socket
import subprocess
import sys


def control(op, **kw):
    from .host import control_path
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        c.connect(control_path())
    except OSError:
        sys.exit("The Sill host is not running. Start it with: systemctl --user start sill-linux")
    c.sendall(json.dumps(dict(op=op, **kw)).encode())
    data = b""
    while True:
        chunk = c.recv(65536)
        if not chunk:
            break
        data += chunk
    return json.loads(data)


def check():
    """Print what works on this computer, one line each."""
    import os
    ok = lambda good, text: print(("  OK    " if good else "  FAIL  ") + text) or good
    import gi
    from . import mutter, video
    from gi.repository import Gio, GLib
    video.init()
    print("Sill for Linux: checking this computer\n")
    ok(os.environ.get("XDG_SESSION_TYPE") == "wayland" or bool(os.environ.get("WAYLAND_DISPLAY")),
       f"Wayland session ({os.environ.get('XDG_SESSION_TYPE', 'unknown')})")
    try:
        bus = mutter.session_bus()
    except GLib.Error as e:
        bus = None
        ok(False, f"session D-Bus: {e.message}")
    if bus and ok(mutter.available(bus), "GNOME remote desktop API (org.gnome.Mutter.RemoteDesktop)"):
        try:
            mons = mutter.monitors(bus)
            ok(bool(mons), "monitors: " + ", ".join(f"{m.connector} {m.width}x{m.height}"
                                                    f"{' (primary)' if m.primary else ''}" for m in mons))
        except GLib.Error as e:
            ok(False, f"monitors: {e.message}")
    ok(video.have("pipewiresrc"), "PipeWire capture (gstreamer1.0-pipewire)")
    ok(video.have("h265parse"), "HEVC parser (gstreamer1.0-plugins-bad)")
    vk = video.vulkan_device()
    ok(True, f"Vulkan HEVC (sill-vkenc): {'works on ' + vk if vk else 'not used (needs NVIDIA and FFmpeg hevc_vulkan)'}")
    ok(True, "Encode on (tray): Auto, " + ", ".join(label for _, label in video.encode_gpus()))
    encs = [e for e in video.ENCODERS if video.have(e)]
    hw = [e for e in encs if e != "x265enc"]
    ok(bool(hw), "hardware HEVC encoder: " + (", ".join(hw) if hw else "none found (software x265 only)"))
    if hw:
        for enc in hw:
            pipe = video.Gst.parse_launch(
                f"videotestsrc num-buffers=30 ! video/x-raw,width=1920,height=1080 ! "
                f"{video.convert_description(enc, None, None)} ! {video.encoder_description(enc, 20000, 60, 240, False)}"
                f" ! h265parse ! fakesink")
            pipe.set_state(video.Gst.State.PLAYING)
            msg = pipe.get_bus().timed_pop_filtered(10 * video.Gst.SECOND,
                                                    video.Gst.MessageType.ERROR | video.Gst.MessageType.EOS)
            good = msg is not None and msg.type == video.Gst.MessageType.EOS
            ok(good, f"  {enc} encodes" + ("" if good else f": {msg.parse_error()[0].message if msg else 'timeout'}"))
            pipe.set_state(video.Gst.State.NULL)
    try:
        sysbus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        r = sysbus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                             GLib.Variant("(s)", ("org.freedesktop.Avahi",)), None, Gio.DBusCallFlags.NONE, 2000, None)
        ok(r.unpack()[0], "Avahi (Bonjour) daemon")
    except GLib.Error as e:
        ok(False, f"Avahi: {e.message}")
    ok(shutil.which("qrencode") is not None, "qrencode (QR codes in `sill-linux pair`, optional)")
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3  # noqa: F401
        ok(True, "tray icon library (AyatanaAppIndicator3)")
    except (ValueError, ImportError):
        ok(False, "tray icon library: install gir1.2-ayatanaappindicator3-0.1")
    ext = subprocess.run(["sh", "-c", "gnome-extensions list --enabled 2>/dev/null | grep -i appindicator"],
                         capture_output=True, text=True).stdout.strip()
    ok(bool(ext), "GNOME shows tray icons (AppIndicator extension" + (f": {ext})" if ext else
       " is off: run  gnome-extensions enable ubuntu-appindicators@ubuntu.com)"))
    ufw = subprocess.run(["sh", "-c", "ufw status 2>/dev/null | head -1"], capture_output=True, text=True).stdout
    if "active" in ufw and "inactive" not in ufw:
        print("  NOTE  ufw firewall is on: run  sudo ufw allow 7456/tcp && sudo ufw allow 5353/udp")


def main():
    ap = argparse.ArgumentParser(prog="sill-linux", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="run",
                    choices=["run", "pair", "status", "devices", "forget", "check", "tray", "pause", "resume", "release",
                             "watchdog"])
    ap.add_argument("device", nargs="?",
                    help="with forget: the device's name; with watchdog: on, off, pause (4 hours), resume or status")
    ap.add_argument("--name", help="the name devices see (default: this computer's host name)")
    ap.add_argument("--port", type=int, default=7456, help="TCP port (default 7456)")
    ap.add_argument("--open", action="store_true",
                    help="no pairing: any device on the network may connect (still encrypted)")
    ap.add_argument("--encoder", help="force one encoder, e.g. hevc_vulkan, nvh265enc or x265enc")
    ap.add_argument("--cursor", choices=["auto", "hidden", "embedded"], default="auto",
                    help="auto (default): in the video for iPhone and iPad, left out for desktop viewers, which "
                         "show your own cursor; embedded: always in the video; hidden: never")
    ap.add_argument("--command-key", choices=["ctrl", "super"], default="ctrl",
                    help="what the iPad's Command key becomes (default ctrl, so Cmd+C copies)")
    ap.add_argument("--scroll-speed", type=float, default=1.0)
    ap.add_argument("--trace-input", action="store_true",
                    help="log pointer and scroll events (never keys or text), to debug input")
    # Off by default: switching the real monitor's mode once left a PC with no picture at all (not
    # on the monitor, not through a KVM), and with the host down nothing could switch it back.
    ap.add_argument("--fit", choices=["off", "monitor", "virtual"], default="off",
                    help="Fit screen: leave the monitor as it is and let the viewer scale (off, the default), "
                         "switch the real monitor to the closest mode (monitor), or use an exact GNOME virtual "
                         "screen (virtual; slow on some GPUs)")
    # Off by default: on GNOME 50 with NVIDIA it gave blank frames, and no more of them.
    ap.add_argument("--dmabuf", choices=["auto", "off"], default="off",
                    help="virtual screens: take frames from GNOME on the GPU (auto), or as copies in memory (off)")
    ap.add_argument("--test-source", action="store_true", help="stream a test pattern, without GNOME")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if args.command == "pair":
        r = control("pair")
        print(f"\nPair a device with {r['name']}\n")
        if shutil.which("qrencode"):
            subprocess.run(["qrencode", "-t", "ansiutf8", "-m", "2", r["link"]])
            print("Scan this with the Sill app (Add a Mac…), or tap the computer in the list and enter the code.")
        print(f"\n  Code: {r['code']}\n\nThe code works for 5 minutes.")
        return
    if args.command == "check":
        return check()
    if args.command == "tray":
        from .tray import main as tray_main
        return tray_main()
    if args.command == "release":
        r = control("release")
        print("Released every key and button." if r.get("released") else "Nothing is streaming.")
        return
    if args.command in ("pause", "resume"):
        r = control(args.command)
        print("Sharing is paused." if r.get("paused") else "Sharing is on.")
        return
    if args.command == "watchdog":
        from . import watchdog
        what = args.device or "status"
        if what == "on":
            watchdog.save(enabled=True)
        elif what == "off":
            watchdog.save(enabled=False)
        elif what == "pause":
            watchdog.pause()
        elif what == "resume":
            watchdog.resume()
        elif what != "status":
            sys.exit("usage: sill-linux watchdog [on|off|pause|resume|status]")
        print(watchdog.describe())
        return
    if args.command == "status":
        print(json.dumps(control("status"), indent=2))
        return
    if args.command in ("devices", "forget"):
        from .identity import Devices
        if args.command == "forget":
            if not args.device:
                sys.exit("usage: sill-linux forget NAME")
            try:
                r = control("forget", device=args.device)
            except SystemExit:
                r = {"removed": Devices().remove(args.device)}
            print("Removed." if r.get("removed") else "No such device.")
            return
        for key, d in Devices().listing().items():
            print(f"{d['name']:<28} {d.get('model') or '':<14} {key[:10]}…")
        return

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(name)s: %(message)s", datefmt="%H:%M:%S")
    from .host import Host
    Host(args).run()


if __name__ == "__main__":
    main()
