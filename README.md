# Sill Desktop

> **Unofficial.** This is an independent companion project. It is not made by, or affiliated with,
> the Sill team. "Sill" names the app it works with. If the Sill author prefers another name,
> this project will be renamed.

Two additions to [Sill](https://github.com/Saffsanity/sill), the open-source app that shows a Mac's
windows on an iPhone or iPad:

| Folder | What it is |
|---|---|
| [`linux-host/`](linux-host/) | **sill-linux**: a Sill host for Linux (GNOME on Wayland). Your Linux desktop shows up in the Sill app from the App Store, as a Mac does. Tray icon, pairing, NVENC/VA-API HEVC, virtual screens sized to the device. |
| [`viewer/`](viewer/) | **Sill Viewer**: a desktop app for Windows, Mac and Linux that connects to any Sill host (a Mac with Sill, or Linux with sill-linux), with your own mouse and keyboard. Tray icon, hardware decoding. |

Both speak Sill's own wire format and pairing: TLS 1.3 with both keys pinned, the 12-digit code or
the QR link, Bonjour (`_sill._tcp`).

## Downloads

Every push builds the viewer for Windows, Mac and Linux (Actions tab, the run's artifacts).
A tag such as `v0.2.0` makes a release with the downloads attached.

## Linux host: install

```
cd linux-host
./install.sh
```

Then open Sill on the iPhone or iPad, tap the computer, and type the code it shows.
See [`linux-host/README.md`](linux-host/README.md).

## Viewer: build

- Windows, cross-compiled on Linux: `viewer/scripts/prepare-ffmpeg-windows.sh` then `viewer/build-windows.sh`.
- Mac: `viewer/build-mac.sh`.
- Linux: `cargo build --release` in `viewer/` (FFmpeg development packages needed).

See [`viewer/README.md`](viewer/README.md).

## License

Apache-2.0, as Sill.
