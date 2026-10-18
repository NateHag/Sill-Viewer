# Sill Desktop

## What this adds to Sill

Sill today: **a Mac** shows its screen on **an iPhone or iPad**.

In short: **Linux can now share its screen, and Windows, Mac and Linux PCs can now view.**

This project adds:

| | Before | With this project |
|---|---|---|
| **Linux computers** | Not supported | **Show a Linux desktop on your iPhone or iPad**, in the normal Sill app from the App Store. No app change needed. |
| **Windows PCs** | Not supported | **Show a Mac or Linux screen on a Windows PC**, with your own mouse and keyboard. |
| **Macs** | Only share their screen | **Also show another Mac or Linux screen**, in a window. |
| **Linux viewer** | Not supported | **Show a Mac or Linux screen on a Linux PC.** |

Between the desktop viewers and a Linux computer, you also get:

- **Copy and paste of text**, both ways.
- **Files both ways:** drop files on the viewer to send them; click "Get copied files" to fetch what you copied on Linux.
- **Match this screen:** the Linux desktop takes your screen's exact resolution.
- **A quick switcher** between your paired computers.
- **Zoom** (any computer, Mac too): make a big remote screen readable on a small laptop.

> **Unofficial.** This is an independent companion project. It is not made by, or affiliated with,
> the Sill team. "Sill" names the app it works with. If the Sill author prefers another name,
> this project will be renamed.

## The two parts

Two additions to [Sill](https://github.com/Saffsanity/sill), the open-source app that shows a Mac's
windows on an iPhone or iPad:

| Folder | What it is |
|---|---|
| [`linux-host/`](linux-host/) | **sill-linux**: a Sill host for Linux (GNOME on Wayland). Your Linux desktop shows up in the Sill app from the App Store, as a Mac does. Tray icon, pairing, NVENC/VA-API HEVC, virtual screens sized to the device. |
| [`viewer/`](viewer/) | **Sill Viewer**: a desktop app for Windows, Mac and Linux that connects to any Sill host (a Mac with Sill, or Linux with sill-linux), with your own mouse and keyboard. Tray icon, hardware decoding. |

Both speak Sill's own wire format and pairing: TLS 1.3 with both keys pinned, the 12-digit code or
the QR link, Bonjour (`_sill._tcp`).

## Downloads

Ready-made files in the [downloads](downloads) folder:

- **Linux host** (share a Linux desktop): [sill-linux-host.tar.gz](downloads/sill-linux-host.tar.gz).
  Ubuntu with GNOME on Wayland. Unpack it, then in the `sill-linux-host` folder run `./install.sh`.

- **Windows:** [SillViewer-windows.zip](downloads/SillViewer-windows.zip). Unzip it and run "Sill Viewer.exe".
- **Linux:** [SillViewer-linux.tar.gz](downloads/SillViewer-linux.tar.gz). Needs FFmpeg 6 or later. Run `./sill-viewer`.
- **Mac:** build it with `viewer/build-mac.sh` (see [viewer/README.md](viewer/README.md)).

Every push also builds the viewer for Windows, Mac and Linux (Actions tab, the run's artifacts).
A tag such as `v0.2.0` makes a release with the downloads attached.

## Mac host (in progress)

`mac-host/` is an unofficial build of Sill's own Mac host, renamed Sill Desktop Host, where the
features above will come to Macs too (scaling, files, Match this screen, a locked Mac). Build it on
the Mac with `cd mac-host && Scripts/make-app.sh --install --open`. See mac-host/README.md.

Done so far: copy files both ways; Fit screen and Match this screen on the whole desktop (the
desktop moves to a virtual screen of the viewer's size, which becomes the Mac's main screen; the
real screens come back when you turn it off or disconnect).

## Automatic updates

Each machine checks GitHub every hour and installs what changed. Set it up once per machine:

- **Mac** (viewer and/or host, whichever is in /Applications):
  `~/Sill-Viewer/scripts/update-mac.sh --install`
  Optional signing setting in `~/.config/sill-update.conf`, e.g. `SILL_SIGN_IDENTITY=<SHA-1 hash>`.
  Log: `~/Library/Logs/sill-update.log`. Update now: `~/Sill-Viewer/scripts/update-mac.sh --force`.
- **Linux host:** `install.sh` sets it up (or `./update.sh --install` in the host folder).
  Log: `journalctl --user -u sill-linux-update`.
- **Windows viewer** (PowerShell):
  ```
  $f="$env:TEMP\install-sill-viewer.ps1"
  iwr https://raw.githubusercontent.com/NateHag/Sill-Viewer/main/downloads/install-sill-viewer.ps1 -OutFile $f
  powershell -ExecutionPolicy Bypass -File $f
  ```
  Installs to `%LOCALAPPDATA%\Programs\SillViewer` with a Start menu entry. Log: `update.log` there.

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
