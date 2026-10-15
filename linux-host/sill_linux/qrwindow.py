"""A small window with the pairing QR code and the 12-digit code. Run as its own process:
python3 -m sill_linux.qrwindow LINK CODE NAME"""
import os
import subprocess
import sys
import tempfile


def main():
    link, code, name = sys.argv[1], sys.argv[2], sys.argv[3]
    if not os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY"):
        os.environ["WAYLAND_DISPLAY"] = "wayland-0"      # a service started before the session exported it
    png = os.path.join(tempfile.mkdtemp(prefix="sill-"), "pair.png")
    subprocess.run(["qrencode", "-s", "9", "-m", "2", "-o", png, link], check=True)
    import gi
    try:
        gi.require_version("Gtk", "4.0")
        from gi.repository import GLib, Gtk
        gtk4 = True
    except (ValueError, ImportError):
        gi.require_version("Gtk", "3.0")
        from gi.repository import GLib, Gtk
        gtk4 = False

    def build(win):
        win.set_title(f"Pair with {name}")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        for m in ("set_margin_top", "set_margin_bottom", "set_margin_start", "set_margin_end"):
            getattr(box, m)(24)
        title = Gtk.Label()
        title.set_markup("<span size='large' weight='bold'>Scan with the Sill app</span>")
        img = Gtk.Picture.new_for_filename(png) if gtk4 else Gtk.Image.new_from_file(png)
        if gtk4:
            img.set_size_request(320, 320)
        code_l = Gtk.Label()
        code_l.set_markup(f"<span size='xx-large' font_family='monospace' weight='bold'>{code}</span>")
        code_l.set_selectable(True)
        hint = Gtk.Label(label="Or choose Enter Code Instead and type the code. It works for 5 minutes.")
        for w in (title, img, code_l, hint):
            box.append(w) if gtk4 else box.pack_start(w, False, False, 0)
        if gtk4:
            win.set_child(box)
            win.present()
        else:
            win.add(box)
            win.show_all()
        GLib.timeout_add_seconds(300, lambda: (win.close(), False)[1])

    if gtk4:
        app = Gtk.Application(application_id=None)
        app.connect("activate", lambda a: build(Gtk.ApplicationWindow(application=a)))
        app.run([])
    else:
        win = Gtk.Window()
        win.connect("destroy", Gtk.main_quit)
        build(win)
        Gtk.main()


if __name__ == "__main__":
    main()
